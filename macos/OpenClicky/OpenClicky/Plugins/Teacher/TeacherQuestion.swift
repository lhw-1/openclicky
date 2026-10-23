//
//  TeacherQuestion.swift
//  OpenClicky
//
//  Whether a question asks to be taught an idea, so the Teacher can start drawing without waiting
//  for the voice model to decide to. Asked by text "how does a rotary engine work compared to a
//  normal engine", the Realtime model said "let's draw it: 1. the normal engine: a cylinder…" and
//  never called the tool. A question about the screen ("how does this work"), or how to do
//  something ("how do I export"), is not a lesson: pointing answers those. Pure: unit-tested.
//

import Foundation

enum TeacherQuestion {
    static func isTeachingQuestion(_ question: String) -> Bool {
        let text = " " + question.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "' ")).inverted)
            .joined(separator: " ") + " "
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 3 else { return false }

        // About what is on the screen, or about doing something: not a lesson.
        let pointsAtTheScreen = [" this ", " that ", " these ", " those ", " here ", " button", " screen", " menu", " click", " app "]
            .contains { text.contains($0) }
        // "solve this", "work out the equation on my screen": a worked solution on the board, read
        // off the screenshot. Checked before the screen and how-to rules, which "this" and "help me" trip.
        if isProblemToSolve(text) { return true }
        let asksHowToDoSomething = [" how do i ", " how can i ", " how should i ", " how to ", " where is ", " where do i ", " can you open ", " help me "]
            .contains { text.contains($0) }
        if asksHowToDoSomething { return false }

        if [" teach me ", " teach us ", " explain to me how ", " explain how ", " explain why ", " explain what "].contains(where: { text.contains($0) }) {
            return true
        }
        if pointsAtTheScreen { return false }
        // "how does a rotary engine work", "how do vaccines work", "how is rain formed"
        if (text.contains(" how does ") || text.contains(" how do ") || text.contains(" how is ") || text.contains(" how are "))
            && [" work ", " works ", " formed ", " made ", " happen ", " happens "].contains(where: { text.contains($0) }) {
            return true
        }
        if [" vs ", " versus ", " compared to ", " compared with ", " difference between ", " differ from "].contains(where: { text.contains($0) }) {
            return true
        }
        if text.contains(" explain ") || text.hasPrefix(" what is the ") && text.contains(" theorem ") {
            return true
        }
        return false
    }

    /// Asks for a worked solution: "solve", "work out", "show me the steps", "step by step".
    static func isProblemToSolve(_ question: String) -> Bool {
        let text = " " + question.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "' ")).inverted).joined(separator: " ") + " "
        return [" solve ", " solving ", " work out ", " work this out ", " show me the steps ", " step by step ", " show the working ", " show your working "]
            .contains { text.contains($0) }
    }

    /// The question is about something on the screen, so the writer needs the screenshot.
    static func needsTheScreen(_ question: String) -> Bool {
        let text = " " + question.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "' ")).inverted).joined(separator: " ") + " "
        return isProblemToSolve(question)
            || [" this ", " that ", " these ", " those ", " here ", " screen ", " on my screen ", " above ", " below "].contains { text.contains($0) }
    }
}
