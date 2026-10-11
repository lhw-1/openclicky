//
//  AnswerProviderPlanTests.swift
//  OpenClickyTests
//
//  The plan CLIs (Claude Code, Codex): how each call is built, how their output is read, how
//  failures become sentences, and how the status checks read `claude auth status` / `codex login
//  status`. A fake runner stands in for every process; nothing here starts a CLI, uses the network,
//  or reads files outside the temporary directory.
//

import Foundation
import Testing
@testable import OpenClicky

/// Records each call and answers with canned output. For Codex it writes the canned last message
/// to the `-o` path, the way the real CLI does.
private final class FakePlanCLIProcessRunner: PlanCLIProcessRunning, @unchecked Sendable {
    struct RecordedCall {
        let executablePath: String
        let arguments: [String]
        let standardInput: Data?
        let workingDirectory: URL
        let environment: [String: String]
        let timeoutSeconds: TimeInterval
    }

    private let lock = NSLock()
    private var recordedCalls: [RecordedCall] = []
    private let standardOutputChunks: [String]
    private let standardError: String
    private let exitStatus: Int32
    private let timedOut: Bool
    private let lastMessageFileContents: String?
    private var workingDirectoryExistedDuringRun = false

    init(standardOutputChunks: [String] = [], standardError: String = "", exitStatus: Int32 = 0, timedOut: Bool = false, lastMessageFileContents: String? = nil) {
        self.standardOutputChunks = standardOutputChunks
        self.standardError = standardError
        self.exitStatus = exitStatus
        self.timedOut = timedOut
        self.lastMessageFileContents = lastMessageFileContents
    }

    var calls: [RecordedCall] {
        lock.lock(); defer { lock.unlock() }
        return recordedCalls
    }

    var sawWorkingDirectoryDuringRun: Bool {
        lock.lock(); defer { lock.unlock() }
        return workingDirectoryExistedDuringRun
    }

    func run(
        executablePath: String,
        arguments: [String],
        standardInput: Data?,
        workingDirectory: URL,
        environment: [String: String],
        timeoutSeconds: TimeInterval,
        onStandardOutputChunk: (@Sendable (Data) -> Void)?
    ) async throws -> PlanCLIProcessOutput {
        lock.withLock {
            recordedCalls.append(RecordedCall(executablePath: executablePath, arguments: arguments, standardInput: standardInput, workingDirectory: workingDirectory, environment: environment, timeoutSeconds: timeoutSeconds))
            workingDirectoryExistedDuringRun = FileManager.default.fileExists(atPath: workingDirectory.path)
        }

        if let lastMessageFileContents, let outputFlagIndex = arguments.firstIndex(of: "-o"), outputFlagIndex + 1 < arguments.count {
            try lastMessageFileContents.write(toFile: arguments[outputFlagIndex + 1], atomically: true, encoding: .utf8)
        }
        for chunk in standardOutputChunks { onStandardOutputChunk?(Data(chunk.utf8)) }
        return PlanCLIProcessOutput(
            exitStatus: exitStatus,
            standardOutput: Data(standardOutputChunks.joined().utf8),
            standardError: Data(standardError.utf8),
            timedOut: timedOut
        )
    }
}

/// Collects the chunks a provider hands to `onTextChunk`.
private final class TextChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedChunks: [String] = []
    func append(_ chunk: String) { lock.lock(); recordedChunks.append(chunk); lock.unlock() }
    var chunks: [String] { lock.lock(); defer { lock.unlock() }; return recordedChunks }
}

private func sampleRequest(history: [AnswerRequest.Turn] = []) -> AnswerRequest {
    AnswerRequest(
        images: [AnswerRequest.Image(data: Data([0x89, 0x50, 0x4E, 0x47]), label: "Screen 1 of 1 (cursor here)", mediaType: "image/png")],
        systemPrompt: "answer in lowercase",
        history: history,
        userPrompt: "what color is this square? answer in one word",
        tools: []
    )
}

private func jsonLine(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
}

