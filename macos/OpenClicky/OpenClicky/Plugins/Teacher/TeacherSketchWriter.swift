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

    /// For a question nobody has described a drawing for yet (`TeacherPlugin.startLesson`).
    static func userPrompt(question: String, withScreenshot: Bool = false) -> String {
        """
        The student asked: "\(question)"\(withScreenshot ? "\nThe attached screenshot is what they are looking at; \"this\" means what is on it." : "")
        Draw the one diagram a good teacher would put on the whiteboard to answer it, with a short title at the top. \
        If they ask to solve or work something out, write the worked solution instead: the problem first, then one \
        short line per step, in order, left-aligned under each other (text with the option left), the answer last in red. \
        If no simple diagram can show it well (a real animal, an organ, a place, a painting, a photo of a machine), \
        reply with exactly one line instead: PICTURE: <a short search phrase in English>
        """
    }

    /// What the writer answered: drawing commands, or a picture to search for.
    enum Reply: Equatable {
        case sketch(String)
        case picture(query: String)

        static func parse(_ text: String) -> Reply {
            let trimmed = withoutCodeFences(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.uppercased().hasPrefix("PICTURE:") {
                return .picture(query: String(trimmed.dropFirst("PICTURE:".count)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return .sketch(trimmed)
        }
    }

    /// The drawing commands, or nil when no model could write them.
    @MainActor static func write(title: String, whatToDraw: String) async -> String? {
        await complete(userPrompt: userPrompt(title: title, whatToDraw: whatToDraw), screenshotJPEG: nil).map(withoutCodeFences)
    }

    /// The lesson for a question: drawing commands or a picture search; nil when no model answered.
    /// `screenshotJPEG` goes along when the question is about the screen ("solve this").
    @MainActor static func lesson(for question: String, screenshotJPEG: Data?) async -> Reply? {
        await complete(userPrompt: userPrompt(question: question, withScreenshot: screenshotJPEG != nil), screenshotJPEG: screenshotJPEG).map(Reply.parse)
    }

    /// Only on an own OpenAI key: without it the writer is the ask lane's source, which on a plan
    /// takes 15 s or more, so a lesson started early would race the model's own drawing for nothing.
    @MainActor static var canStartLessonsEarly: Bool {
        ProviderRouter.currentCredentials().openAIKey != nil
    }

    @MainActor private static func complete(userPrompt: String, screenshotJPEG: Data?) async -> String? {
        let startedAt = Date()
        let reply: String?
        if let openAIKey = ProviderRouter.currentCredentials().openAIKey {
            reply = await writeWithOpenAI(key: openAIKey, userPrompt: userPrompt, screenshotJPEG: screenshotJPEG)
        } else {
            let answers = ClaudeAPI(currentProxyURL: { "\(OpenClickyConfiguration.backendBaseURL)/chat" })
            let images = screenshotJPEG.map { [(data: $0, label: "the student's screen")] } ?? []
            reply = try? await answers.analyzeImage(images: images, systemPrompt: systemPrompt, userPrompt: userPrompt).text
        }
        AppLog.append("teacher: sketch \(reply == nil ? "not written" : "written") in \(String(format: "%.1f", Date().timeIntervalSince(startedAt))) s")
        return reply
    }

    private static func writeWithOpenAI(key: String, userPrompt: String, screenshotJPEG: Data?) async -> String? {
        var request = DirectProviderRequests.openAIChatCompletions(key: key)
        request.timeoutInterval = timeoutSeconds
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": openAIModel,
            "reasoning_effort": "none",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent(userPrompt: userPrompt, screenshotJPEG: screenshotJPEG)],
            ],
        ] as [String: Any])
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            AppLog.append("teacher: sketch writer refused (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
            return nil
        }
        return chatCompletionText(from: data)
    }

    /// Plain text, or text plus the screenshot as a data URL (Chat Completions' image input).
    static func userContent(userPrompt: String, screenshotJPEG: Data?) -> Any {
        guard let screenshotJPEG else { return userPrompt }
        return [
            ["type": "text", "text": userPrompt],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(screenshotJPEG.base64EncodedString())"]],
        ]
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
