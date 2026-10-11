//
//  PlanCLIs.swift
//  OpenClicky
//
//  The two command-line tools a person may already pay for through a plan rather than a key: the
//  Claude Code CLI (`claude`, a Claude plan) and Codex (`codex`, a ChatGPT plan). This file finds
//  them, says whether they are signed in, and runs them; ClaudeCodeAnswerProvider and
//  CodexAnswerProvider build the actual questions.
//
//  A GUI app launched from Finder inherits launchd's minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin),
//  so `claude` and `codex` are never found by name. They are looked up in the usual install
//  locations first, then by asking the person's login shell, which reads their own PATH setup.
//

import Foundation

/// Whether a plan CLI can answer right now.
nonisolated enum PlanCLIStatus: String, Equatable, Sendable {
    case notInstalled
    /// Installed, but `claude auth status` / `codex login status` says nobody is signed in (or the
    /// check could not tell within its timeout, which the person fixes the same way: open the CLI).
    case installedSignedOut
    case ready
}

/// What a finished CLI run left behind.
nonisolated struct PlanCLIProcessOutput: Sendable, Equatable {
    var exitStatus: Int32
    var standardOutput: Data
    var standardError: Data
    /// The run was stopped because it went past its timeout; `exitStatus` is then the signal's.
    var timedOut: Bool

    var standardOutputText: String { String(decoding: standardOutput, as: UTF8.self) }
    var standardErrorText: String { String(decoding: standardError, as: UTF8.self) }
}

/// Runs one CLI process. The answer providers and status checks take this as a parameter so the
/// tests can hand them a fake that never starts a process.
nonisolated protocol PlanCLIProcessRunning: Sendable {
    /// `onStandardOutputChunk` is called on a background thread with each piece of stdout as it
    /// arrives, in order, before the returned output (which also holds all of stdout).
    func run(
        executablePath: String,
        arguments: [String],
        standardInput: Data?,
        workingDirectory: URL,
        environment: [String: String],
        timeoutSeconds: TimeInterval,
        onStandardOutputChunk: (@Sendable (Data) -> Void)?
    ) async throws -> PlanCLIProcessOutput
}

