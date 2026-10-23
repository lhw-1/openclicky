//
//  TeacherListening.swift
//  OpenClicky
//
//  Whether the person can hear Clicky right now. In a loud room with the volume at 31 %, a
//  student typed "please solve this equation on the screen" and the whole answer went to a voice
//  nobody heard. A typed question, muted sound or a low volume means the answer is written on the
//  screen as well: a lesson when it is one, otherwise the reply as a handwritten note
//  (`TeacherNote`). The decision is pure and unit-tested; reading the volume is CoreAudio.
//

import AudioToolbox
import CoreAudio
import CoreGraphics
import Foundation

enum TeacherListening {
    struct Output: Equatable {
        /// 0…1, nil when the device has no main volume control (some USB and HDMI outputs).
        let volume: Float?
        let isMuted: Bool
    }

    /// Below this, built-in speakers are lost in any noise.
    static let quietVolume: Float = 0.4

    static func answersShouldBeWritten(questionWasTyped: Bool, output: Output) -> Bool {
        // Typing instead of speaking is the clearest sign they cannot talk, or listen, right now.
        if questionWasTyped || output.isMuted { return true }
        guard let volume = output.volume else { return false }
        return volume < quietVolume
    }

    /// The default output device's main volume and mute.
    static func currentOutput() -> Output {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            return Output(volume: nil, isMuted: false)
        }
        var volume = Float32(0)
        size = UInt32(MemoryLayout<Float32>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        let hasVolume = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr
        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        let hasMute = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr
        return Output(volume: hasVolume ? volume : nil, isMuted: hasMute && muted != 0)
    }
}

/// A reply written out as a handwritten note: wrapped lines, left-aligned, on paper.
enum TeacherNote {
    static let charactersPerLine = 34
    static let maximumLines = 14
    static let lineSpacing: CGFloat = 28

    static func sketch(for answer: String) -> TeacherSketch? {
        let lines = wrappedLines(answer)
        guard !lines.isEmpty else { return nil }
        let strokes = lines.enumerated().map { index, line in
            TeacherStroke(kind: .text(line), points: [CGPoint(x: 12, y: 22 + CGFloat(index) * lineSpacing)], isLeftAligned: true)
        }
        return TeacherSketch(boardWidth: 400, boardHeight: 22 + CGFloat(lines.count) * lineSpacing, strokes: strokes)
    }

    /// Words wrapped at `charactersPerLine`, one line per sentence break the reply already has;
    /// past `maximumLines` the last line ends in "…".
    static func wrappedLines(_ answer: String) -> [String] {
        var lines: [String] = []
        for paragraph in answer.components(separatedBy: .newlines) {
            var current = ""
            for word in paragraph.split(separator: " ") {
                let candidate = current.isEmpty ? String(word) : current + " " + word
                if candidate.count > charactersPerLine, !current.isEmpty {
                    lines.append(current)
                    current = String(word)
                } else {
                    current = candidate
                }
            }
            if !current.isEmpty { lines.append(current) }
        }
        if lines.count > maximumLines {
            lines = Array(lines.prefix(maximumLines))
            lines[maximumLines - 1] += " …"
        }
        return lines
    }
}
