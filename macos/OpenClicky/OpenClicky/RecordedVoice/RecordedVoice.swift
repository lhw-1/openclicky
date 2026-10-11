//
//  RecordedVoice.swift
//  OpenClicky
//
//  The lines OpenClicky says the same way every time, recorded once in its answering voice
//  (OpenAI speech, marin) and bundled, so they sound good with no key and no network: the
//  first-run tour's narration, and the notices that used to be read by the Mac's system voice
//  ("i didn't get an answer…"). Anything not recorded here is spoken the way it was before.
//

import AVFoundation
import Foundation

@MainActor
final class RecordedVoice {
    enum Line: String {
        case tourHello = "tour-hello"
        case tourDictate = "tour-dictate"
        case tourDictateDone = "tour-dictate-done"
        case tourTalk = "tour-talk"
        case tourTalkDone = "tour-talk-done"
        case tourAct = "tour-act"
        case tourActDone = "tour-act-done"
        case tourAccount = "tour-account"
        case tourDone = "tour-done"
        case noticeEmptyAnswer = "notice-empty-answer"
        case noticeNoScreen = "notice-no-screen"
        case noticeScreenRecordingOff = "notice-screen-recording-off"
        case noticeNoInternet = "notice-no-internet"
        case noticeStoppedPartway = "notice-stopped-partway"
        case noticeWentWrong = "notice-went-wrong"
        case noticeRealtimeUnavailable = "notice-realtime-unavailable"
    }

    /// The fixed sentences the app speaks, by their exact text (any case), and their recording.
    static let notices: [String: Line] = [
        "i didn't get an answer. please ask again.": .noticeEmptyAnswer,
        "i couldn't see your screen just now. please ask again.": .noticeNoScreen,
        "screen recording is off for openclicky. turn it on in system settings, privacy and security, screen recording.": .noticeScreenRecordingOff,
        "i couldn't reach openclicky. check your internet and ask again.": .noticeNoInternet,
        "the answer stopped partway. please ask again.": .noticeStoppedPartway,
        "something went wrong getting your answer. please ask again.": .noticeWentWrong,
        "realtime voice is unavailable right now.": .noticeRealtimeUnavailable,
    ]

    static func line(forSpokenText text: String) -> Line? {
        notices[text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    private var player: AVAudioPlayer?

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Plays `line`, cutting off whatever recording was playing. False when it is not bundled.
    @discardableResult
    func play(_ line: Line) -> Bool {
        guard let url = Bundle.main.url(forResource: line.rawValue, withExtension: "mp3"),
              let newPlayer = try? AVAudioPlayer(contentsOf: url) else {
            AppLog.append("recorded voice: \(line.rawValue).mp3 is not in the bundle")
            return false
        }
        player?.stop()
        newPlayer.volume = 0.85
        player = newPlayer
        newPlayer.play()
        return true
    }

    func stop() {
        player?.stop()
    }
}
