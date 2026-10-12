//
//  SpokenStretchesTests.swift
//  OpenClickyTests
//
//  SFSpeechRecognizer starts each stretch after a pause from nothing; the take keeps them all.
//

@testable import OpenClicky
import Testing

struct SpokenStretchesTests {
    @Test func aStretchWithoutAFullStopGetsOneBeforeTheNextSentence() {
        #expect(SpokenStretches.joined("The weather is lovely today", "I am going to the market") == "The weather is lovely today. I am going to the market")
    }

    @Test func punctuationTheRecogniserWroteIsKept() {
        #expect(SpokenStretches.joined("Is it raining?", "Take an umbrella.") == "Is it raining? Take an umbrella.")
    }

    @Test func aStretchThatContinuesTheSentenceIsJoinedWithASpace() {
        #expect(SpokenStretches.joined("I went to the shop", "and bought milk") == "I went to the shop and bought milk")
    }

    @Test func emptySidesLeaveTheOther() {
        #expect(SpokenStretches.joined("", "Hello") == "Hello")
        #expect(SpokenStretches.joined("Hello. ", "  ") == "Hello.")
    }
}
