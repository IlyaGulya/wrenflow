import Foundation

struct GroqModel: Identifiable, Codable {
    let id: String
    let ownedBy: String

    enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
    }
}

enum GroqModelsService {
    /// Fetches available chat/text models from the Groq API, excluding whisper/tts/vision-only models.
    static func fetchModels(apiKey: String, baseURL: String = "https://api.groq.com/openai/v1") async -> [GroqModel] {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let url = URL(string: "\(baseURL)/models") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }

            struct ModelsResponse: Codable {
                let data: [GroqModel]
            }

            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)

            let excludedPrefixes = ["whisper", "distil-whisper", "playai", "tts"]
            let excludedIds = Set([
                "llama-3.2-11b-vision-preview",
                "llama-3.2-90b-vision-preview",
            ])

            return decoded.data
                .filter { model in
                    let lowerId = model.id.lowercased()
                    let isExcludedPrefix = excludedPrefixes.contains { lowerId.hasPrefix($0) }
                    let isExcludedId = excludedIds.contains(model.id)
                    return !isExcludedPrefix && !isExcludedId
                }
                .sorted { $0.id < $1.id }
        } catch {
            return []
        }
    }
}