private func textDeltaLine(_ text: String) -> String {
    jsonLine(["type": "stream_event", "parent_tool_use_id": NSNull(), "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]]])
}

private func value(after flag: String, in arguments: [String]) -> String? {
    guard let flagIndex = arguments.firstIndex(of: flag), flagIndex + 1 < arguments.count else { return nil }
    return arguments[flagIndex + 1]
}

struct AnswerProviderPlanTests {

    // MARK: Claude Code — the call

    @Test func claudeCodeRunsOneTurnWithNoToolsAndTheRequestsSystemPrompt() {
        let arguments = ClaudeCodeAnswerProvider.commandLineArguments(model: nil, systemPrompt: "answer in lowercase")
        #expect(arguments.first == "-p")
        #expect(value(after: "--input-format", in: arguments) == "stream-json")
        #expect(value(after: "--output-format", in: arguments) == "stream-json")
        #expect(arguments.contains("--verbose"))
        #expect(arguments.contains("--include-partial-messages"))
        #expect(value(after: "--tools", in: arguments) == "")
        #expect(value(after: "--permission-mode", in: arguments) == "dontAsk")
        #expect(value(after: "--permission-prompts", in: arguments) == "none")
        #expect(value(after: "--system-prompt", in: arguments) == "answer in lowercase")
        #expect(!arguments.contains("--append-system-prompt"))
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(!arguments.contains("--model"))
        #expect(!arguments.contains("--dangerously-skip-permissions"))
    }

    @Test func claudeCodePassesAModelOnlyWhenOneIsNamed() {
        #expect(value(after: "--model", in: ClaudeCodeAnswerProvider.commandLineArguments(model: "sonnet", systemPrompt: "")) == "sonnet")
        #expect(!ClaudeCodeAnswerProvider.commandLineArguments(model: "  ", systemPrompt: "").contains("--model"))
    }

    @Test func claudeCodeSendsLabelledBase64ImagesAndHistoryInOneUserMessage() throws {
        let request = sampleRequest(history: [AnswerRequest.Turn(user: "what is this app", assistant: "it's finder")])
        let messageData = ClaudeCodeAnswerProvider.standardInputMessage(for: request)
        #expect(messageData.last == UInt8(ascii: "\n"))
        let message = try #require(try JSONSerialization.jsonObject(with: messageData) as? [String: Any])
        #expect(message["type"] as? String == "user")
        let innerMessage = try #require(message["message"] as? [String: Any])
        #expect(innerMessage["role"] as? String == "user")
        let contentBlocks = try #require(innerMessage["content"] as? [[String: Any]])
        #expect(contentBlocks.count == 4)
        #expect((contentBlocks[0]["text"] as? String)?.contains("User: what is this app\nYou: it's finder") == true)
        #expect(contentBlocks[1]["text"] as? String == "Screen 1 of 1 (cursor here)")
        let imageSource = try #require(contentBlocks[2]["source"] as? [String: Any])
        #expect(contentBlocks[2]["type"] as? String == "image")
        #expect(imageSource["type"] as? String == "base64")
        #expect(imageSource["media_type"] as? String == "image/png")
        #expect(imageSource["data"] as? String == Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
        #expect(contentBlocks[3]["text"] as? String == "what color is this square? answer in one word")
    }

    @Test func claudeCodeWithoutHistoryHasNoHistoryBlock() throws {
        let messageData = ClaudeCodeAnswerProvider.standardInputMessage(for: sampleRequest())
        let message = try #require(try JSONSerialization.jsonObject(with: messageData) as? [String: Any])
        let contentBlocks = try #require((message["message"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(contentBlocks.count == 3)
    }

    // MARK: Claude Code — reading the stream

    @Test func claudeCodeStreamsTextDeltasAndReturnsTheResult() async throws {
        let assistantLine = jsonLine(["type": "assistant", "message": ["content": [["type": "text", "text": "red square"]]]])
        let resultLine = jsonLine(["type": "result", "subtype": "success", "is_error": false, "result": "red square"])
        let fullOutput = jsonLine(["type": "system", "subtype": "init"]) + textDeltaLine("red") + textDeltaLine(" square") + assistantLine + resultLine
        // Split mid-line, as pipe reads do.
        let splitIndex = fullOutput.index(fullOutput.startIndex, offsetBy: 70)
        let runner = FakePlanCLIProcessRunner(standardOutputChunks: [String(fullOutput[..<splitIndex]), String(fullOutput[splitIndex...])])
        let provider = ClaudeCodeAnswerProvider(executablePath: "/fake/bin/claude", model: "haiku", processRunner: runner)
        let recorder = TextChunkRecorder()

        let result = try await provider.answer(sampleRequest()) { recorder.append($0) }

        #expect(result == AnswerResult(text: "red square", toolCalls: []))
        #expect(recorder.chunks == ["red", " square"])
        let call = try #require(runner.calls.first)
        #expect(call.executablePath == "/fake/bin/claude")
        #expect(call.timeoutSeconds == 90)
        #expect(value(after: "--model", in: call.arguments) == "haiku")
        #expect(call.standardInput == ClaudeCodeAnswerProvider.standardInputMessage(for: sampleRequest()))
        // A fresh scratch folder under the temporary directory, removed afterwards.
        #expect(call.workingDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(runner.sawWorkingDirectoryDuringRun)
        #expect(!FileManager.default.fileExists(atPath: call.workingDirectory.path))
        #expect(call.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(call.environment["PATH"]?.hasPrefix("/fake/bin:") == true)
    }

    @Test func claudeCodeStreamParserFallsBackToStreamedTextAndToTheAssistantMessage() {
        let streamOnlyParser = ClaudeCodeStreamParser()
        _ = streamOnlyParser.consume(Data((textDeltaLine("blue")).utf8))
        #expect(streamOnlyParser.summary.streamedText == "blue")
        #expect(streamOnlyParser.summary.resultText == nil)

        let noPartialsParser = ClaudeCodeStreamParser()
        _ = noPartialsParser.consume(Data(jsonLine(["type": "assistant", "message": ["content": [["type": "text", "text": "green"]]]]).utf8))
        #expect(noPartialsParser.summary.streamedText == "green")
    }

    @Test func claudeCodeStreamParserHandlesALastLineWithoutANewline() {
        let parser = ClaudeCodeStreamParser()
        var unterminatedLine = textDeltaLine("tail")
        unterminatedLine.removeLast()
        #expect(parser.consume(Data(unterminatedLine.utf8)).isEmpty)
        #expect(parser.finish() == ["tail"])
    }

    @Test func claudeCodeStreamParserIgnoresSubagentTextAndNonJSONLines() {
        let parser = ClaudeCodeStreamParser()
        let subagentLine = jsonLine(["type": "stream_event", "parent_tool_use_id": "toolu_1", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "inner"]]])
        #expect(parser.consume(Data((subagentLine + "not json\n" + textDeltaLine("outer")).utf8)) == ["outer"])
    }

    @Test func claudeCodeErrorResultBecomesASignInSentence() async {
        let output = jsonLine(["type": "assistant", "error": "authentication_failed", "message": ["content": [["type": "text", "text": "Not logged in · Please run /login"]]]])
            + jsonLine(["type": "result", "subtype": "success", "is_error": true, "result": "Not logged in · Please run /login"])
        let runner = FakePlanCLIProcessRunner(standardOutputChunks: [output], exitStatus: 1)
        let provider = ClaudeCodeAnswerProvider(executablePath: "/fake/claude", processRunner: runner)

        await #expect(throws: AnswerProviderError(source: .claudeCodePlan, status: 0, message: "Claude Code is signed out. Open Terminal, run claude, and sign in with your Claude account.")) {
            _ = try await provider.answer(sampleRequest()) { _ in }
        }
    }

    @Test func claudeCodeErrorSubtypeKeepsTheCLIsReason() throws {
        let parser = ClaudeCodeStreamParser()
        _ = parser.consume(Data(jsonLine(["type": "result", "subtype": "error_during_execution", "is_error": true, "errors": ["overloaded"]]).utf8))
        let output = PlanCLIProcessOutput(exitStatus: 1, standardOutput: Data(), standardError: Data(), timedOut: false)
        #expect(throws: AnswerProviderError(source: .claudeCodePlan, status: 0, message: "Claude Code couldn't answer: overloaded")) {
            _ = try ClaudeCodeAnswerProvider.answerText(from: parser.summary, output: output, timeoutSeconds: 90)
        }
    }

    @Test func claudeCodeNonZeroExitWithoutEventsUsesStderrOrTheStatus() {
        let emptySummary = ClaudeCodeStreamSummary()
        let withStderr = PlanCLIProcessOutput(exitStatus: 1, standardOutput: Data(), standardError: Data("warming up\n[claude-code:unrecognized_model] bad model\n".utf8), timedOut: false)
        #expect(throws: AnswerProviderError(source: .claudeCodePlan, status: 0, message: "Claude Code couldn't answer: [claude-code:unrecognized_model] bad model")) {
            _ = try ClaudeCodeAnswerProvider.answerText(from: emptySummary, output: withStderr, timeoutSeconds: 90)
        }
        let silent = PlanCLIProcessOutput(exitStatus: 2, standardOutput: Data(), standardError: Data(), timedOut: false)
        #expect(throws: AnswerProviderError(source: .claudeCodePlan, status: 0, message: "Claude Code stopped with exit status 2.")) {
            _ = try ClaudeCodeAnswerProvider.answerText(from: emptySummary, output: silent, timeoutSeconds: 90)
        }
    }

    @Test func claudeCodeTimeoutAndEmptyAnswerAreErrors() {
        let timedOut = PlanCLIProcessOutput(exitStatus: 15, standardOutput: Data(), standardError: Data(), timedOut: true)
        #expect(throws: AnswerProviderError(source: .claudeCodePlan, status: 0, message: "Claude Code took longer than 90 seconds to answer.")) {
            _ = try ClaudeCodeAnswerProvider.answerText(from: ClaudeCodeStreamSummary(), output: timedOut, timeoutSeconds: 90)
        }
        let finishedQuietly = PlanCLIProcessOutput(exitStatus: 0, standardOutput: Data(), standardError: Data(), timedOut: false)
        #expect(throws: AnswerProviderError(source: .claudeCodePlan, status: 0, message: "Claude Code finished without an answer.")) {
            _ = try ClaudeCodeAnswerProvider.answerText(from: ClaudeCodeStreamSummary(), output: finishedQuietly, timeoutSeconds: 90)
        }
    }

    // MARK: Codex — the call

    @Test func codexRunsReadOnlyEphemeralWithToolsOffAndImagesAttached() {
        let arguments = CodexAnswerProvider.commandLineArguments(
            model: nil,
            systemPrompt: "answer in lowercase",
            imageFilePaths: ["/scratch/image-1.png", "/scratch/image-2.jpg"],
            outputFilePath: "/scratch/last-message.txt",
            workingDirectoryPath: "/scratch"
        )
        #expect(arguments.first == "exec")
        #expect(arguments.last == "-")
        for flag in ["--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--json"] {
            #expect(arguments.contains(flag))
        }
        #expect(value(after: "--sandbox", in: arguments) == "read-only")
        #expect(value(after: "-C", in: arguments) == "/scratch")
        #expect(value(after: "-o", in: arguments) == "/scratch/last-message.txt")
        let imagePaths = arguments.indices.filter { arguments[$0] == "-i" }.map { arguments[$0 + 1] }
        #expect(imagePaths == ["/scratch/image-1.png", "/scratch/image-2.jpg"])
        let disabledFeatures = arguments.indices.filter { arguments[$0] == "--disable" }.map { arguments[$0 + 1] }
        #expect(disabledFeatures.contains("shell_tool") && disabledFeatures.contains("unified_exec") && disabledFeatures.contains("plugins"))
        let configOverrides = arguments.indices.filter { arguments[$0] == "-c" }.map { arguments[$0 + 1] }
        #expect(configOverrides.contains("web_search=\"disabled\""))
        #expect(configOverrides.contains("developer_instructions=\"answer in lowercase\""))
        #expect(!arguments.contains("-m"))
        #expect(!arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    @Test func codexPassesAModelAndSkipsAnEmptySystemPrompt() {
        let arguments = CodexAnswerProvider.commandLineArguments(model: "gpt-5.5", systemPrompt: " ", imageFilePaths: [], outputFilePath: "/o", workingDirectoryPath: "/w")
        #expect(value(after: "-m", in: arguments) == "gpt-5.5")
        #expect(!arguments.contains { $0.hasPrefix("developer_instructions=") })
        #expect(!arguments.contains("-i"))
    }

    @Test func codexSystemPromptIsEscapedAsATOMLString() {
        #expect(CodexAnswerProvider.tomlBasicString("say \"hi\"\nthen C:\\path\tend\u{1}") == "\"say \\\"hi\\\"\\nthen C:\\\\path\\tend\\u0001\"")
        #expect(CodexAnswerProvider.tomlBasicString("café ✓") == "\"café ✓\"")
    }

    @Test func codexPromptFoldsHistoryAndNamesTheImagesInOrder() {
        var request = sampleRequest(history: [AnswerRequest.Turn(user: "hi", assistant: "hello")])
        request.images.append(AnswerRequest.Image(data: Data([1]), label: "Screen 2 of 2", mediaType: "image/jpeg"))
        #expect(CodexAnswerProvider.promptText(for: request) == """
        Earlier in this conversation:
        User: hi
        You: hello

        Attached images, in order:
        1. Screen 1 of 1 (cursor here)
        2. Screen 2 of 2

        what color is this square? answer in one word
        """)
        #expect(CodexAnswerProvider.promptText(for: AnswerRequest(images: [], systemPrompt: "", history: [], userPrompt: "just this", tools: [])) == "just this")
    }

    // MARK: Codex — reading the result

    @Test func codexReadsTheLastMessageFileAndCleansUp() async throws {
        let runner = FakePlanCLIProcessRunner(
            standardOutputChunks: [jsonLine(["type": "item.completed", "item": ["type": "agent_message", "text": "red"]])],
            lastMessageFileContents: "red\n"
        )
        let provider = CodexAnswerProvider(executablePath: "/fake/bin/codex", processRunner: runner)
        let recorder = TextChunkRecorder()

        let result = try await provider.answer(sampleRequest()) { recorder.append($0) }

        #expect(result == AnswerResult(text: "red", toolCalls: []))
        #expect(recorder.chunks == ["red"])
        let call = try #require(runner.calls.first)
        #expect(call.timeoutSeconds == 120)
        #expect(String(decoding: call.standardInput ?? Data(), as: UTF8.self).hasSuffix("what color is this square? answer in one word"))
        let imagePath = try #require(value(after: "-i", in: call.arguments))
        #expect(imagePath.hasPrefix(call.workingDirectory.path) && imagePath.hasSuffix(".png"))
        #expect(value(after: "-o", in: call.arguments)?.hasPrefix(call.workingDirectory.path) == true)
        #expect(call.environment["CODEX_HOME"] == nil)
        #expect(call.environment["OPENAI_API_KEY"] == nil)
        #expect(runner.sawWorkingDirectoryDuringRun)
        #expect(!FileManager.default.fileExists(atPath: call.workingDirectory.path))
    }

    @Test func codexFallsBackToTheLastAgentMessageWhenTheFileIsMissing() throws {
        let jsonLines = jsonLine(["type": "item.completed", "item": ["type": "agent_message", "text": "i'll look"]])
            + jsonLine(["type": "item.completed", "item": ["type": "command_execution", "command": "ls"]])
            + jsonLine(["type": "item.completed", "item": ["type": "agent_message", "text": " red "]])
        let output = PlanCLIProcessOutput(exitStatus: 0, standardOutput: Data(jsonLines.utf8), standardError: Data(), timedOut: false)
        #expect(try CodexAnswerProvider.answerText(outputFileContents: nil, output: output, timeoutSeconds: 120) == "red")
        #expect(throws: AnswerProviderError(source: .codexPlan, status: 0, message: "Codex finished without an answer.")) {
            _ = try CodexAnswerProvider.answerText(outputFileContents: "  ", output: PlanCLIProcessOutput(exitStatus: 0, standardOutput: Data(), standardError: Data(), timedOut: false), timeoutSeconds: 120)
        }
    }

    @Test func codexTurnFailureUsesTheAPIsInnerMessage() async {
        let apiErrorBody = "{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'x' model is not supported when using Codex with a ChatGPT account.\"}}"
        let output = jsonLine(["type": "error", "message": apiErrorBody]) + jsonLine(["type": "turn.failed", "error": ["message": apiErrorBody]])
        let runner = FakePlanCLIProcessRunner(standardOutputChunks: [output], exitStatus: 1)
        let provider = CodexAnswerProvider(executablePath: "/fake/codex", model: "x", processRunner: runner)

        await #expect(throws: AnswerProviderError(source: .codexPlan, status: 0, message: "Codex couldn't answer: The 'x' model is not supported when using Codex with a ChatGPT account.")) {
            _ = try await provider.answer(sampleRequest()) { _ in }
        }
    }

    @Test func codexSignedOutTimeoutAndSilentExitMessages() {
        let signedOut = PlanCLIProcessOutput(exitStatus: 1, standardOutput: Data(), standardError: Data("Error: Not logged in\n".utf8), timedOut: false)
        #expect(throws: AnswerProviderError(source: .codexPlan, status: 0, message: "Codex is signed out. Open Terminal, run codex login, and sign in with ChatGPT.")) {
            _ = try CodexAnswerProvider.answerText(outputFileContents: nil, output: signedOut, timeoutSeconds: 120)
        }
        let timedOut = PlanCLIProcessOutput(exitStatus: 15, standardOutput: Data(), standardError: Data(), timedOut: true)
        #expect(throws: AnswerProviderError(source: .codexPlan, status: 0, message: "Codex took longer than 120 seconds to answer.")) {
            _ = try CodexAnswerProvider.answerText(outputFileContents: "late", output: timedOut, timeoutSeconds: 120)
        }
        let silent = PlanCLIProcessOutput(exitStatus: 127, standardOutput: Data(), standardError: Data(), timedOut: false)
        #expect(throws: AnswerProviderError(source: .codexPlan, status: 0, message: "Codex stopped with exit status 127.")) {
            _ = try CodexAnswerProvider.answerText(outputFileContents: nil, output: silent, timeoutSeconds: 120)
        }
    }

    // MARK: status and locating

    @Test func claudeCodeStatusReadsAuthStatusJSON() {
        let signedIn = PlanCLIProcessOutput(exitStatus: 0, standardOutput: Data("{\"loggedIn\": true, \"authMethod\": \"claude.ai\"}".utf8), standardError: Data(), timedOut: false)
        let signedOut = PlanCLIProcessOutput(exitStatus: 1, standardOutput: Data("{\"loggedIn\": false, \"authMethod\": \"none\"}".utf8), standardError: Data(), timedOut: false)
        let garbage = PlanCLIProcessOutput(exitStatus: 0, standardOutput: Data("error: unknown command".utf8), standardError: Data(), timedOut: false)
        let hung = PlanCLIProcessOutput(exitStatus: 15, standardOutput: Data("{\"loggedIn\": true}".utf8), standardError: Data(), timedOut: true)
        #expect(PlanCLIs.claudeCodeStatus(fromAuthStatusOutput: signedIn) == .ready)
        #expect(PlanCLIs.claudeCodeStatus(fromAuthStatusOutput: signedOut) == .installedSignedOut)
        #expect(PlanCLIs.claudeCodeStatus(fromAuthStatusOutput: garbage) == .installedSignedOut)
        #expect(PlanCLIs.claudeCodeStatus(fromAuthStatusOutput: hung) == .installedSignedOut)
    }

    @Test func codexStatusReadsLoginStatus() {
        let chatGPT = PlanCLIProcessOutput(exitStatus: 0, standardOutput: Data(), standardError: Data("Logged in using ChatGPT\n".utf8), timedOut: false)
        let signedOut = PlanCLIProcessOutput(exitStatus: 1, standardOutput: Data(), standardError: Data("Not logged in\n".utf8), timedOut: false)
        let hung = PlanCLIProcessOutput(exitStatus: 0, standardOutput: Data(), standardError: Data("Logged in using ChatGPT".utf8), timedOut: true)
        #expect(PlanCLIs.codexStatus(fromLoginStatusOutput: chatGPT) == .ready)
        #expect(PlanCLIs.codexStatus(fromLoginStatusOutput: signedOut) == .installedSignedOut)
        #expect(PlanCLIs.codexStatus(fromLoginStatusOutput: hung) == .installedSignedOut)
    }

    @Test func statusChecksRunTheRightSubcommandWithATimeout() async throws {
        let claudeRunner = FakePlanCLIProcessRunner(standardOutputChunks: ["{\"loggedIn\": true}"])
        #expect(await PlanCLIs.claudeCodeStatus(executablePath: "/fake/claude", processRunner: claudeRunner) == .ready)
        let claudeCall = try #require(claudeRunner.calls.first)
        #expect(claudeCall.arguments == ["auth", "status", "--json"])
        #expect(claudeCall.timeoutSeconds == PlanCLIs.statusCheckTimeoutSeconds)

        let codexRunner = FakePlanCLIProcessRunner(standardError: "Logged in using ChatGPT", exitStatus: 0)
        #expect(await PlanCLIs.codexStatus(executablePath: "/fake/codex", processRunner: codexRunner) == .ready)
        #expect(codexRunner.calls.first?.arguments == ["login", "status"])

        #expect(await PlanCLIs.claudeCodeStatus(executablePath: nil, processRunner: claudeRunner) == .notInstalled)
        #expect(await PlanCLIs.codexStatus(executablePath: nil, processRunner: codexRunner) == .notInstalled)
    }

    @Test func locatingTriesCommonDirectoriesInOrder() {
        let installedPaths: Set<String> = ["/opt/homebrew/bin/codex", "/home/test/.bun/bin/codex", "/home/test/.claude/local/claude"]
        #expect(PlanCLIs.pathInCommonInstallDirectories(executableName: "codex", homeDirectory: "/home/test", isExecutableFile: installedPaths.contains) == "/opt/homebrew/bin/codex")
        #expect(PlanCLIs.pathInCommonInstallDirectories(executableName: "claude", homeDirectory: "/home/test", isExecutableFile: installedPaths.contains) == "/home/test/.claude/local/claude")
        #expect(PlanCLIs.pathInCommonInstallDirectories(executableName: "gemini", homeDirectory: "/home/test", isExecutableFile: installedPaths.contains) == nil)
        #expect(PlanCLIs.commonInstallDirectories(homeDirectory: "/home/test").first == "/home/test/.local/bin")
    }

    @Test func loginShellOutputKeepsOnlyTheLastExecutablePath() {
        let isExecutable: (String) -> Bool = { $0 == "/home/test/.nvm/versions/node/v22/bin/codex" }
        #expect(PlanCLIs.pathFromLoginShellOutput("Welcome back!\n/home/test/.nvm/versions/node/v22/bin/codex\n", isExecutableFile: isExecutable) == "/home/test/.nvm/versions/node/v22/bin/codex")
        #expect(PlanCLIs.pathFromLoginShellOutput("codex: aliased to npx codex\n", isExecutableFile: isExecutable) == nil)
        #expect(PlanCLIs.pathFromLoginShellOutput("/nowhere/codex", isExecutableFile: isExecutable) == nil)
    }

    @Test func processEnvironmentDropsPlanOverridesAndPutsTheExecutablesFolderFirst() {
        let baseEnvironment = [
            "PATH": "/usr/bin:/bin", "HOME": "/home/test", "USER": "test",
            "ANTHROPIC_API_KEY": "ak", "OPENAI_API_KEY": "sk", "CODEX_HOME": "/home/test/.openclicky/codex-home",
            "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "abc",
        ]
        let environment = PlanCLIs.processEnvironment(forExecutableAt: "/home/test/.nvm/bin/codex", baseEnvironment: baseEnvironment, homeDirectory: "/home/test")
        for removedName in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "CODEX_HOME", "CLAUDECODE", "CLAUDE_CODE_SESSION_ID"] {
            #expect(environment[removedName] == nil)
        }
        // USER and HOME stay: Claude Code finds its keychain sign-in through them.
        #expect(environment["USER"] == "test" && environment["HOME"] == "/home/test")
        let pathEntries = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(pathEntries.first == "/home/test/.nvm/bin")
        #expect(pathEntries.contains("/home/test/.local/bin") && pathEntries.contains("/opt/homebrew/bin"))
        #expect(pathEntries.suffix(2) == ["/usr/bin", "/bin"])
        #expect(Set(pathEntries).count == pathEntries.count)
    }
}