nonisolated enum PlanCLIs {
    /// Short: these run while Settings is open or before a question, and a CLI that cannot say
    /// whether it is signed in within this long is not going to answer quickly either.
    static let statusCheckTimeoutSeconds: TimeInterval = 5
    static let loginShellLookupTimeoutSeconds: TimeInterval = 3

    // MARK: finding the executables

    /// The directories a CLI is usually installed into, in the order they are tried: the native
    /// Claude Code installer and `npm --prefix ~/.local` (~/.local/bin), Homebrew on Apple silicon
    /// and Intel, npm's suggested user prefix, Bun, and Claude Code's older local install.
    static func commonInstallDirectories(homeDirectory: String) -> [String] {
        [
            "\(homeDirectory)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDirectory)/.npm-global/bin",
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.claude/local",
        ]
    }

    /// The first executable file named `executableName` in the common install directories.
    /// The account's real home folder, where CLIs are installed, from the user database: a
    /// redirected home (CFFIXED_USER_HOME, the UI tour's demo profile) must not hide them.
    static var realHomeDirectory: String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir { return String(cString: directory) }
        return NSHomeDirectory()
    }

    static func pathInCommonInstallDirectories(
        executableName: String,
        homeDirectory: String = PlanCLIs.realHomeDirectory,
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        for directory in commonInstallDirectories(homeDirectory: homeDirectory) {
            let candidatePath = "\(directory)/\(executableName)"
            if isExecutableFile(candidatePath) { return candidatePath }
        }
        return nil
    }

    /// The path a login shell printed for `command -v <name>`. Login and rc files can print their
    /// own banners first, so only the last line that is an absolute path counts, and only if it is
    /// really an executable file (an alias or function prints its definition instead).
    static func pathFromLoginShellOutput(
        _ loginShellOutput: String,
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let absolutePathLines = loginShellOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") }
        guard let lastAbsolutePath = absolutePathLines.last, isExecutableFile(lastAbsolutePath) else { return nil }
        return lastAbsolutePath
    }

    /// Asks the person's login shell where `executableName` is, for installs outside the common
    /// directories (nvm, asdf, a custom npm prefix). zsh is the macOS default shell; `-l` makes it
    /// read .zprofile / .zshrc-driven PATH changes the way Terminal would.
    static func pathFromLoginShell(
        executableName: String,
        processRunner: PlanCLIProcessRunning = PlanCLIProcessRunner()
    ) async -> String? {
        // The name is ours ("claude" / "codex"), never user input, so it is safe inside the command.
        let output = try? await processRunner.run(
            executablePath: "/bin/zsh",
            arguments: ["-lc", "command -v \(executableName)"],
            standardInput: nil,
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment,
            timeoutSeconds: loginShellLookupTimeoutSeconds,
            onStandardOutputChunk: nil
        )
        guard let output, !output.timedOut, output.exitStatus == 0 else { return nil }
        return pathFromLoginShellOutput(output.standardOutputText)
    }

    /// Finds `executableName`: common directories first (a few file checks), then the login shell
    /// (up to `loginShellLookupTimeoutSeconds`). Runs off the main actor because the shell lookup
    /// starts a process.
    static func locateExecutable(
        named executableName: String,
        processRunner: PlanCLIProcessRunning = PlanCLIProcessRunner()
    ) async -> String? {
        if let commonPath = pathInCommonInstallDirectories(executableName: executableName) { return commonPath }
        return await pathFromLoginShell(executableName: executableName, processRunner: processRunner)
    }

    /// Claude Code, the newest copy on this Mac: an old install left in /usr/local/bin next to a
    /// current one in ~/.local/bin refused options the provider passes ("unknown option").
    static func claudeCodePath(processRunner: PlanCLIProcessRunning = PlanCLIProcessRunner()) async -> String? {
        var candidates = commonInstallDirectories(homeDirectory: realHomeDirectory)
            .map { "\($0)/claude" }
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        if let shellPath = await pathFromLoginShell(executableName: "claude", processRunner: processRunner),
           !candidates.contains(shellPath) {
            candidates.append(shellPath)
        }
        guard candidates.count > 1 else { return candidates.first }
        var versions: [(path: String, version: String)] = []
        for candidate in candidates {
            let output = try? await processRunner.run(
                executablePath: candidate, arguments: ["--version"], standardInput: nil,
                workingDirectory: FileManager.default.temporaryDirectory,
                environment: ProcessInfo.processInfo.environment,
                timeoutSeconds: statusCheckTimeoutSeconds, onStandardOutputChunk: nil)
            if let output, !output.timedOut, output.exitStatus == 0 {
                versions.append((candidate, output.standardOutputText))
            }
        }
        let newest = newestPath(from: versions) ?? candidates.first
        AppLog.append("plans: claude code at \(candidates.joined(separator: ", ")); using \(newest ?? "none")")
        return newest
    }

    /// The path whose `--version` output names the highest version ("2.1.296 (Claude Code)").
    static func newestPath(from versions: [(path: String, version: String)]) -> String? {
        func numbers(_ text: String) -> [Int] {
            let versionText = text.split(whereSeparator: { !$0.isNumber && $0 != "." }).first.map(String.init) ?? ""
            return versionText.split(separator: ".").compactMap { Int($0) }
        }
        return versions.max { first, second in
            let firstNumbers = numbers(first.version), secondNumbers = numbers(second.version)
            for index in 0..<max(firstNumbers.count, secondNumbers.count) {
                let left = index < firstNumbers.count ? firstNumbers[index] : 0
                let right = index < secondNumbers.count ? secondNumbers[index] : 0
                if left != right { return left < right }
            }
            return false
        }?.path
    }
    static func codexPath() async -> String? { await locateExecutable(named: "codex") }

    // MARK: signed in or not

    /// `claude auth status` prints JSON (`{"loggedIn": true, "authMethod": "claude.ai", ...}`) and
    /// exits 1 when signed out. It reads the local credentials only — no model call, no cost, about
    /// 0.2 s — which makes it the cheapest reliable check Claude Code offers.
    static func claudeCodeStatus(fromAuthStatusOutput output: PlanCLIProcessOutput) -> PlanCLIStatus {
        guard !output.timedOut,
              let object = try? JSONSerialization.jsonObject(with: output.standardOutput) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool else {
            return .installedSignedOut
        }
        return loggedIn ? .ready : .installedSignedOut
    }

    /// `codex login status` prints "Logged in using ChatGPT" (or "... an API key") to stderr and
    /// exits 0; signed out it prints "Not logged in" and exits 1.
    static func codexStatus(fromLoginStatusOutput output: PlanCLIProcessOutput) -> PlanCLIStatus {
        guard !output.timedOut, output.exitStatus == 0 else { return .installedSignedOut }
        let combinedText = (output.standardOutputText + "\n" + output.standardErrorText).lowercased()
        if combinedText.contains("not logged in") { return .installedSignedOut }
        return combinedText.contains("logged in") ? .ready : .installedSignedOut
    }

    static func claudeCodeStatus(
        executablePath: String?,
        processRunner: PlanCLIProcessRunning = PlanCLIProcessRunner()
    ) async -> PlanCLIStatus {
        guard let executablePath else { return .notInstalled }
        guard let output = try? await processRunner.run(
            executablePath: executablePath,
            arguments: ["auth", "status", "--json"],
            standardInput: nil,
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: processEnvironment(forExecutableAt: executablePath),
            timeoutSeconds: statusCheckTimeoutSeconds,
            onStandardOutputChunk: nil
        ) else { return .installedSignedOut }
        return claudeCodeStatus(fromAuthStatusOutput: output)
    }

    static func codexStatus(
        executablePath: String?,
        processRunner: PlanCLIProcessRunning = PlanCLIProcessRunner()
    ) async -> PlanCLIStatus {
        guard let executablePath else { return .notInstalled }
        guard let output = try? await processRunner.run(
            executablePath: executablePath,
            arguments: ["login", "status"],
            standardInput: nil,
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: processEnvironment(forExecutableAt: executablePath),
            timeoutSeconds: statusCheckTimeoutSeconds,
            onStandardOutputChunk: nil
        ) else { return .installedSignedOut }
        return codexStatus(fromLoginStatusOutput: output)
    }

    /// Locates Claude Code and checks it, off the main actor.
    static func claudeCodeStatus() async -> PlanCLIStatus {
        await claudeCodeStatus(executablePath: await claudeCodePath())
    }

    /// Locates Codex and checks it, off the main actor.
    static func codexStatus() async -> PlanCLIStatus {
        await codexStatus(executablePath: await codexPath())
    }

    // MARK: the environment a plan CLI runs in

    /// Environment variables that would make the CLI bill something other than the person's plan,
    /// or that mark a nested Claude Code session (present when OpenClicky itself was started from a
    /// terminal inside Claude Code) and would make `claude -p` talk to the outer session.
    static let environmentVariablesRemovedForPlanCLIs: [String] = [
        // An API key in the environment wins over the plan's sign-in in both CLIs.
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY",
        // Codex must use the person's own login (~/.codex), never OpenClicky's agent home.
        "CODEX_HOME",
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_EXECPATH", "CLAUDE_PID", "CLAUDE_EFFORT", "AI_AGENT",
    ]

    /// The app's environment with the plan-overriding variables removed and a PATH that can run
    /// the CLI: Codex is a Node script (`#!/usr/bin/env node`), so `node` must resolve, and an npm
    /// install keeps it next to `codex` — hence the executable's own directory first.
    static func processEnvironment(
        forExecutableAt executablePath: String,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> [String: String] {
        var environment = baseEnvironment
        for variableName in environmentVariablesRemovedForPlanCLIs {
            environment.removeValue(forKey: variableName)
        }
        let executableDirectory = (executablePath as NSString).deletingLastPathComponent
        let inheritedPath = baseEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var pathEntries: [String] = []
        for entry in [executableDirectory] + commonInstallDirectories(homeDirectory: homeDirectory) + inheritedPath.split(separator: ":").map(String.init)
        where !entry.isEmpty && !pathEntries.contains(entry) {
            pathEntries.append(entry)
        }
        environment["PATH"] = pathEntries.joined(separator: ":")
        return environment
    }

    /// A fresh empty directory for one run, under the temporary directory: the CLIs treat their
    /// working directory as a project and may read files there, so it must not be the person's
    /// home or ~/Documents. The caller removes it afterwards.
    static func makeScratchWorkingDirectory() throws -> URL {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-plan-answers", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        return scratchDirectory
    }

    /// The last non-empty line of a CLI's stderr, which is where both CLIs put a one-line reason.
    static func lastNonEmptyLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}

