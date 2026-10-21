//
//  AgentSessions.swift
//  OpenClicky
//
//  The Coding agents component's eyes: what a Claude Code or Codex session is doing, read from
//  the session's own log on disk (no network, nothing written), when a session counts as live,
//  and the watcher that lists the recent ones. The parsers are pure; the watcher polls.
//

import Combine
import Foundation

enum AgentKind: String, Codable {
    case claudeCode = "claude"
    case codex

    var displayName: String { rawValue }
}

/// What the session's last records say the agent is doing.
enum AgentActivity: Equatable {
    case tool(name: String, detail: String?)
    case thinking
    case writing(String)
    /// The last record is a prompt or a tool result: the model is working on it.
    case waiting
    /// The answer is finished and nothing followed.
    case idle

    /// One short line: "editing Hero.swift", "running: git status", "thinking", "writing",
    /// "waiting", "done".
    var line: String {
        switch self {
        case .tool(let name, let detail):
            let verb: String
            var joiner = " "
            switch name.lowercased() {
            case "edit", "write", "multiedit", "notebookedit", "apply_patch": verb = "editing"
            case "read": verb = "reading"
            case "bash", "shell", "exec", "exec_command", "shell_command": verb = "running:"
            case "grep", "glob": verb = "searching"
            case "webfetch", "websearch": verb = "browsing"
            default: verb = name.lowercased()
            }
            if verb == "running:" { joiner = " " }
            guard let detail, !detail.isEmpty else { return verb == "running:" ? "running" : verb }
            return verb + joiner + detail
        case .thinking: return "thinking"
        case .writing: return "writing"
        case .waiting: return "waiting"
        case .idle: return "done"
        }
    }
}

struct AgentSession: Equatable, Identifiable {
    let id: String
    let agent: AgentKind
    /// The working folder's last path component.
    let project: String
    let title: String?
    let activity: AgentActivity
    let lastEventAt: Date

    /// How long after its last write a working session still counts as live.
    static let liveWindow: TimeInterval = 120
    /// How long a session stays listed after it stops.
    static let recentWindow: TimeInterval = 600

    func isLive(now: Date) -> Bool {
        activity != .idle && now.timeIntervalSince(lastEventAt) < Self.liveWindow
    }
}

/// What the tail of one log yields.
struct AgentTailParse: Equatable {
    var activity: AgentActivity = .waiting
    var title: String?
    var cwd: String?
}

enum AgentSessionParser {
    private static let detailLength = 40

    /// `~/.claude/projects/*/*.jsonl`: one JSON record a line. The activity comes from the last
    /// `assistant` record (idle once its answer finished), `.waiting` when a `user` record follows
    /// it or no assistant record is in the tail. Other record types only lend their `cwd`.
    static func parseClaudeTail(_ text: String) -> AgentTailParse {
        var parse = AgentTailParse()
        var lastAssistant: [String: Any]?
        var userAfterAssistant = false
        for record in records(in: text) {
            if let cwd = record["cwd"] as? String { parse.cwd = cwd }
            switch record["type"] as? String {
            case "assistant":
                lastAssistant = record
                userAfterAssistant = false
            case "user":
                if lastAssistant != nil { userAfterAssistant = true }
            case "ai-title":
                if let title = record["aiTitle"] as? String, !title.isEmpty { parse.title = title }
            default:
                break
            }
        }
        guard let lastAssistant, let message = lastAssistant["message"] as? [String: Any] else { return parse }
        if userAfterAssistant {
            parse.activity = .waiting
            return parse
        }
        if let stopReason = message["stop_reason"] as? String, stopReason == "end_turn" || stopReason == "stop_sequence" {
            parse.activity = .idle
            return parse
        }
        guard let blocks = message["content"] as? [[String: Any]], let last = blocks.last else {
            parse.activity = .waiting
            return parse
        }
        switch last["type"] as? String {
        case "tool_use":
            let input = last["input"] as? [String: Any] ?? [:]
            parse.activity = .tool(name: last["name"] as? String ?? "tool", detail: toolDetail(filePath: input["file_path"] as? String, command: input["command"] as? String))
        case "thinking":
            parse.activity = .thinking
        case "text":
            parse.activity = .writing(firstLine(of: last["text"] as? String ?? "", limit: 60))
        default:
            parse.activity = .waiting
        }
        return parse
    }

