//
//  AgentSessionsTests.swift
//  OpenClickyTests
//
//  What a coding agent's own session log says it is doing, when a session counts as live, and
//  the watcher that lists them.
//

import Foundation
import Testing
@testable import OpenClicky

struct AgentSessionsTests {
    func claudeLine(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

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
        // The first 40 characters of the command, trailing space trimmed.
        #expect(bash.activity.line == "running: git status --short && git log --oneline")
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
