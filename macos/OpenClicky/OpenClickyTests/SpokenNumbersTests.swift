//
//  SpokenNumbersTests.swift
//  OpenClickyTests
//

@testable import OpenClicky
import Testing

struct SpokenNumbersTests {
    @Test func countedNumbersBecomeDigits() {
        #expect(SpokenNumbers.digitize("I have three hundred and twenty five rupees left") == "I have 325 rupees left")
        #expect(SpokenNumbers.digitize("about twenty-five people came") == "about 25 people came")
        #expect(SpokenNumbers.digitize("two thousand three hundred steps") == "2300 steps")
        #expect(SpokenNumbers.digitize("we sold fifteen") == "we sold 15")
        #expect(SpokenNumbers.digitize("one hundred days") == "100 days")
    }

    @Test func oneToNineStayWords() {
        #expect(SpokenNumbers.digitize("one of them brought two books") == "one of them brought two books")
        #expect(SpokenNumbers.digitize("no one came") == "no one came")
    }

    @Test func aLoneHundredKeepsItsWords() {
        #expect(SpokenNumbers.digitize("a hundred people") == "a hundred people")
    }

    @Test func numbersThatCantBeOneStayAsSaid() {
        #expect(SpokenNumbers.digitize("two three four") == "two three four")
        #expect(SpokenNumbers.digitize("twenty, thirty, forty") == "20, 30, 40")
    }

    @Test func punctuationAndCapitalsSurvive() {
        #expect(SpokenNumbers.digitize("Twenty people came.") == "20 people came.")
        #expect(SpokenNumbers.digitize("is it fifty?") == "is it 50?")
    }

    @Test func percentBecomesTheSign() {
        #expect(SpokenNumbers.digitize("fifty percent off") == "50% off")
    }

    @Test func andOutsideANumberIsLeftAlone() {
        #expect(SpokenNumbers.digitize("bread and twenty eggs") == "bread and 20 eggs")
        #expect(SpokenNumbers.digitize("a hundred and one things") == "a hundred and one things")
    }
}
