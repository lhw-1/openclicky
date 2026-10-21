# Island Coding Agents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An optional "Coding agents" component: what the Claude Code and Codex sessions on this Mac are doing right now (from their own logs), and Claude's plan limits as two rings.

**Architecture:** A pure parser per agent turns the tail of a session log into an `AgentSession`; a `@MainActor` watcher polls the two log trees (3 s while on screen, 20 s otherwise, only while the component is on); a usage store reads the Claude Code sign-in from the Keychain (at most every 30 min) and asks the usage endpoint every 5 min while on screen. The view is rows plus rings; the peek line names a live session.

**Tech Stack:** Swift 6 / SwiftUI, `FileManager`, `Security` (`SecItemCopyMatching`), `URLSession`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-21-island-components-design.md` (section "Coding agents").

## Global Constraints

- Deployment target macOS 14.2; Swift Testing; no new dependencies; no new entitlements.
- Session reading is local files only: `$CLAUDE_CONFIG_DIR` (default `~/.claude`) `projects/*/*.jsonl` and `~/.codex/sessions/**/rollout-*.jsonl`; at most the last 64 KB of a file; only files modified in the last 10 min; the component never writes there.
- OpenClicky's own Codex answers (rollouts whose `cwd` is under `<tmp>/openclicky-plan-answers/`) are not sessions.
- The agents component is never the moment's component (`contextualKey` ignores it).
- Copy lower-case and short: "nothing running", "start claude or codex in a terminal and it shows up here", "sign in to claude to see limits", "allow keychain access to see limits", "resets 2 h 10 m". Agent names "claude" / "codex"; SF Symbols only, no logos.
- Test command: the scratch runner `t.sh Suite[,Suite]` (xcodebuild test, `-only-testing:OpenClickyTests/<Suite>`).
- Commit messages describe OpenClicky's own features; end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Review Focus

1. A Claude log whose last assistant record has `stop_reason: end_turn` and a `text` block, modified 30 s ago: idle, not live, never "writing". Task 1.
2. A Claude log whose last records are `attachment` / `api-request` noise after the assistant's tool call: the activity is still the tool call. Task 1.
3. A log file that is modified every few seconds (a long tool run) but whose 64 KB tail holds no assistant record (one huge `api-request-blob` line): `.waiting`, not a crash or an empty row. Task 1.
4. The Keychain read refused once: no second prompt until the toggle flips or a relaunch. Task 3.
5. Two displays: one watcher, one usage store; closing the panel on one display while the other shows the component keeps polling. Task 4 (ref-counted `beginWatching`).

---

### Task 1: Sessions and the parsers

**Files:**
- Create: `macos/OpenClicky/OpenClicky/AgentSessions.swift`
- Test: `macos/OpenClicky/OpenClickyTests/AgentSessionsTests.swift`

**Interfaces:**
- Produces: `enum AgentKind: String, Codable { case claudeCode = "claude", codex }` with `var displayName: String` ("claude" / "codex"); `enum AgentActivity: Equatable { case tool(name: String, detail: String?), thinking, writing(String), waiting, idle; var line: String }` ("editing Foo.swift" for Edit/Write/MultiEdit with a file, "reading Foo.swift" for Read, "running: git status" for Bash/shell with a command, "<tool name lower-cased>" otherwise, "thinking", "writing", "waiting", "done"); `struct AgentSession: Equatable, Identifiable { let id: String; let agent: AgentKind; let project: String; let title: String?; let activity: AgentActivity; let lastEventAt: Date; static let liveWindow: TimeInterval = 120; static let recentWindow: TimeInterval = 600; func isLive(now: Date) -> Bool }` (live = `lastEventAt` within 120 s and `activity != .idle`); `struct AgentTailParse: Equatable { var activity: AgentActivity; var title: String?; var cwd: String? }`; `enum AgentSessionParser { static func parseClaudeTail(_ text: String) -> AgentTailParse; static func parseCodexTail(_ text: String) -> AgentTailParse; static func isOwnScratchRollout(cwd: String?) -> Bool }`.

- [ ] **Step 1: Write the failing tests** (fixtures are small JSONL strings built in the test):

```swift
struct AgentSessionsTests {
    func claudeLine(_ object: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! }
    func assistant(_ blocks: [[String: Any]], stopReason: String?, cwd: String = "/Users/me/Code/app") -> String {
        var message: [String: Any] = ["role": "assistant", "content": blocks]
        if let stopReason { message["stop_reason"] = stopReason }
        return claudeLine(["type": "assistant", "cwd": cwd, "message": message])
    }

