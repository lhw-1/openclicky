//
//  TeacherSketchWriter.swift
//  OpenClicky
//
//  The Realtime voice model talks well and draws badly: asked for refraction it ran the incoming
//  ray straight down the normal. So on that lane it only says what to draw, and a text model
//  writes the drawing while the voice is already explaining. On an own OpenAI key that is gpt-5.5
//  with reasoning off (refraction correct in ~3.5 s, where gpt-4.1 at 2 s piled labels on each
//  other and gpt-5.4-mini barely bent the ray; measured 2026-10-23); otherwise the ask lane's
//  answer source writes it.
//

import Foundation

enum TeacherSketchWriter {
    static let openAIModel = "gpt-5.5"
    static let timeoutSeconds: TimeInterval = 20

    static var systemPrompt: String {
        "You draw teaching diagrams on a whiteboard for a school student. Reply with only the drawing commands, nothing else: no code fences, no explanation.\n" + TeacherPlugin.sketchGrammar
    }

    static func userPrompt(title: String, whatToDraw: String) -> String {
        "Draw: \(whatToDraw)\nTitle: \(title)"
    }

    /// The drawing commands, or nil when no model could write them.
    @MainActor static func write(title: String, whatToDraw: String) async -> String? {
        let startedAt = Date()
        let sketch: String?
        if let openAIKey = ProviderRouter.currentCredentials().openAIKey {
            sketch = await writeWithOpenAI(key: openAIKey, title: title, whatToDraw: whatToDraw)
        } else {
            let answers = ClaudeAPI(currentProxyURL: { "\(OpenClickyConfiguration.backendBaseURL)/chat" })
            sketch = try? await answers.analyzeImage(images: [], systemPrompt: systemPrompt,
                                                     userPrompt: userPrompt(title: title, whatToDraw: whatToDraw)).text
        }
        AppLog.append("teacher: sketch \(sketch == nil ? "not written" : "written") in \(String(format: "%.1f", Date().timeIntervalSince(startedAt))) s")
        return sketch.map(withoutCodeFences)
    }

    private static func writeWithOpenAI(key: String, title: String, whatToDraw: String) async -> String? {
        var request = DirectProviderRequests.openAIChatCompletions(key: key)
        request.timeoutInterval = timeoutSeconds
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": openAIModel,
            "reasoning_effort": "none",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt(title: title, whatToDraw: whatToDraw)],
            ],
        ] as [String: Any])
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            AppLog.append("teacher: sketch writer refused (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
            return nil
        }
        return chatCompletionText(from: data)
    }

    static func chatCompletionText(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = ((root["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return content
    }

    /// Models sometimes wrap the commands in ``` fences anyway.
    static func withoutCodeFences(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.joined(separator: "\n")
    }
}
