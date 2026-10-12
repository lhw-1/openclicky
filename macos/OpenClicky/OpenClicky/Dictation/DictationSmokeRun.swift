//
//  DictationSmokeRun.swift
//  OpenClicky
//
//  `--openclicky-smoke-transcribe <wav> [engine]`: a recording is fed to an engine as if it were
//  the microphone, then formatted the way a take is. The real-provider check for Sarvam (a key is
//  needed) and the offline engine (speech recognition permission is needed), run by hand.
//

import AVFoundation
import Foundation

@MainActor
enum DictationSmokeRun {
    static func transcribe(filePath: String, engineName: String) async -> Int32 {
        guard let engine = DictationEngineChoice(rawValue: engineName) else {
            print("smoke: unknown engine \(engineName); one of \(DictationEngineChoice.allCases.map(\.rawValue).joined(separator: ", "))")
            return 2
        }
        let settings = DictationSettings.shared
        let provider: any BuddyTranscriptionProvider
        if engine == .sarvam, let key = ProcessInfo.processInfo.environment["OPENCLICKY_SARVAM_KEY"], !key.isEmpty {
            // The environment's key is for this run only; nothing is written to shell.json.
            provider = SarvamTranscriptionProvider(key: { key }, language: { settings.language })
        } else {
            if engine == .parakeet, !ParakeetDictation.isInstalled {
                // The smoke downloads the model first, as choosing it in Settings does.
                let parakeet = ParakeetDictation.shared
                parakeet.download()
                var lastTenth = -1
                while parakeet.state != .installed {
                    if case .failed(let message) = parakeet.state { print("smoke: parakeet download failed: \(message)"); return 1 }
                    if case .downloading(let fraction) = parakeet.state, Int(fraction * 10) != lastTenth {
                        lastTenth = Int(fraction * 10)
                        print("smoke: parakeet downloading \(lastTenth * 10)%")
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            if let reason = DictationEngineResolver.unavailableReason(for: engine) {
                print("smoke: \(engine.rawValue) unavailable: \(reason)")
                return 2
            }
            provider = DictationEngineResolver.makeProvider(for: engine, settings: settings)
        }
        print("smoke: engine \(provider.displayName), language \(settings.language.code), file \(filePath)")

        // The same feeding a retry uses (`TakeAudioStore.transcribe`), in 100 ms slices paced at
        // real time so the streaming engines behave as they do with a microphone.
        let started = Date()
        let raw: String
        do {
            raw = try await TakeAudioStore.transcribe(
                fileURL: URL(fileURLWithPath: filePath), provider: provider, keyterms: [],
                sliceSeconds: 0.1, pauseBetweenSlicesNanoseconds: 100_000_000,
                onTranscriptUpdate: { partial in print("smoke: … \(partial)") })
        } catch TakeAudioStore.RecordedAudioTranscriptionError.unreadableRecording(let reason) {
            print("smoke: cannot read \(filePath): \(reason)")
            return 2
        } catch TakeAudioStore.RecordedAudioTranscriptionError.engineDidNotOpen(let reason) {
            print("smoke: could not open the engine: \(reason)")
            return 1
        } catch TakeAudioStore.RecordedAudioTranscriptionError.engineDidNotAnswer {
            print("smoke: no final transcript after \(Int(Date().timeIntervalSince(started))) s")
            return 1
        } catch {
            print("smoke: engine failed: \(error.localizedDescription)")
            return 1
        }
        print("smoke: heard in \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(raw)")
        let space = DictationSpaceStore().space
        var style = space.style(forAppBundleID: nil)
        // OPENCLICKY_SMOKE_POLISH=1: the clean-up runs whatever the switch and the style say.
        if ProcessInfo.processInfo.environment["OPENCLICKY_SMOKE_POLISH"] == "1" { style.polishWithModel = true }
        let context = TakeFormattingContext(style: style, dictionary: space.dictionary, shortcuts: space.shortcuts, appName: "smoke", language: settings.language, script: settings.script)
        let polisher: (any TakePolisher)? = {
            if let key = ProcessInfo.processInfo.environment["OPENCLICKY_SARVAM_KEY"], !key.isEmpty { return SarvamTakePolisher(client: SarvamSpeechClient(key: key)) }
            return DictationEngineResolver.makePolisher()
        }()
        let forcesPolish = ProcessInfo.processInfo.environment["OPENCLICKY_SMOKE_POLISH"] == "1"
        let wantsModel = forcesPolish || DictationEngineResolver.wantsModelPolish(settings: settings, engine: engine)
        print("smoke: clean-up \(TakeFormatter.modelPassWanted(context: context, wantsModel: wantsModel) ? "on" : "off"), polisher \(polisher?.displayName ?? "none")")
        let formatted = await TakeFormatter.format(raw, context: context, polisher: polisher, wantsModel: wantsModel)
        print("smoke: formatted (\(formatted.formattingDegraded ? "local rules" : "model")): \(formatted.text)")
        return raw.isEmpty ? 1 : 0
    }
}
