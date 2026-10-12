//
//  SherpaHelperProcess.swift
//  OpenClicky
//
//  The sherpa-onnx models (Kokoro's voice, Parakeet's hearing) run in helper processes: OpenClicky's
//  own binary started with a flag (OpenClickyMain catches it before any app UI exists). Same
//  signature as the app, so the embedded engine loads with library validation on. Ending a helper
//  is how its model leaves memory: sherpa-onnx keeps most of a model allocated after it is freed
//  in-process.
//
//  The protocol is one JSON line each way over stdin/stdout. A helper exits when its stdin closes,
//  so it never outlives the app.
//

import Foundation

nonisolated enum SherpaHelperProcess {
    /// A helper's whole life: answer each request line with `handle`'s reply until the app closes
    /// the pipe. A request that throws is answered `{"error": message}`.
    static func run<Request: Decodable, Reply: Encodable>(handle: (Request) throws -> Reply) -> Never {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        while let line = readLine(strippingNewline: true) {
            var out: Data
            do {
                let request = try decoder.decode(Request.self, from: Data(line.utf8))
                out = try encoder.encode(handle(request))
            } catch {
                out = (try? encoder.encode(["error": error.localizedDescription])) ?? Data(#"{"error":"the reply could not be encoded"}"#.utf8)
            }
            out.append(0x0A)
            FileHandle.standardOutput.write(out)
        }
        exit(0)
    }
}

nonisolated enum SherpaHelperError: Error, LocalizedError, Equatable {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(reason): return "the helper failed: \(reason)."
        }
    }
}

/// The app's side of one helper: starts it on the first request, sends requests one at a time
/// (serially: the models are CPU-bound), and ends it on `unload`.
nonisolated final class SherpaHelperClient: @unchecked Sendable {
    private let flag: String
    private let logName: String
    private let queue: DispatchQueue
    // Touched only on `queue`.
    private var process: Process?
    private var toHelper: FileHandle?
    private var fromHelper: FileHandle?
    private var pending = Data()

    init(flag: String, logName: String) {
        self.flag = flag
        self.logName = logName
        queue = DispatchQueue(label: "org.openclicky.helper.\(logName)", qos: .userInitiated)
    }

    /// One request, answered. A reply carrying `error` throws it.
    func send<Request: Encodable & Sendable, Reply: Decodable & Sendable>(_ request: Request, as replyType: Reply.Type) async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let line = try self.exchange(try JSONEncoder().encode(request))
                    if let failure = try? JSONDecoder().decode([String: String].self, from: line), let message = failure["error"] {
                        throw SherpaHelperError.failed(message)
                    }
                    continuation.resume(returning: try JSONDecoder().decode(Reply.self, from: line))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Starts the helper now if it isn't running, so the model can load before it is needed.
    func start() {
        queue.async { try? self.startIfNeeded() }
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

    private func exchange(_ requestLine: Data) throws -> Data {
        try startIfNeeded()
        guard let toHelper else { throw SherpaHelperError.failed("it isn't running") }
        var line = requestLine
        line.append(0x0A)
        do {
            try toHelper.write(contentsOf: line)
        } catch {
            stop()
            throw SherpaHelperError.failed("it stopped listening")
        }
        guard let replyLine = readReplyLine() else {
            stop()
            throw SherpaHelperError.failed("it stopped")
        }
        return replyLine
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        stop()
        guard let executable = Bundle.main.executableURL else { throw SherpaHelperError.failed("the app has no executable") }
        // Writing to a helper that just died must be an error, not a SIGPIPE that ends the app.
        signal(SIGPIPE, SIG_IGN)
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = [flag]
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
        AppLog.append("\(logName): helper started (pid \(helper.processIdentifier))")
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
