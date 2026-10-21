//
//  AgentsIslandView.swift
//  OpenClicky
//
//  The Coding agents component: up to three session rows (agent, project, what it is doing,
//  a running bar while live) on the left, Claude's two plan-limit rings on the right.
//

import SwiftUI

/// A plugin: the coding agents running on this Mac.
struct AgentsIslandComponent: IslandComponent {
    let id = IslandPluginRegistry.agentsID
    let title = "Coding agents"
    let symbolName = "terminal"
    let preferredHeight: CGFloat = 76
    let isPlugin = true
    let settingsDetail: String? = "Follows Claude Code and Codex sessions on this Mac from their own logs. macOS asks once to let OpenClicky read Claude Code's sign-in for the plan limits."
    func isAvailable(in context: IslandContext) -> Bool { true }
    @MainActor func makeView(companionManager: CompanionManager, model: NotchHUDModel) -> AnyView {
        let hud = companionManager.notchHUDManager
        return AnyView(AgentsIslandView(sessions: hud.agentSessions, usage: hud.claudeUsage, model: model))
    }
}

/// One session row, ready to draw.
struct AgentRow: Equatable, Identifiable {
    let id: String
    let agent: String
    let project: String
    let line: String
    let isLive: Bool
}

struct AgentsIslandView: View {
    @ObservedObject var sessions: AgentSessionWatcher
    @ObservedObject var usage: ClaudeUsageStore
    @ObservedObject var model: NotchHUDModel

    static let maximumRows = 3

    /// The first three sessions as rows; a stopped one says how long ago.
    static func rows(for sessions: [AgentSession], now: Date) -> [AgentRow] {
        sessions.prefix(maximumRows).map { session in
            let isLive = session.isLive(now: now)
            let line: String
            if isLive {
                line = session.activity.line
            } else {
                let minutes = max(0, Int(now.timeIntervalSince(session.lastEventAt) / 60))
                line = minutes == 0 ? "done just now" : "done \(minutes) min ago"
            }
            return AgentRow(id: session.id, agent: session.agent.displayName, project: session.project, line: line, isLive: isLive)
        }
    }

    static func overflowText(count: Int) -> String? {
        count > maximumRows ? "+\(count - maximumRows) more" : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            sessionsColumn
                .frame(maxWidth: .infinity, alignment: .topLeading)
            limits
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            sessions.beginWatching()
            usage.beginWatching()
        }
        .onDisappear {
            sessions.endWatching()
            usage.endWatching()
        }
    }

    private var sessionsColumn: some View {
        let now = Date()
        let rows = Self.rows(for: sessions.sessions, now: now)
        return VStack(alignment: .leading, spacing: 4) {
            if rows.isEmpty {
                Text("nothing running")
                    .font(.system(size: 13))
                    .foregroundColor(DS.HUD.text)
                Text("start claude or codex in a terminal and it shows up here")
                    .font(.system(size: 11))
                    .foregroundColor(DS.HUD.text3)
                    .lineLimit(2)
            } else {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(row.agent)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DS.HUD.text)
                            Text(row.project)
                                .font(.system(size: 11))
                                .foregroundColor(DS.HUD.text2)
                                .lineLimit(1)
                            Text(row.line)
                                .font(.system(size: 11))
                                .foregroundColor(row.isLive ? DS.HUD.text : DS.HUD.text3)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if row.isLive {
                            IslandIndeterminateBar()
                                .frame(height: 2)
                        }
                    }
                }
                if let overflow = Self.overflowText(count: sessions.sessions.count) {
                    Text(overflow)
                        .font(.system(size: 10))
                        .foregroundColor(DS.HUD.text3)
                }
            }
        }
    }

    @ViewBuilder private var limits: some View {
        switch usage.state {
        case .none:
            EmptyView()
        case .signInNeeded:
            limitsNote("sign in to claude to see limits")
        case .keychainRefused:
            limitsNote("allow keychain access to see limits")
        case .figures(let figures, let stale):
            HStack(spacing: 10) {
                UsageRing(label: "5 h", window: figures.fiveHour)
                UsageRing(label: "7 d", window: figures.sevenDay)
            }
            .opacity(stale ? 0.5 : 1)
        }
    }

    private func limitsNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(DS.HUD.text3)
            .frame(width: 96)
            .multilineTextAlignment(.trailing)
    }
}

/// One plan window: a ring with the percentage inside, the window's name and its reset under it.
private struct UsageRing: View {
    let label: String
    let window: UsageWindow

    private var color: Color {
        if window.fraction >= 1 { return DS.HUD.pointer }
        if window.fraction > 0.8 { return DS.Colors.warning }
        return DS.HUD.text
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(window.fraction, 0), 1)))
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(SystemStatsFormatter.percent(window.fraction))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.HUD.text)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 28, height: 28)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(DS.HUD.text2)
            Text(ClaudeUsagePolicy.resetText(until: window.resetsAt, now: Date()))
                .font(.system(size: 9))
                .foregroundColor(DS.HUD.text3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 78)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) window \(SystemStatsFormatter.percent(window.fraction)) used")
    }
}
