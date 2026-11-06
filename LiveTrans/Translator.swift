import Foundation
import FoundationModels
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

    /// 1차 번역을 온디바이스 언어 모델로 후보정한다. 직전 묶음은 맥락으로만 쓴다.
    nonisolated static func refine(
        source: String,
        draft: String,
        previous: (source: String, translation: String)?,
        target: Locale.Language
    ) async throws -> String {
        let english = Locale(identifier: "en")
        let targetName = english.localizedString(forIdentifier: target.minimalIdentifier) ?? target.minimalIdentifier
        let session = LanguageModelSession(instructions: """
            You are a professional interpreter post-editing machine translations of live meeting speech.
            The source text comes from automatic speech recognition and may contain recognition errors.
            Rewrite the draft translation into accurate, natural \(targetName) that faithfully conveys the source.
            The previous segment is context only; do not translate it again.
            Output only the corrected translation of the current segment, with no notes or explanations.
            """)
        var prompt = ""
        if let previous {
            prompt += "Previous source: \(previous.source)\nPrevious translation: \(previous.translation)\n\n"
        }
        prompt += "Current source: \(source)\nDraft translation: \(draft)\n\nCorrected translation:"
        return try await session.respond(to: prompt).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
