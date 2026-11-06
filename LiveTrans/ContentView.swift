import Speech
import SwiftUI
import Translation

struct ContentView: View {
    @State private var sourceLocales: [Locale] = []
    @State private var targetLanguages: [Locale.Language] = []
    @State private var sourceLocale: Locale?
    @State private var targetLanguage: Locale.Language?
    @State private var model = SessionModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("원문", selection: $sourceLocale) {
                    ForEach(sourceLocales, id: \.identifier) { locale in
                        Text(name(of: locale)).tag(Optional(locale))
                    }
                }
                Picker("번역", selection: $targetLanguage) {
                    ForEach(targetLanguages, id: \.maximalIdentifier) { language in
                        Text(name(of: language)).tag(Optional(language))
                    }
                }
                Button(model.isRunning ? "중지" : "시작") {
                    Task {
                        if model.isRunning {
                            await model.stop()
                        } else if let sourceLocale {
                            await model.start(locale: sourceLocale)
                        }
                    }
                }
                .disabled(model.isBusy || sourceLocale == nil)
            }
            if !model.status.isEmpty {
                Text(model.status)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.finalized.indices, id: \.self) { index in
                        Text(model.finalized[index])
                    }
                    if !model.volatile.isEmpty {
                        Text(model.volatile)
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 300)
        }
        .padding()
        .frame(minWidth: 600)
        .task {
            sourceLocales = await SpeechTranscriber.supportedLocales
                .sorted { name(of: $0) < name(of: $1) }
            targetLanguages = await Self.translationLanguages()
                .sorted { name(of: $0) < name(of: $1) }
            sourceLocale = sourceLocales.first { $0.language.languageCode == "ja" }
            targetLanguage = targetLanguages.first { $0.languageCode == "ko" }
        }
    }

    private nonisolated static func translationLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    private func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }
}
