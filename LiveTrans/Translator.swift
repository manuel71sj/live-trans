import Foundation
import FoundationModels
import NaturalLanguage
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

    /// 보정본이 직전 묶음 번역을 다시 내놓았을 때 던진다. 호출부는 1차 번역을 유지한다.
    struct CopiedContextError: Error {}

    /// 보정본이 번역 언어가 아닌 언어(대개 원문 언어)로 나왔을 때 던진다. 호출부는 1차 번역을 유지한다.
    struct WrongLanguageError: Error {}

    /// 1차 번역을 설정된 언어 모델(온디바이스 또는 외부 모델)로 후보정한다. 직전 묶음은 맥락으로만 쓴다.
    nonisolated static func refine(
        source: String,
        draft: String,
        previous: (source: String, translation: String)?,
        target: Locale.Language,
        settings: RefineSettings
    ) async throws -> String {
        let english = Locale(identifier: "en")
        let targetName = english.localizedString(forIdentifier: target.minimalIdentifier) ?? target.minimalIdentifier
        let instructions = """
            You are a professional interpreter post-editing machine translations of live meeting speech.
            The source text comes from automatic speech recognition and may contain recognition errors.
            The prompt has a <context> section and a <current> section.
            <context> is an earlier segment that is ALREADY translated. Use it only to understand the flow. Never output its translation.
            <current> is the only segment to work on. Rewrite its draft into accurate, natural \(targetName) that faithfully conveys its source.
            Output only the corrected translation of <current>, with no tags, notes or explanations.
            """
        var prompt = ""
        if let previous {
            prompt += """
                <context>
                source: \(previous.source)
                translation: \(previous.translation)
                </context>

                """
        }
        prompt += """
            <current>
            source: \(source)
            draft: \(draft)
            </current>
            """
        let refined = try await generate(instructions: instructions, prompt: prompt, settings: settings)
        if let previous, similarity(refined, previous.translation) >= 0.6 {
            throw CopiedContextError()
        }
        // 모델이 번역하지 않고 원문을 다듬어 원문 언어로 내놓는 경우가 있다(실측).
        if let detected = NLLanguageRecognizer.dominantLanguage(for: refined),
           detected.rawValue.split(separator: "-").first.map(String.init) != target.languageCode?.identifier {
            throw WrongLanguageError()
        }
        return refined
    }

    /// 전사 원문의 음성 인식 오류를 설정된 언어 모델로 고친다. 직전 묶음의 전사는 맥락으로만 쓴다.
    /// 보정본이 원문 언어가 아니면 WrongLanguageError를 던진다. 호출부는 원문을 그대로 쓴다.
    nonisolated static func correct(
        source: String,
        previous: String?,
        language: Locale.Language,
        settings: RefineSettings
    ) async throws -> String {
        let english = Locale(identifier: "en")
        let languageName = english.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
        let instructions = """
            You correct automatic speech recognition transcripts of live meeting speech in \(languageName).
            The prompt has a <context> section and a <current> section.
            <context> is the transcript just before. Use it only to understand the topic and terminology. Never output it.
            <current> is the only text to work on. Fix words that were misrecognized, such as wrong homophones and misheard terms or names.
            Keep the language, wording and order of everything else exactly as it is. Do not translate, summarize, add or remove content.
            Output only the corrected text of <current>, with no tags, notes or explanations.
            """
        var prompt = ""
        if let previous {
            prompt += """
                <context>
                \(previous)
                </context>

                """
        }
        prompt += """
            <current>
            \(source)
            </current>
            """
        let corrected = try await generate(instructions: instructions, prompt: prompt, settings: settings)
        // 고치지 않고 번역해 내놓는 경우가 있다(온디바이스 실측).
        if let detected = NLLanguageRecognizer.dominantLanguage(for: corrected),
           detected.rawValue.split(separator: "-").first.map(String.init) != language.languageCode?.identifier {
            throw WrongLanguageError()
        }
        return corrected
    }

    /// 설정된 제공자의 언어 모델에 한 번 물어 앞뒤 공백을 뗀 답을 돌려준다.
    private nonisolated static func generate(instructions: String, prompt: String, settings: RefineSettings) async throws -> String {
        let response: String
        if settings.provider == .onDevice {
            response = try await LanguageModelSession(instructions: instructions).respond(to: prompt).content
        } else {
            response = try await RemoteRefiner.respond(instructions: instructions, prompt: prompt, settings: settings)
        }
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 글자 2-gram Dice 계수 (0~1). 두 문장이 거의 같으면 1에 가깝다.
    nonisolated static func similarity(_ a: String, _ b: String) -> Double {
        func bigrams(_ s: String) -> [String: Int] {
            let chars = Array(s.filter { !$0.isWhitespace })
            var counts: [String: Int] = [:]
            for i in chars.indices.dropLast() {
                counts[String(chars[i...i + 1]), default: 0] += 1
            }
            return counts
        }
        let x = bigrams(a), y = bigrams(b)
        let total = x.values.reduce(0, +) + y.values.reduce(0, +)
        guard total > 0 else { return 0 }
        let common = x.reduce(0) { $0 + min($1.value, y[$1.key] ?? 0) }
        return 2 * Double(common) / Double(total)
    }
}
