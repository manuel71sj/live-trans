import AnyLanguageModel
import Foundation

/// 후보정을 외부 모델(OpenAI·Claude·로컬 OpenAI 호환 서버)에 맡긴다.
/// AnyLanguageModel은 FoundationModels와 타입 이름이 같아 이 파일에서만 import한다.
enum RemoteRefiner {
    /// 패키지 기본 max_tokens는 1024이고 잘림(stop_reason)을 알리지 않는다.
    /// 잘린 응답이 정상으로 돌아와 1차 번역을 덮어쓸 수 있으므로 Claude 호출에는 넉넉히 지정한다.
    private static let claudeMaxTokens = 16000

    nonisolated static func respond(instructions: String, prompt: String, settings: RefineSettings) async throws -> String {
        let apiKey = readAPIKey(for: settings.provider)
        var options = GenerationOptions()
        let model: any LanguageModel
        switch settings.provider {
        case .onDevice:
            // 호출부가 온디바이스를 걸러 낸다.
            throw URLError(.unsupportedURL)
        case .openAI:
            model = OpenAILanguageModel(apiKey: apiKey, model: settings.model)
            options[custom: OpenAILanguageModel.self] = .init(reasoningEffort: .init(rawValue: settings.effort))
        case .local:
            guard let url = URL(string: settings.baseURL) else { throw URLError(.badURL) }
            model = OpenAILanguageModel(baseURL: url, apiKey: apiKey, model: settings.model)
            options[custom: OpenAILanguageModel.self] = .init(reasoningEffort: .init(rawValue: settings.effort))
        case .claude:
            model = AnthropicLanguageModel(apiKey: apiKey, model: settings.model)
            options = GenerationOptions(maximumResponseTokens: claudeMaxTokens)
            options[custom: AnthropicLanguageModel.self] = .init(effort: .init(rawValue: settings.effort))
        }
        let session = LanguageModelSession(model: model, instructions: instructions)
        return try await session.respond(to: prompt, options: options).content
    }
}
