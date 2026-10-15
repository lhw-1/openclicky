//
//  AskPointerContextTests.swift
//  OpenClickyTests
//
//  "What is this?" with the mouse on something: where the pointer is in the screenshot the model
//  sees, the close-up around it, and the second ask of the same question in a row.
//

import AppKit
import Foundation
@testable import OpenClicky
import Testing

@MainActor
struct AskPointerContextTests {
    private func capture(label: String, frame: CGRect, scale: Int = 2, isCursorScreen: Bool = true) -> CompanionScreenCapture {
        CompanionScreenCapture(imageData: Data(), label: label, isCursorScreen: isCursorScreen,
                               displayWidthInPoints: Int(frame.width), displayHeightInPoints: Int(frame.height), displayFrame: frame,
                               screenshotWidthInPixels: Int(frame.width) * scale, screenshotHeightInPixels: Int(frame.height) * scale)
    }

    @Test func thePointerIsPlacedInTheScreenshotItIsOnFromTheTopLeft() {
        let laptop = capture(label: "screen1", frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let external = capture(label: "screen2", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), scale: 1, isCursorScreen: false)
        // 100 pt in from the left, 100 pt down from the top of the laptop screen (AppKit's y goes up).
        let onLaptop = PointerInCapture.locate(mouse: CGPoint(x: 100, y: 882), in: [laptop, external])
        #expect(onLaptop == PointerInCapture(x: 200, y: 200, screenLabel: "screen1"))
        let onExternal = PointerInCapture.locate(mouse: CGPoint(x: 1612, y: 1400), in: [laptop, external])
        #expect(onExternal == PointerInCapture(x: 100, y: 40, screenLabel: "screen2"))
        #expect(PointerInCapture.locate(mouse: CGPoint(x: -5, y: 10), in: [laptop, external]) == nil)
    }

    @Test func thePromptLineSaysWhereThePointerIsAndWhatThisMeans() {
        let line = PointerInCapture(x: 200, y: 200, screenLabel: "screen1").promptLine
        #expect(line.contains("(200, 200)"))
        #expect(line.contains("screen1"))
        #expect(line.lowercased().contains("under the pointer"))
    }

    @Test func aCloseUpIsCutAroundThePointerAndKeptInsideTheImage() throws {
        let image = try #require(Self.solidJPEG(width: 600, height: 400))
        let middle = try #require(PointerCloseUp.jpeg(from: image, around: PointerInCapture(x: 300, y: 200, screenLabel: "s"), sideInPixels: 200))
        #expect(Self.pixelSize(of: middle) == CGSize(width: 200, height: 200))
        let corner = try #require(PointerCloseUp.jpeg(from: image, around: PointerInCapture(x: 10, y: 390, screenLabel: "s"), sideInPixels: 200))
        #expect(Self.pixelSize(of: corner) == CGSize(width: 200, height: 200))
        #expect(PointerCloseUp.jpeg(from: Data(), around: PointerInCapture(x: 1, y: 1, screenLabel: "s"), sideInPixels: 200) == nil)
    }

    @Test func theSameQuestionAgainSoonAfterIsARepeat() {
        #expect(RepeatedQuestion.isRepeat("what is this?", of: "What is this", secondsSincePrevious: 20))
        #expect(RepeatedQuestion.isRepeat("what's this", of: "what is this", secondsSincePrevious: 20))
        #expect(RepeatedQuestion.isRepeat("what is that", of: "what is this", secondsSincePrevious: 20))
        #expect(!RepeatedQuestion.isRepeat("open my mail", of: "what is this", secondsSincePrevious: 20))
        #expect(!RepeatedQuestion.isRepeat("what is this", of: "what is this", secondsSincePrevious: 400))
        #expect(!RepeatedQuestion.isRepeat("what is this", of: nil, secondsSincePrevious: 5))
        #expect(!RepeatedQuestion.isRepeat("", of: "", secondsSincePrevious: 5))
    }

    @Test func theQuestionCarriesThePointerAndTheRepeatNotice() {
        let pointer = PointerInCapture(x: 40, y: 50, screenLabel: "screen1")
        let plain = CompanionManager.askUserPrompt(transcript: "what is this", writingTarget: nil, pointer: pointer, isRepeatedQuestion: false)
        #expect(plain.hasPrefix("what is this"))
        #expect(plain.contains("(40, 50)"))
        #expect(!plain.contains(RepeatedQuestion.promptLine))
        let again = CompanionManager.askUserPrompt(transcript: "what is this", writingTarget: nil, pointer: pointer, isRepeatedQuestion: true)
        #expect(again.contains(RepeatedQuestion.promptLine))
        // (The test host may have text highlighted somewhere, so only the pointer line is checked.)
        #expect(!CompanionManager.askUserPrompt(transcript: "hi", writingTarget: nil, pointer: nil, isRepeatedQuestion: false).contains("pointer"))
    }

    // MARK: helpers

    private static func solidJPEG(width: Int, height: Int) -> Data? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    private static func pixelSize(of jpeg: Data) -> CGSize? {
        guard let bitmap = NSBitmapImageRep(data: jpeg) else { return nil }
        return CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    }
}
