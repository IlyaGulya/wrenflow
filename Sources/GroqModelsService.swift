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
        #if canImport(wrenflow_ffiFFI)
        return await fetchModelsViaFFI(apiKey: apiKey, baseURL: baseURL)
        #else
        return await fetchModelsViaURLSession(apiKey: apiKey, baseURL: baseURL)
        #endif
    }

    #if canImport(wrenflow_ffiFFI)
    /// Fetch models using the Rust FFI implementation.
    /// The FFI call is blocking, so we dispatch it off the main thread.
    private static func fetchModelsViaFFI(apiKey: String, baseURL: String) async -> [GroqModel] {
        do {
            let ffiModels: [FfiGroqModel] = try await Task.detached {
                try ffiFetchGroqModels(apiKey: apiKey, baseUrl: baseURL)
            }.value

            return ffiModels.map { GroqModel(id: $0.id, ownedBy: $0.ownedBy) }
        } catch {
            return []
        }
    }
    #endif

    /// Fallback: fetch models directly via URLSession (used when FFI is not available).
    private static func fetchModelsViaURLSession(apiKey: String, baseURL: String) async -> [GroqModel] {
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
