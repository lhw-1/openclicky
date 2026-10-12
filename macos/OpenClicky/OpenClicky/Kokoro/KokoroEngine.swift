//
//  KokoroEngine.swift
//  OpenClicky
//
//  Runs Kokoro through sherpa-onnx's C API (SherpaLibrary).
//  Only ever used inside the Kokoro helper process (KokoroHelper.swift): freeing the model in the
//  app gave back almost none of its memory (sherpa-onnx keeps ~300 MB allocated), while ending the
//  helper gives back all of it.
//

import Foundation

nonisolated final class KokoroEngine {
    struct Request: Codable, Sendable {
        let text: String
        let speakerID: Int
        /// sherpa-onnx's `lang` hint; English and Mandarin go by the model's lexicons instead.
        let languageHint: String
        let libraryFolder: URL
        let modelFolder: URL
    }

    private typealias CreateFunction = @convention(c) (UnsafePointer<SherpaOnnxOfflineTtsConfig>?) -> OpaquePointer?
    private typealias DestroyFunction = @convention(c) (OpaquePointer?) -> Void
    private typealias GenerateFunction = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, Float) -> UnsafePointer<SherpaOnnxGeneratedAudio>?
    private typealias DestroyAudioFunction = @convention(c) (UnsafePointer<SherpaOnnxGeneratedAudio>?) -> Void

    private struct Library {
        let create: CreateFunction
        let destroy: DestroyFunction
        let generate: GenerateFunction
        let destroyAudio: DestroyAudioFunction
    }

    private var library: Library?
    private var tts: OpaquePointer?
    private var loadedLanguageHint: String?

    /// `request.text` spoken, as WAV bytes; loads the model first if it isn't (about 0.8 s).
    func generate(_ request: Request) throws -> Data {
        let library = try loadLibrary(from: request.libraryFolder)
        if tts == nil || loadedLanguageHint != request.languageHint {
            if let tts { library.destroy(tts) }
            tts = nil
            let startedAt = Date()
            tts = createTTS(library: library, request: request)
            guard tts != nil else { throw KokoroError.modelNotLoaded }
            loadedLanguageHint = request.languageHint
            AppLog.append(String(format: "kokoro: model loaded in %.1f s", Date().timeIntervalSince(startedAt)))
        }
        guard let audio = request.text.withCString({ library.generate(tts, $0, Int32(request.speakerID), 1.0) }) else {
            throw KokoroError.nothingGenerated
        }
        defer { library.destroyAudio(audio) }
        let sampleCount = Int(audio.pointee.n)
        guard sampleCount > 0, let samples = audio.pointee.samples else { throw KokoroError.nothingGenerated }
        return Self.wav(samples: UnsafeBufferPointer(start: samples, count: sampleCount), sampleRate: Int(audio.pointee.sample_rate))
    }

    private func loadLibrary(from folder: URL) throws -> Library {
        if let library { return library }
        let sherpa = try SherpaLibrary.open(in: folder)
        let loaded = Library(
            create: try sherpa.symbol("SherpaOnnxCreateOfflineTts", as: CreateFunction.self),
            destroy: try sherpa.symbol("SherpaOnnxDestroyOfflineTts", as: DestroyFunction.self),
            generate: try sherpa.symbol("SherpaOnnxOfflineTtsGenerate", as: GenerateFunction.self),
            destroyAudio: try sherpa.symbol("SherpaOnnxDestroyOfflineTtsGeneratedAudio", as: DestroyAudioFunction.self))
        library = loaded
        return loaded
    }

    private func createTTS(library: Library, request: Request) -> OpaquePointer? {
        // The config holds C strings: kept alive until the model is created, then freed.
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        defer { cStrings.forEach { free($0) } }
        func cString(_ value: String) -> UnsafePointer<CChar> {
            let pointer = strdup(value)!
            cStrings.append(pointer)
            return UnsafePointer(pointer)
        }
        let model = request.modelFolder
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.kokoro.model = cString(model.appendingPathComponent("model.onnx").path)
        config.model.kokoro.voices = cString(model.appendingPathComponent("voices.bin").path)
        config.model.kokoro.tokens = cString(model.appendingPathComponent("tokens.txt").path)
        config.model.kokoro.data_dir = cString(model.appendingPathComponent("espeak-ng-data").path)
        config.model.kokoro.dict_dir = cString(model.appendingPathComponent("dict").path)
        config.model.kokoro.length_scale = 1.0
        if request.languageHint == "en-us" || request.languageHint == "zh" {
            let lexicons = ["lexicon-us-en.txt", "lexicon-zh.txt"].map { model.appendingPathComponent($0).path }
            config.model.kokoro.lexicon = cString(lexicons.joined(separator: ","))
        } else {
            config.model.kokoro.lang = cString(request.languageHint)
        }
        config.model.num_threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 1)))
        config.model.provider = cString("cpu")
        config.max_num_sentences = 1
        config.silence_scale = 0.2
        return withUnsafePointer(to: &config) { library.create($0) }
    }

    /// Mono float samples in [-1, 1] as a 16-bit WAV file AVAudioPlayer can play.
    static func wav(samples: UnsafeBufferPointer<Float>, sampleRate: Int) -> Data {
        var pcm16 = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm16.append(contentsOf: $0) }
        }
        return BuddyWAVFileBuilder.buildWAVData(fromPCM16MonoAudio: pcm16, sampleRate: sampleRate)
    }
}