    /// `~/.codex/sessions/**/rollout-*.jsonl`: `session_meta` for the folder, `response_item`s
    /// for what the model does, `event_msg` `task_complete` once a turn is over.
    static func parseCodexTail(_ text: String) -> AgentTailParse {
        var parse = AgentTailParse()
        for record in records(in: text) {
            guard let payload = record["payload"] as? [String: Any] else { continue }
            switch record["type"] as? String {
            case "session_meta":
                if let cwd = payload["cwd"] as? String { parse.cwd = cwd }
            case "response_item":
                switch payload["type"] as? String {
                case "function_call":
                    parse.activity = .tool(name: payload["name"] as? String ?? "tool", detail: codexArgumentsDetail(payload["arguments"]))
                case "custom_tool_call":
                    parse.activity = .tool(name: payload["name"] as? String ?? "tool", detail: (payload["input"] as? String).map { String($0.prefix(detailLength)) })
                case "reasoning":
                    parse.activity = .thinking
                case "message":
                    let text = (payload["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.first ?? ""
                    if payload["role"] as? String == "assistant" {
                        parse.activity = .writing(firstLine(of: text, limit: 60))
                    } else {
                        parse.activity = .waiting
                        if parse.title == nil, !text.isEmpty { parse.title = firstLine(of: text, limit: 60) }
                    }
                default:
                    break
                }
            case "event_msg":
                switch payload["type"] as? String {
                case "task_complete": parse.activity = .idle
                case "task_started": parse.activity = .waiting
                default: break
                }
            default:
                break
            }
        }
        return parse
    }

    /// OpenClicky's own plan answers run Codex in a scratch folder under the temporary
    /// directory; they are not the user's sessions.
    static func isOwnScratchRollout(cwd: String?) -> Bool {
        guard let cwd else { return false }
        let scratchRoot = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-plan-answers", isDirectory: true).path
        return cwd.hasPrefix(scratchRoot) || cwd.contains("/openclicky-plan-answers/")
    }

    // MARK: Pieces

    private static func records(in text: String) -> [[String: Any]] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return object as? [String: Any]
        }
    }

    private static func toolDetail(filePath: String?, command: String?) -> String? {
        if let filePath, !filePath.isEmpty { return URL(fileURLWithPath: filePath).lastPathComponent }
        if let command, !command.isEmpty { return firstLine(of: command, limit: detailLength).trimmingCharacters(in: .whitespaces) }
        return nil
    }

    /// Codex tool arguments are a JSON string: a `command` (array or string) or a path.
    private static func codexArgumentsDetail(_ arguments: Any?) -> String? {
        guard let string = arguments as? String, let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let parts = object["command"] as? [String] { return String(parts.joined(separator: " ").prefix(detailLength)).trimmingCharacters(in: .whitespaces) }
        if let command = object["command"] as? String { return firstLine(of: command, limit: detailLength).trimmingCharacters(in: .whitespaces) }
        if let path = (object["path"] ?? object["file_path"]) as? String { return URL(fileURLWithPath: path).lastPathComponent }
        return nil
    }

    private static func firstLine(of text: String, limit: Int) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(line.prefix(limit))
    }
}

// MARK: - The watcher

/// Where the two agents keep their session logs.
struct AgentLogRoots {
    var claudeProjects: URL
    var codexSessions: URL

    /// `$CLAUDE_CONFIG_DIR` (default `~/.claude`) and `~/.codex`.
    static var standard: AgentLogRoots {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeConfig = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".claude", isDirectory: true)
        return AgentLogRoots(
            claudeProjects: claudeConfig.appendingPathComponent("projects", isDirectory: true),
            codexSessions: home.appendingPathComponent(".codex/sessions", isDirectory: true)
        )
    }
}