    @Test func aClaudeToolCallReadsAsWhatItIsDoing() {
        let tail = [
            claudeLine(["type": "user", "cwd": "/Users/me/Code/app", "message": ["role": "user", "content": "fix it"]]),
            assistant([["type": "tool_use", "name": "Edit", "input": ["file_path": "/Users/me/Code/app/Sources/Hero.swift"]]], stopReason: "tool_use"),
            claudeLine(["type": "attachment", "attachment": [:]]),
            claudeLine(["type": "api-request", "requestId": "x"]),
        ].joined(separator: "\n")
        let parse = AgentSessionParser.parseClaudeTail(tail)
        #expect(parse.activity == .tool(name: "Edit", detail: "Hero.swift"))
        #expect(parse.activity.line == "editing Hero.swift")
        #expect(parse.cwd == "/Users/me/Code/app")
        let bash = AgentSessionParser.parseClaudeTail(assistant([["type": "tool_use", "name": "Bash", "input": ["command": "git status --short && git log --oneline -5"]]], stopReason: "tool_use"))
        #expect(bash.activity.line == "running: git status --short && git log --oneli")
    }

    @Test func aFinishedClaudeAnswerIsIdleAndAFollowUpPromptIsWaiting() {
        let finished = assistant([["type": "text", "text": "Done, the hero is blue."]], stopReason: "end_turn")
        #expect(AgentSessionParser.parseClaudeTail(finished).activity == .idle)
        let streaming = assistant([["type": "text", "text": "Let me look"]], stopReason: nil)
        #expect(AgentSessionParser.parseClaudeTail(streaming).activity == .writing("Let me look"))
        let thinking = assistant([["type": "thinking", "thinking": "hmm"]], stopReason: "tool_use")
        #expect(AgentSessionParser.parseClaudeTail(thinking).activity == .thinking)
        let followUp = [finished, claudeLine(["type": "user", "message": ["role": "user", "content": "now red"]])].joined(separator: "\n")
        #expect(AgentSessionParser.parseClaudeTail(followUp).activity == .waiting)
        let title = [claudeLine(["type": "ai-title", "aiTitle": "Blue hero"]), finished].joined(separator: "\n")
        #expect(AgentSessionParser.parseClaudeTail(title).title == "Blue hero")
    }

    @Test func noiseWithoutAnAssistantRecordIsWaitingAndBrokenLinesAreSkipped() {
        let tail = "not json at all\n" + claudeLine(["type": "api-request-blob", "cwd": "/x/y"]) + "\n{\"type\": \"progress\""
        let parse = AgentSessionParser.parseClaudeTail(tail)
        #expect(parse.activity == .waiting)
        #expect(parse.cwd == "/x/y")
    }