// MARK: - The real process runner

/// Runs the CLI with `Process`. stdout and stderr are each drained on their own thread until end of
/// file (a full pipe would otherwise stall the child), stdin is written on a third so a large
/// request (base64 screenshots) cannot block the caller, and the run is stopped at the timeout or
/// when the calling task is cancelled.
nonisolated struct PlanCLIProcessRunner: PlanCLIProcessRunning {
    func run(
        executablePath: String,
        arguments: [String],
        standardInput: Data?,
        workingDirectory: URL,
        environment: [String: String],
        timeoutSeconds: TimeInterval,
        onStandardOutputChunk: (@Sendable (Data) -> Void)?
    ) async throws -> PlanCLIProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        let standardInputPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        process.standardInput = standardInputPipe

        let runState = PlanCLIProcessRunState(process: process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PlanCLIProcessOutput, Error>) in
                // Three things must finish before the result is complete: stdout reaches end of
                // file, stderr reaches end of file, and the process exits.
                let completionGroup = DispatchGroup()
                completionGroup.enter()
                completionGroup.enter()
                completionGroup.enter()

                process.terminationHandler = { _ in completionGroup.leave() }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                Thread.detachNewThread {
                    let readHandle = standardOutputPipe.fileHandleForReading
                    while true {
                        let chunk = readHandle.availableData
                        if chunk.isEmpty { break }
                        runState.appendStandardOutput(chunk)
                        onStandardOutputChunk?(chunk)
                    }
                    completionGroup.leave()
                }
                Thread.detachNewThread {
                    let readHandle = standardErrorPipe.fileHandleForReading
                    while true {
                        let chunk = readHandle.availableData
                        if chunk.isEmpty { break }
                        runState.appendStandardError(chunk)
                    }
                    completionGroup.leave()
                }

                let writeHandle = standardInputPipe.fileHandleForWriting
                // A child that exits before reading all of stdin would otherwise deliver SIGPIPE,
                // which terminates the whole app; with this flag the write just fails.
                _ = fcntl(writeHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
                DispatchQueue.global(qos: .userInitiated).async {
                    if let standardInput, !standardInput.isEmpty {
                        try? writeHandle.write(contentsOf: standardInput)
                    }
                    try? writeHandle.close()
                }

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                    runState.stop(becauseOfTimeout: true)
                }

                completionGroup.notify(queue: .global(qos: .userInitiated)) {
                    continuation.resume(returning: runState.output(exitStatus: process.terminationStatus))
                }
            }
        } onCancel: {
            runState.stop(becauseOfTimeout: false)
        }
    }
}

/// The output collected so far and the stop switch, shared between the reader threads, the
/// timeout and the cancellation handler.
nonisolated private final class PlanCLIProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var standardOutput = Data()
    private var standardError = Data()
    private var timedOut = false

    init(process: Process) {
        self.process = process
    }

    func appendStandardOutput(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        standardOutput.append(chunk)
    }

    func appendStandardError(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        standardError.append(chunk)
    }

    /// SIGTERM first so the CLI can clean up, SIGKILL two seconds later if it is still there.
    func stop(becauseOfTimeout: Bool) {
        lock.lock()
        let processIsRunning = process.isRunning
        if processIsRunning && becauseOfTimeout { timedOut = true }
        lock.unlock()
        guard processIsRunning else { return }
        process.terminate()
        let processIdentifier = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(processIdentifier, SIGKILL) }
        }
    }

    func output(exitStatus: Int32) -> PlanCLIProcessOutput {
        lock.lock(); defer { lock.unlock() }
        return PlanCLIProcessOutput(exitStatus: exitStatus, standardOutput: standardOutput, standardError: standardError, timedOut: timedOut)
    }
}
