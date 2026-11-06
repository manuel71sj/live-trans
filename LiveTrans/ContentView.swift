import Speech
import SwiftUI
import Translation

struct ContentView: View {
    @State private var sourceLocales: [Locale] = []
    @State private var targetLanguages: [Locale.Language] = []
    @State private var sourceLocale: Locale?
    @State private var targetLanguage: Locale.Language?
    @State private var model = SessionModel()
    @State private var pairStatus: LanguageAvailability.Status?
    @State private var downloadConfiguration: TranslationSession.Configuration?

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
                        } else if let sourceLocale, let targetLanguage {
                            await model.start(locale: sourceLocale, target: targetLanguage)
                        }
                    }
                }
                .disabled(model.isBusy || (!model.isRunning && pairStatus != .installed))
            }
            if pairStatus == .supported {
                HStack {
                    Text("번역 언어팩 설치가 필요합니다.")
                        .foregroundStyle(.secondary)
                    Button("설치") {
                        downloadConfiguration = .init(source: sourceLocale?.language, target: targetLanguage)
                    }
                }
            } else if pairStatus == .unsupported {
                Text("지원하지 않는 언어쌍입니다.")
                    .foregroundStyle(.secondary)
            }
            if !model.status.isEmpty {
                Text(model.status)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.blocks.indices, id: \.self) { index in
                        let block = model.blocks[index]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(block.source)
                            Text(block.translation ?? "번역 중…")
                                .foregroundStyle(.blue)
                        }
                        Divider()
                    }
                    ForEach(model.pending.indices, id: \.self) { index in
                        Text(model.pending[index])
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
        .task(id: [sourceLocale?.identifier, targetLanguage?.maximalIdentifier]) {
            pairStatus = nil
            guard let sourceLocale, let targetLanguage else { return }
            let status = await Translator.status(from: sourceLocale.language, to: targetLanguage)
            // 그사이 언어쌍이 바뀌어 취소됐으면 이전 쌍의 결과를 반영하지 않는다.
            guard !Task.isCancelled else { return }
            pairStatus = status
        }
        .translationTask(downloadConfiguration) { @concurrent session in
            // 시스템 다운로드 시트를 띄운다. 사용자가 취소해도 상태를 다시 확인한다.
            try? await session.prepareTranslation()
            await finishDownload()
        }
    }

    private func finishDownload() async {
        downloadConfiguration = nil
        guard let sourceLocale, let targetLanguage else { return }
        pairStatus = await Translator.status(from: sourceLocale.language, to: targetLanguage)
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