    @Test func codexRolloutsReadTheSameWay() {
        func codex(_ type: String, _ payload: [String: Any]) -> String {
            var payload = payload; payload["type"] = payload["type"] ?? type
            return claudeLine(["type": type == "session_meta" ? "session_meta" : (payload["type"] as? String == "task_complete" || payload["type"] as? String == "task_started" ? "event_msg" : "response_item"), "payload": payload])
        }
        let meta = claudeLine(["type": "session_meta", "payload": ["cwd": "/Users/me/Code/site", "id": "abc"]])
        let call = claudeLine(["type": "response_item", "payload": ["type": "function_call", "name": "shell", "arguments": "{\"command\":[\"npm\",\"test\"]}"]])
        let parse = AgentSessionParser.parseCodexTail([meta, call].joined(separator: "\n"))
        #expect(parse.cwd == "/Users/me/Code/site")
        #expect(parse.activity.line == "running: npm test")
        let done = claudeLine(["type": "event_msg", "payload": ["type": "task_complete", "last_agent_message": "ok"]])
        #expect(AgentSessionParser.parseCodexTail([meta, call, done].joined(separator: "\n")).activity == .idle)
        let reasoning = claudeLine(["type": "response_item", "payload": ["type": "reasoning", "summary": []]])
        #expect(AgentSessionParser.parseCodexTail(reasoning).activity == .thinking)
        let message = claudeLine(["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Here is the plan"]]]])
        #expect(AgentSessionParser.parseCodexTail(message).activity == .writing("Here is the plan"))
        let firstPrompt = claudeLine(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "make the site faster please"]]]])
        #expect(AgentSessionParser.parseCodexTail([meta, firstPrompt, call].joined(separator: "\n")).title == "make the site faster please")
        #expect(AgentSessionParser.isOwnScratchRollout(cwd: FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-plan-answers/abc").path))
        #expect(!AgentSessionParser.isOwnScratchRollout(cwd: "/Users/me/Code/site"))
    }

    @Test func aSessionIsLiveForTwoMinutesUnlessItIsIdle() {
        let now = Date()
        let working = AgentSession(id: "a", agent: .claudeCode, project: "app", title: nil, activity: .thinking, lastEventAt: now.addingTimeInterval(-119))
        #expect(working.isLive(now: now))
        #expect(!AgentSession(id: "b", agent: .claudeCode, project: "app", title: nil, activity: .thinking, lastEventAt: now.addingTimeInterval(-121)).isLive(now: now))
        #expect(!AgentSession(id: "c", agent: .codex, project: "app", title: nil, activity: .idle, lastEventAt: now).isLive(now: now))
    }
}
```

- [ ] **Step 2: Run** `AgentSessionsTests`. Expected: build FAILS.
- [ ] **Step 3: Implement** `AgentSessions.swift`. Claude: walk the lines, `JSONSerialization` each (skip failures), remember `cwd` from any record, `aiTitle` from `ai-title`, the last `assistant` record (its `message.stop_reason` and last content block) and whether a `user` record came after it; `.idle` when stop_reason is `end_turn` or `stop_sequence`; tool detail: `input.file_path` → last path component, else `input.command` → first 40 characters, else nil. Codex: `session_meta.payload.cwd`; title from the first `response_item` message with role `user` (text of the first `input_text` content, trimmed to 60); activity from the last of `function_call` (`name`, `arguments` JSON string: `command` array joined by spaces or string, or `path`/`file_path`), `custom_tool_call` (`name`, `input` first 40), `reasoning` → thinking, assistant `message` → writing (first `output_text`), user `message` → waiting; `event_msg` `task_complete` after all of those → idle, `task_started` → waiting. `AgentActivity.line` maps Edit/Write/MultiEdit/NotebookEdit → "editing", Read → "reading", Bash/shell/exec → "running: ", Grep/Glob → "searching", WebFetch/WebSearch → "browsing", else the lower-cased name, with the detail appended after a space when present (the "running: " form has no extra space).
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `Coding agents: what a Claude Code or Codex session log says it is doing`.

### Task 2: The watcher

**Files:**
- Modify: `macos/OpenClicky/OpenClicky/AgentSessions.swift`
- Test: `macos/OpenClicky/OpenClickyTests/AgentSessionsTests.swift`

**Interfaces:**
- Produces: `struct AgentLogRoots { var claudeProjects: URL; var codexSessions: URL; static var standard: AgentLogRoots }` (`CLAUDE_CONFIG_DIR` honoured); `@MainActor final class AgentSessionWatcher: ObservableObject { @Published private(set) var sessions: [AgentSession]; var liveCount: Int; var peekLine: String? ("claude · editing Foo.swift" for the newest live session); init(roots: AgentLogRoots, now: @escaping () -> Date = Date.init); func refreshNow(); func setEnabled(_:); func beginWatching(); func endWatching(); var pollInterval: TimeInterval (3 while watched, 20 while enabled only); var isPolling: Bool; static let tailBytes = 65_536 }` — `refreshNow` lists `claudeProjects/*/*.jsonl` and `codexSessions/**/rollout-*.jsonl`, keeps files with `contentModificationDate` within 10 min, reads the last 64 KB, parses, drops own-scratch rollouts, sorts live first then newest.

- [ ] **Step 1: Write the failing test**:

```swift
@MainActor @Test func theWatcherListsRecentLogsLiveFirstAndSkipsItsOwnScratchRuns() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agents-tests-\(UUID().uuidString)", isDirectory: true)
    let claude = root.appendingPathComponent("claude/projects/-Users-me-app", isDirectory: true)
    let codex = root.appendingPathComponent("codex/sessions/2026/10/21", isDirectory: true)
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let now = Date()
    try assistant([["type": "tool_use", "name": "Read", "input": ["file_path": "/Users/me/app/README.md"]]], stopReason: "tool_use").write(to: claude.appendingPathComponent("live.jsonl"), atomically: true, encoding: .utf8)
    try assistant([["type": "text", "text": "done"]], stopReason: "end_turn").write(to: claude.appendingPathComponent("done.jsonl"), atomically: true, encoding: .utf8)
    let stale = claude.appendingPathComponent("stale.jsonl")
    try assistant([["type": "thinking", "thinking": "x"]], stopReason: nil).write(to: stale, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-900)], ofItemAtPath: stale.path)
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-plan-answers/x").path
    try claudeLine(["type": "session_meta", "payload": ["cwd": scratch]]).write(to: codex.appendingPathComponent("rollout-own.jsonl"), atomically: true, encoding: .utf8)
    try claudeLine(["type": "session_meta", "payload": ["cwd": "/Users/me/site"]]).write(to: codex.appendingPathComponent("rollout-site.jsonl"), atomically: true, encoding: .utf8)
    let watcher = AgentSessionWatcher(roots: AgentLogRoots(claudeProjects: root.appendingPathComponent("claude/projects"), codexSessions: root.appendingPathComponent("codex/sessions")), now: { now })
    watcher.refreshNow()
    #expect(watcher.sessions.map(\.project) == ["app", "app", "site"])
    #expect(watcher.sessions[0].activity.line == "reading README.md")
    #expect(watcher.liveCount == 1)
    #expect(watcher.peekLine == "claude · reading README.md")
    #expect(!watcher.isPolling)
    watcher.setEnabled(true)
    #expect(watcher.isPolling && watcher.pollInterval == 20)
    watcher.beginWatching()
    #expect(watcher.pollInterval == 3)
    watcher.endWatching()
    #expect(watcher.pollInterval == 20)
    watcher.setEnabled(false)
    #expect(!watcher.isPolling)
}
```
(The Codex session without activity records parses as `.waiting`; a waiting record with `lastEventAt` now counts as live? No: `.waiting` is live. Expect `liveCount == 2`? Rule: `.waiting` means the model is working on a prompt, so it is live. Set the expectation to `liveCount == 2` and `peekLine` to the newest live one; make the Claude live file the newer by writing it last with `modificationDate` now + 1.)

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** with `FileManager.enumerator` (`.contentModificationDateKey`), a `FileHandle` seek to `max(0, size - 64 KB)`, a `Timer` rebuilt when the interval changes.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `Coding agents: a watcher that polls the session logs only while the component is on`.

### Task 3: Claude's plan limits

**Files:**
- Create: `macos/OpenClicky/OpenClicky/ClaudeUsage.swift`
- Test: `macos/OpenClicky/OpenClickyTests/ClaudeUsageTests.swift`

**Interfaces:**
- Produces: `struct UsageWindow: Equatable { var fraction: Double; var resetsAt: Date? }`; `struct ClaudeUsage: Equatable { var fiveHour: UsageWindow; var sevenDay: UsageWindow; static func parse(_ data: Data) -> ClaudeUsage? }` (`utilization` 0…100 → fraction; `resets_at` ISO 8601 with fractional seconds allowed); `enum ClaudeUsageState: Equatable { case none, signInNeeded, keychainRefused, figures(ClaudeUsage, stale: Bool) }`; `enum ClaudeCredentialResult { case token(String), missing, refused }`; `protocol ClaudeCredentialReading { func readAccessToken() -> ClaudeCredentialResult }`; `struct KeychainClaudeCredentialReader: ClaudeCredentialReading` (service `Claude Code-credentials`, `SecItemCopyMatching`, `errSecItemNotFound` → missing; `errSecAuthFailed` / `errSecInteractionNotAllowed` / `errSecUserCanceled` → refused; JSON `claudeAiOauth.accessToken`); `enum ClaudeUsagePolicy { static let fetchInterval: TimeInterval = 300; static let keychainInterval: TimeInterval = 1800; static func shouldReadKeychain(lastRead: Date?, now: Date) -> Bool; static func resetText(until: Date?, now: Date) -> String }` ("resets 2 h 10 m", "resets 35 m", "resets soon" under a minute, "" for nil); `@MainActor final class ClaudeUsageStore: ObservableObject { @Published private(set) var state: ClaudeUsageState; init(credentials: any ClaudeCredentialReading, transport: @escaping (String) async -> (Data, Int)?, now: @escaping () -> Date = Date.init); func beginWatching(); func endWatching(); func setEnabled(_:) (false resets `keychainRefused` and the last-read clock); func refreshNow() async }`.

- [ ] **Step 1: Write the failing tests**:

```swift
struct ClaudeUsageTests {
    let reply = Data(#"{"five_hour":{"utilization":38.0,"resets_at":"2026-10-21T15:00:00.000000+00:00"},"seven_day":{"utilization":37.0,"resets_at":"2026-10-25T09:00:00+00:00"},"extra_usage":{}}"#.utf8)

    @Test func theReplyBecomesTwoWindows() throws {
        let usage = try #require(ClaudeUsage.parse(reply))
        #expect(usage.fiveHour.fraction == 0.38)
        #expect(usage.sevenDay.fraction == 0.37)
        #expect(usage.fiveHour.resetsAt == ISO8601DateFormatter().date(from: "2026-10-21T15:00:00Z"))
        #expect(ClaudeUsage.parse(Data("{}".utf8)) == nil)
    }

    @Test func resetsReadShort() {
        let now = Date()
        #expect(ClaudeUsagePolicy.resetText(until: now.addingTimeInterval(2 * 3600 + 10 * 60 + 5), now: now) == "resets 2 h 10 m")
        #expect(ClaudeUsagePolicy.resetText(until: now.addingTimeInterval(35 * 60), now: now) == "resets 35 m")
        #expect(ClaudeUsagePolicy.resetText(until: now.addingTimeInterval(30), now: now) == "resets soon")
        #expect(ClaudeUsagePolicy.resetText(until: nil, now: now) == "")
        #expect(ClaudeUsagePolicy.shouldReadKeychain(lastRead: nil, now: now))
        #expect(!ClaudeUsagePolicy.shouldReadKeychain(lastRead: now.addingTimeInterval(-1799), now: now))
        #expect(ClaudeUsagePolicy.shouldReadKeychain(lastRead: now.addingTimeInterval(-1801), now: now))
    }

    @MainActor @Test func theStoreTellsSignInFromARefusedKeychainFromStaleFigures() async {
        final class Reader: ClaudeCredentialReading { var result: ClaudeCredentialResult = .missing; var reads = 0; func readAccessToken() -> ClaudeCredentialResult { reads += 1; return result } }
        let reader = Reader()
        var status = 200
        var data = reply
        let store = ClaudeUsageStore(credentials: reader, transport: { _ in (data, status) })
        store.setEnabled(true)
        await store.refreshNow()
        #expect(store.state == .signInNeeded)
        reader.result = .refused
        await store.refreshNow()
        #expect(store.state == .keychainRefused)
        await store.refreshNow()
        #expect(reader.reads == 2)             // a refusal is remembered: no second prompt
        store.setEnabled(false); store.setEnabled(true)
        reader.result = .token("t")
        await store.refreshNow()
        guard case .figures(let usage, let stale) = store.state else { Issue.record("no figures"); return }
        #expect(usage.fiveHour.fraction == 0.38 && !stale)
        status = 500
        await store.refreshNow()
        #expect(store.state == .figures(usage, stale: true))
        status = 401
        await store.refreshNow()
        #expect(store.state == .signInNeeded)
        _ = data
    }
}
```

- [ ] **Step 2: Run.** Expected: build FAILS.
- [ ] **Step 3: Implement**. The store: `refreshNow` reads the Keychain when `shouldReadKeychain` says so or no token is cached (and not refused); GET `https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`, `Accept: application/json`; 200 + parse → figures; 401 → signInNeeded and drop the cached token; other failures → figures stale (or `.none` if nothing yet). `beginWatching` fetches now and every 5 min while watched (ref-counted like the stats store). The real transport uses `URLSession.shared`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `Coding agents: Claude's plan limits with the sign-in Claude Code already has`.

### Task 4: The component, the view, the peek line

**Files:**
- Create: `macos/OpenClicky/OpenClicky/AgentsIslandView.swift`
- Modify: `IslandComponents.swift` (registry; `IslandComponent.settingsDetail`), `NotchHUD.swift` (manager owns `agentSessions`, `claudeUsage`; enabling follows the switch; debug hooks), `NotchHUDPanels.swift` (`NotchPeekLine.shortStatusText(companionManager:agentLine:)`), `Dictation/UI/SettingsGeneralPage.swift` (switch row shows `settingsDetail`), `UITour.swift` (shot `04e-panel-agents`), `AGENTS.md`
- Test: `IslandComponentSelectorTests.swift`, `AgentSessionsTests.swift`

**Interfaces:**
- Produces: `struct AgentsIslandComponent: IslandComponent` (id `agents`, "Coding agents", `terminal`, 76, optional, always available, `settingsDetail` = "Follows Claude Code and Codex sessions on this Mac from their own logs. macOS asks once to let OpenClicky read Claude Code's sign-in for the plan limits."); `protocol IslandComponent { var settingsDetail: String? { get } }` default nil; `struct AgentsIslandView: View` with `static func rows(for sessions: [AgentSession], now: Date) -> [AgentRow]` (`AgentRow { id, agent: String, project, line, isLive }`, at most 3) and `static func overflowText(count: Int) -> String?` ("+2 more"); `NotchPeekLine.shortStatusText(companionManager:agentLine: String?)` returns `agentLine` when given; `NotchHUDManager.agentSessions: AgentSessionWatcher`, `claudeUsage: ClaudeUsageStore`, `func syncOptionalComponents()` (called from the UserDefaults observer and at start: `agentSessions.setEnabled(...)`, `claudeUsage.setEnabled(...)` from the enabled set); `debugSetAgentSessions(_:)` (Debug).

- [ ] **Step 1: Write the failing tests**:

```swift
// AgentSessionsTests
@Test func rowsShowThreeSessionsAndCountTheRest() {
    let now = Date()
    let sessions = (0..<5).map { AgentSession(id: "\($0)", agent: $0 % 2 == 0 ? .claudeCode : .codex, project: "p\($0)", title: nil, activity: $0 < 2 ? .thinking : .idle, lastEventAt: now.addingTimeInterval(Double(-60 * $0))) }
    let rows = AgentsIslandView.rows(for: sessions, now: now)
    #expect(rows.count == 3)
    #expect(rows[0].agent == "claude" && rows[0].isLive && rows[0].line == "thinking")
    #expect(rows[2].line == "done 2 min ago")
    #expect(AgentsIslandView.overflowText(count: 5) == "+2 more")
    #expect(AgentsIslandView.overflowText(count: 3) == nil)
}
// IslandComponentSelectorTests: theRealRegistryListsTheBuiltInsThenTheExtras → ids [..., "system", "shelf", "agents"], heights [45, 52, 52, 70, 84, 76], optional [false, false, false, true, true, true]; and
@Test func thePeekLineNamesALiveSessionWhenGivenOne() {
    #expect(NotchPeekLine.shortStatusText(companionManager: nil, agentLine: "claude · thinking") == "claude · thinking")
}
```
(Give `shortStatusText` an optional `companionManager` for the test? No: keep the signature `shortStatusText(companionManager: CompanionManager, agentLine: String?)` and test the pure piece `NotchPeekLine.peekText(status: "pointer follows you", agentLine: "claude · thinking") == "claude · thinking"` and `peekText(status:agentLine: nil) == "pointer follows you"` instead.)

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement**. View: `HStack(alignment: .top)`: left `VStack` of rows (agent name 11 pt semibold text, project text2, line text, a 2 pt `IslandIndeterminateBar` under a live row; "done <n> min ago" text3 for a recent one; overflow text3; empty state "nothing running" + text3 hint); right: rings (28 pt, like System's; amber above 0.8, `DS.HUD.pointer` at 1.0) labelled "5 h" / "7 d" with the reset text under, or the state's line ("sign in to claude to see limits" / "allow keychain access to see limits") in text3; `onAppear` → `agentSessions.beginWatching()`, `claudeUsage.beginWatching()`; `onDisappear` the reverse. The peek line passes `companionManager.notchHUDManager.agentSessions.peekLine` when the agents component is enabled. The tour injects two sessions through `debugSetAgentSessions`, shows `agents`, shoots `04e-panel-agents`, resets.
- [ ] **Step 4: Run** the suites; build Debug; run the island tour and look at `04e-panel-agents`. Expected: PASS; two rows and the rings (or the sign-in line) under the band.
- [ ] **Step 5: Commit** `Island: a Coding agents component; the peek line names a live session`.
