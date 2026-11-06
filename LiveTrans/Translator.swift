import Foundation
import Translation

/// TranslationSession·LanguageAvailability는 Sendable이 아니므로 메인 액터 밖에서 만들고 쓴다.
enum Translator {
    nonisolated static func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: target)
    }

    nonisolated static func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        let session = TranslationSession(installedSource: source, target: target)
        return try await session.translate(text).targetText
    }
}
