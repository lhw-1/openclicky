//
//  Farewell.swift
//  OpenClicky
//
//  What OpenClicky shows on its way out, typed into the island under a short chime (no voice).
//  Every line says how to bring it back, because a menu bar app with no Dock icon is easy to lose:
//  ⌘ space, type openclicky.
//

import Foundation

struct Farewell: Equatable {
    let text: String

    static let all: [Farewell] = [
        Farewell(text: "bye for now. ⌘ space, type openclicky, and i'm back."),
        Farewell(text: "off to nap in your applications folder. ⌘ space → openclicky wakes me."),
        Farewell(text: "fine, i'll go. you'll miss me by lunch. ⌘ space → openclicky"),
        Farewell(text: "exit, pursued by a bear. ⌘ space brings me back."),
        Farewell(text: "it was a pleasure hovering with you. spotlight “openclicky” to call me back."),
        Farewell(text: "clocking out. your pointer is all yours. ⌘ space → openclicky when you need a hand."),
    ]

    static func random() -> Farewell {
        all.randomElement() ?? all[0]
    }
}
