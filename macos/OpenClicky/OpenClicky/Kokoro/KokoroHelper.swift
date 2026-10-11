//
//  KokoroHelper.swift
//  OpenClicky
//
//  Kokoro runs in a helper process: OpenClicky's own binary started with `--openclicky-kokoro-helper`
//  (OpenClickyMain catches the flag before any app UI exists). Same signature as the app, so the
//  embedded engine loads with library validation on. Ending the helper is how the model's ~400 MB
//  leaves memory: sherpa-onnx keeps most of it allocated after the model is freed in-process.
//
//  The protocol is one JSON line each way over stdin/stdout: a `KokoroEngine.Request`, then
//  {"wav": base64} or {"error": message}. The helper exits when its stdin closes, so it never
//  outlives the app.
//

import Foundation

enum KokoroHelper {
    static let flag = "--openclicky-kokoro-helper"

    struct Reply: Codable {
        var wav: String?
        var error: String?
    }

    /// The helper's whole life: answer requests until the app closes the pipe.
    static func run() -> Never {
        let engine = KokoroEngine()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        while let line = readLine(strippingNewline: true) {
            var reply = Reply()
            do {
                let request = try decoder.decode(KokoroEngine.Request.self, from: Data(line.utf8))
                reply.wav = try engine.generate(request).base64EncodedString()
            } catch {
                reply.error = error.localizedDescription
            }
            var out = (try? encoder.encode(reply)) ?? Data(#"{"error":"the reply could not be encoded"}"#.utf8)
            out.append(0x0A)
            FileHandle.standardOutput.write(out)
        }
        exit(0)
    }
}

/// The app's side: starts the helper when Kokoro is first asked for something, sends it one
/// sentence at a time (serially: generation is CPU-bound), and ends it on `unload`.
final class KokoroHelperClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.openclicky.kokoro.client", qos: .userInitiated)
    // Touched only on `queue`.
    private var process: Process?
    private var toHelper: FileHandle?
    private var fromHelper: FileHandle?
    private var pending = Data()

    func audio(for request: KokoroEngine.Request) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.send(request)) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Ends the helper; tells `completion`, on the main queue, whether one was running.
    func unload(completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        queue.async {
            let wasRunning = self.process?.isRunning == true
            self.stop()
            DispatchQueue.main.async { completion(wasRunning) }
        }
    }

    // MARK: On the queue

    private func send(_ request: KokoroEngine.Request) throws -> Data {
        try startIfNeeded()
        guard let toHelper else { throw KokoroError.helperFailed("it isn't running") }
        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        do {
            try toHelper.write(contentsOf: line)
        } catch {
            stop()
            throw KokoroError.helperFailed("it stopped listening")
        }
        guard let replyLine = readReplyLine() else {
            stop()
            throw KokoroError.helperFailed("it stopped")
        }
        let reply = try JSONDecoder().decode(KokoroHelper.Reply.self, from: replyLine)
        if let message = reply.error { throw KokoroError.helperFailed(message) }
        guard let encoded = reply.wav, let wav = Data(base64Encoded: encoded) else { throw KokoroError.nothingGenerated }
        return wav
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        stop()
        guard let executable = Bundle.main.executableURL else { throw KokoroError.helperFailed("the app has no executable") }
        // Writing to a helper that just died must be an error, not a SIGPIPE that ends the app.
        signal(SIGPIPE, SIG_IGN)
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = [KokoroHelper.flag]
        let input = Pipe()
        let output = Pipe()
        helper.standardInput = input
        helper.standardOutput = output
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        process = helper
        toHelper = input.fileHandleForWriting
        fromHelper = output.fileHandleForReading
        pending = Data()
        AppLog.append("kokoro: helper started (pid \(helper.processIdentifier))")
    }

    /// One reply line, or nil when the helper's output ended.
    private func readReplyLine() -> Data? {
        guard let fromHelper else { return nil }
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = Data(pending[pending.index(after: newline)...])
                return Data(line)
            }
            let chunk = fromHelper.availableData
            if chunk.isEmpty { return nil }
            pending.append(chunk)
        }
    }

    private func stop() {
        try? toHelper?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        toHelper = nil
        fromHelper = nil
        pending = Data()
    }
}
