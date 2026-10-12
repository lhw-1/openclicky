//
//  ParakeetEngine.swift
//  OpenClicky
//
//  NVIDIA's Parakeet TDT 0.6B v3 (int8) through sherpa-onnx's offline recogniser. Only ever used
//  inside Parakeet's helper process (ParakeetHelper below): the loaded model takes several hundred
//  MB, which only ending the process gives back.
//

import Foundation

nonisolated final class ParakeetEngine {
    struct Request: Codable, Sendable {
        /// 16 kHz mono 16-bit little-endian PCM, base64.
        let pcm16Base64: String
        let libraryFolder: URL
        let modelFolder: URL
    }

    struct Reply: Codable, Sendable {
        let text: String
    }

    static let sampleRate: Int32 = 16_000

    private typealias CreateRecognizer = @convention(c) (UnsafePointer<SherpaOnnxOfflineRecognizerConfig>?) -> OpaquePointer?
    private typealias CreateStream = @convention(c) (OpaquePointer?) -> OpaquePointer?
    private typealias AcceptWaveform = @convention(c) (OpaquePointer?, Int32, UnsafePointer<Float>?, Int32) -> Void
    private typealias Decode = @convention(c) (OpaquePointer?, OpaquePointer?) -> Void
    private typealias GetResult = @convention(c) (OpaquePointer?) -> UnsafePointer<SherpaOnnxOfflineRecognizerResult>?
    private typealias DestroyResult = @convention(c) (UnsafePointer<SherpaOnnxOfflineRecognizerResult>?) -> Void
    private typealias DestroyStream = @convention(c) (OpaquePointer?) -> Void

    private struct Library {
        let createRecognizer: CreateRecognizer
        let createStream: CreateStream
        let acceptWaveform: AcceptWaveform
        let decode: Decode
        let getResult: GetResult
        let destroyResult: DestroyResult
        let destroyStream: DestroyStream
    }

    private var library: Library?
    private var recognizer: OpaquePointer?

    /// The words in `request`'s audio; loads the model first if it isn't. An empty request only
    /// loads it (the warm-up when the dictation key goes down).
    func transcribe(_ request: Request) throws -> Reply {
        let library = try loadLibrary(from: request.libraryFolder)
        if recognizer == nil {
            let startedAt = Date()
            recognizer = createRecognizer(library: library, modelFolder: request.modelFolder)
            guard recognizer != nil else { throw ParakeetError.modelNotLoaded }
            AppLog.append(String(format: "parakeet: model loaded in %.1f s", Date().timeIntervalSince(startedAt)))
        }
        guard let pcm16 = Data(base64Encoded: request.pcm16Base64) else { throw ParakeetError.unreadableAudio }
        let samples = Self.floatSamples(fromPCM16: pcm16)
        guard !samples.isEmpty else { return Reply(text: "") }

        guard let stream = library.createStream(recognizer) else { throw ParakeetError.modelNotLoaded }
        defer { library.destroyStream(stream) }
        samples.withUnsafeBufferPointer { buffer in
            library.acceptWaveform(stream, Self.sampleRate, buffer.baseAddress, Int32(buffer.count))
        }
        library.decode(recognizer, stream)
        guard let result = library.getResult(stream) else { return Reply(text: "") }
        defer { library.destroyResult(result) }
        let text = result.pointee.text.map { String(cString: $0) } ?? ""
        return Reply(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func floatSamples(fromPCM16 pcm16: Data) -> [Float] {
        pcm16.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
    }

    private func loadLibrary(from folder: URL) throws -> Library {
        if let library { return library }
        let sherpa = try SherpaLibrary.open(in: folder)
        let loaded = Library(
            createRecognizer: try sherpa.symbol("SherpaOnnxCreateOfflineRecognizer", as: CreateRecognizer.self),
            createStream: try sherpa.symbol("SherpaOnnxCreateOfflineStream", as: CreateStream.self),
            acceptWaveform: try sherpa.symbol("SherpaOnnxAcceptWaveformOffline", as: AcceptWaveform.self),
            decode: try sherpa.symbol("SherpaOnnxDecodeOfflineStream", as: Decode.self),
            getResult: try sherpa.symbol("SherpaOnnxGetOfflineStreamResult", as: GetResult.self),
            destroyResult: try sherpa.symbol("SherpaOnnxDestroyOfflineRecognizerResult", as: DestroyResult.self),
            destroyStream: try sherpa.symbol("SherpaOnnxDestroyOfflineStream", as: DestroyStream.self))
        library = loaded
        return loaded
    }

    private func createRecognizer(library: Library, modelFolder: URL) -> OpaquePointer? {
        // The config holds C strings: kept alive until the recogniser is created, then freed.
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        defer { cStrings.forEach { free($0) } }
        func cString(_ value: String) -> UnsafePointer<CChar> {
            let pointer = strdup(value)!
            cStrings.append(pointer)
            return UnsafePointer(pointer)
        }
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Self.sampleRate
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = cString(modelFolder.appendingPathComponent("encoder.int8.onnx").path)
        config.model_config.transducer.decoder = cString(modelFolder.appendingPathComponent("decoder.int8.onnx").path)
        config.model_config.transducer.joiner = cString(modelFolder.appendingPathComponent("joiner.int8.onnx").path)
        config.model_config.tokens = cString(modelFolder.appendingPathComponent("tokens.txt").path)
        config.model_config.model_type = cString("nemo_transducer")
        config.model_config.num_threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 1)))
        config.model_config.provider = cString("cpu")
        config.decoding_method = cString("greedy_search")
        return withUnsafePointer(to: &config) { library.createRecognizer($0) }
    }
}

/// Parakeet's helper process (SherpaHelperProcess.swift).
nonisolated enum ParakeetHelper {
    static let flag = "--openclicky-parakeet-helper"

    static func run() -> Never {
        let engine = ParakeetEngine()
        SherpaHelperProcess.run { (request: ParakeetEngine.Request) in try engine.transcribe(request) }
    }
}

nonisolated enum ParakeetError: Error, LocalizedError, Equatable {
    case notInstalled
    case modelNotLoaded
    case unreadableAudio

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "the offline speech model isn't downloaded yet."
        case .modelNotLoaded: return "the offline speech model didn't load."
        case .unreadableAudio: return "the audio couldn't be read."
        }
    }
}