/// One per app. Lists the logs written in the last ten minutes, reads the tail of each, and
/// polls: every 3 s while a Coding agents row is on screen, every 20 s while the component is
/// merely on (so the peek line can name a live session), never otherwise.
@MainActor
final class AgentSessionWatcher: ObservableObject {
    static let tailBytes = 65_536
    static let watchedInterval: TimeInterval = 3
    static let backgroundInterval: TimeInterval = 20

    /// Live first, then newest.
    @Published private(set) var sessions: [AgentSession] = []

    private let roots: AgentLogRoots
    private let now: () -> Date
    private var isEnabled = false
    private var watchers = 0
    private var timer: Timer?

    init(roots: AgentLogRoots, now: @escaping () -> Date = Date.init) {
        self.roots = roots
        self.now = now
    }

    var liveCount: Int { sessions.filter { $0.isLive(now: now()) }.count }

    /// "claude · editing Foo.swift" for the newest live session, for the island's peek line.
    var peekLine: String? {
        guard let live = sessions.first(where: { $0.isLive(now: now()) }) else { return nil }
        return "\(live.agent.displayName) · \(live.activity.line)"
    }

    var isPolling: Bool { timer != nil }
    var pollInterval: TimeInterval { watchers > 0 ? Self.watchedInterval : Self.backgroundInterval }

    /// The component's switch: on starts the slow poll, off stops everything and forgets.
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            refreshNow()
        } else {
            sessions = []
        }
        rebuildTimer()
    }

    /// A row appeared: poll fast while any is on screen.
    func beginWatching() {
        watchers += 1
        if watchers == 1 {
            if isEnabled { refreshNow() }
            rebuildTimer()
        }
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { rebuildTimer() }
    }

    /// One pass over both trees.
    func refreshNow() {
        let now = now()
        let cutoff = now.addingTimeInterval(-AgentSession.recentWindow)
        var found: [AgentSession] = []
        for file in recentFiles(under: roots.claudeProjects, suffix: ".jsonl", newerThan: cutoff) {
            let parse = AgentSessionParser.parseClaudeTail(tail(of: file.url))
            found.append(AgentSession(id: file.url.path, agent: .claudeCode, project: project(from: parse.cwd, fallback: file.url.deletingLastPathComponent().lastPathComponent), title: parse.title, activity: parse.activity, lastEventAt: file.modifiedAt))
        }
        for file in recentFiles(under: roots.codexSessions, suffix: ".jsonl", newerThan: cutoff) where file.url.lastPathComponent.hasPrefix("rollout-") {
            let parse = AgentSessionParser.parseCodexTail(tail(of: file.url))
            if AgentSessionParser.isOwnScratchRollout(cwd: parse.cwd) { continue }
            found.append(AgentSession(id: file.url.path, agent: .codex, project: project(from: parse.cwd, fallback: "codex"), title: parse.title, activity: parse.activity, lastEventAt: file.modifiedAt))
        }
        found.sort { a, b in
            let aLive = a.isLive(now: now), bLive = b.isLive(now: now)
            if aLive != bLive { return aLive }
            return a.lastEventAt > b.lastEventAt
        }
        if found != sessions { sessions = found }
    }

    // MARK: Pieces

    private func rebuildTimer() {
        timer?.invalidate()
        timer = nil
        guard isEnabled else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private struct RecentFile {
        let url: URL
        let modifiedAt: Date
    }

    private func recentFiles(under root: URL, suffix: String, newerThan cutoff: Date) -> [RecentFile] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [RecentFile] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasSuffix(suffix),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let modifiedAt = values.contentModificationDate, modifiedAt > cutoff else { continue }
            files.append(RecentFile(url: url, modifiedAt: modifiedAt))
        }
        return files
    }

    /// The last 64 KB of the log, from the first whole line.
    private func tail(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(Self.tailBytes) ? size - UInt64(Self.tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return "" }
        if start > 0, let newline = text.firstIndex(where: \.isNewline) { text = String(text[text.index(after: newline)...]) }
        return text
    }

    private func project(from cwd: String?, fallback: String) -> String {
        guard let cwd, !cwd.isEmpty else { return fallback }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}
