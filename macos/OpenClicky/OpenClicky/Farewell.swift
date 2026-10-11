//
//  Farewell.swift
//  OpenClicky
//
//  What OpenClicky says on its way out. Every line says how to bring it back, because a menu bar
//  app with no Dock icon is easy to lose: ⌘ space, type openclicky. `text` is typed into the
//  island; `spoken` is what the system voice reads (no symbols, so it does not say "arrow").
//

import Foundation

struct Farewell: Equatable {
    let text: String
    let spoken: String

    static let all: [Farewell] = [
        Farewell(text: "bye for now. ⌘ space, type openclicky, and i'm back.",
                 spoken: "Bye for now. Command space, type open clicky, and I'm back."),
        Farewell(text: "off to nap in your applications folder. ⌘ space → openclicky wakes me.",
                 spoken: "Off to nap in your applications folder. Spotlight open clicky to wake me."),
        Farewell(text: "fine, i'll go. you'll miss me by lunch. ⌘ space → openclicky",
                 spoken: "Fine, I'll go. You'll miss me by lunch."),
        Farewell(text: "exit, pursued by a bear. ⌘ space brings me back.",
                 spoken: "Exit, pursued by a bear. Command space brings me back."),
        Farewell(text: "it was a pleasure hovering with you. spotlight “openclicky” to call me back.",
                 spoken: "It was a pleasure hovering with you. Spotlight open clicky to call me back."),
        Farewell(text: "clocking out. your pointer is all yours. ⌘ space → openclicky when you need a hand.",
                 spoken: "Clocking out. Your pointer is all yours."),
    ]

    static func random() -> Farewell {
        all.randomElement() ?? all[0]
    }
}
