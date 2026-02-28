import Foundation
import os.log

private let ppLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "PostProcessing")

enum PostProcessingError: LocalizedError {
    case requestFailed(Int, String)
    case invalidResponse(String)
    case requestTimedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode, let details):
            "Post-processing failed with status \(statusCode): \(details)"
        case .invalidResponse(let details):
            "Invalid post-processing response: \(details)"
        case .requestTimedOut(let seconds):
            "Post-processing timed out after \(Int(seconds))s"
        }
    }
}

struct PostProcessingResult {
    let transcript: String
    let prompt: String
    let reasoning: String
}

final class PostProcessingService {
    static let defaultSystemPrompt = """
You are a dictation post-processor. You clean up raw speech-to-text output for typing.

Rules:
- Add punctuation, capitalization, and formatting.
- Remove filler words (um, uh, like, you know) unless they carry meaning.
- Fix misspellings using context and custom vocabulary — only correct words already spoken, never insert new ones.
- Preserve tone, intent, and word choice exactly. Never censor, rephrase, or omit anything including profanity and slang.

Respond with JSON: {"text": "cleaned text", "reasoning": "brief explanation of changes made"}
If the input is empty or only noise, respond: {"text": "", "reasoning": "explanation"}
"""
    static let defaultSystemPromptDate = "2026-02-24"

    private let apiKey: String
    private let baseURL: String
    private let defaultModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    private let postProcessingTimeoutSeconds: TimeInterval = 20

    static func validateAPIKey(_ key: String, baseURL: String = "https://api.groq.com/openai/v1") async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var request = URLRequest(url: URL(string: "\(baseURL)/models")!)
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200
        } catch {
            return false
        }
    }

    init(apiKey: String, baseURL: String = "https://api.groq.com/openai/v1") {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    func postProcess(
        transcript: String,
        context: AppContext,
        customVocabulary: String,
        customSystemPrompt: String = ""
    ) async throws -> PostProcessingResult {
        let vocabularyTerms = mergedVocabularyTerms(rawVocabulary: customVocabulary)

        let timeoutSeconds = postProcessingTimeoutSeconds
        return try await withThrowingTaskGroup(of: PostProcessingResult.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw PostProcessingError.invalidResponse("Post-processing service deallocated")
                }
                return try await self.process(
                    transcript: transcript,
                    contextSummary: context.contextSummary,
                    model: defaultModel,
                    customVocabulary: vocabularyTerms,
                    customSystemPrompt: customSystemPrompt
                )
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw PostProcessingError.requestTimedOut(timeoutSeconds)
            }

            do {
                guard let result = try await group.next() else {
                    throw PostProcessingError.invalidResponse("No post-processing result")
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func process(
        transcript: String,
        contextSummary: String,
        model: String,
        customVocabulary: [String],
        customSystemPrompt: String = ""
    ) async throws -> PostProcessingResult {
        os_log(.info, log: ppLog, "process() called — transcript: '%{public}@', context: '%{public}@'", transcript, contextSummary)
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = postProcessingTimeoutSeconds

        let normalizedVocabulary = normalizedVocabularyText(customVocabulary)
        os_log(.info, log: ppLog, "vocabulary: '%{public}@', customSystemPrompt empty: %{public}d", normalizedVocabulary, customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let vocabularyPrompt = if !normalizedVocabulary.isEmpty {
            """
The following vocabulary must be treated as high-priority terms while rewriting.
Use these spellings exactly in the output when relevant:
\(normalizedVocabulary)
"""
        } else {
            ""
        }

        var systemPrompt = customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultSystemPrompt
            : customSystemPrompt
        if !vocabularyPrompt.isEmpty {
            systemPrompt += "\n\n" + vocabularyPrompt
        }

        let userMessage = """
CONTEXT: \(contextSummary)

RAW_TRANSCRIPTION: \(transcript)
"""

        os_log(.info, log: ppLog, "sending to model: %{public}@", model)
        os_log(.info, log: ppLog, "user message: '%{public}@'", userMessage)

        let promptForDisplay = """
Model: \(model)

[System]
\(systemPrompt)

[User]
\(userMessage)
"""

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.0,
            "response_format": ["type": "json_object"],
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": userMessage
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            os_log(.error, log: ppLog, "no HTTP response")
            throw PostProcessingError.invalidResponse("No HTTP response")
        }

        os_log(.info, log: ppLog, "post-processing API response status: %d", httpResponse.statusCode)

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            os_log(.error, log: ppLog, "post-processing API error: status=%d body='%{public}@'", httpResponse.statusCode, message)
            throw PostProcessingError.requestFailed(httpResponse.statusCode, message)
        }

        let rawBody = String(data: data, encoding: .utf8) ?? "<binary>"
        os_log(.info, log: ppLog, "post-processing API raw response: '%{public}@'", rawBody)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            os_log(.error, log: ppLog, "failed to parse response JSON")
            throw PostProcessingError.invalidResponse("Missing choices[0].message.content")
        }

        os_log(.info, log: ppLog, "LLM raw content: '%{public}@'", content)
        let (cleanedText, reasoning) = parsePostProcessingResponse(content)
        os_log(.info, log: ppLog, "parsed text: '%{public}@', reasoning: '%{public}@'", cleanedText, reasoning)
        return PostProcessingResult(
            transcript: cleanedText,
            prompt: promptForDisplay,
            reasoning: reasoning
        )
    }

    /// Parse LLM response as JSON {"text": "...", "reasoning": "..."}.
    /// Falls back to treating the entire response as plain text if JSON parsing fails.
    private func parsePostProcessingResponse(_ value: String) -> (text: String, reasoning: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "Empty response from LLM") }

        // Try JSON parse first
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let reasoning = (json["reasoning"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            os_log(.info, log: ppLog, "parsed as JSON — text: '%{public}@', reasoning: '%{public}@'", text, reasoning)
            return (text, reasoning)
        }

        // Fallback: treat as plain text (LLM didn't return JSON)
        os_log(.info, log: ppLog, "LLM did not return JSON, falling back to plain text")
        var result = trimmed

        // Strip outer quotes if the LLM wrapped the response
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 1 {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if result == "EMPTY" {
            return ("", "LLM returned EMPTY sentinel")
        }

        return (result, "LLM returned plain text (no JSON)")
    }

    private func mergedVocabularyTerms(rawVocabulary: String) -> [String] {
        let terms = rawVocabulary
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }

    private func normalizedVocabularyText(_ vocabularyTerms: [String]) -> String {
        let terms = vocabularyTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return "" }
        return terms.joined(separator: ", ")
    }
}
