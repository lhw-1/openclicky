//
//  KokoroHelper.swift
//  OpenClicky
//
//  Kokoro's helper process (SherpaHelperProcess.swift): each request is a `KokoroEngine.Request`,
//  each reply the spoken WAV, base64.
//

import Foundation

nonisolated enum KokoroHelper {
    static let flag = "--openclicky-kokoro-helper"

    struct Reply: Codable, Sendable {
        var wav: String
    }

    static func run() -> Never {
        let engine = KokoroEngine()
        SherpaHelperProcess.run { (request: KokoroEngine.Request) in
            Reply(wav: try engine.generate(request).base64EncodedString())
        }
    }
}
