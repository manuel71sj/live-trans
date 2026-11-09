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
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    /// 스크롤 추적용: 내용 높이와, 그 시점에 맨 아래를 보고 있었는지
    private struct ScrollState: Equatable {
        var contentHeight: CGFloat
        var isAtBottom: Bool
    }

    /// 원문·번역 두 열이 이 폭을 넘지 않게 해 한 줄이 너무 길어지지 않게 한다.
    private static let maxReadingWidth: CGFloat = 1080

    var body: some View {
        VStack(spacing: 0) {
            columns(
                source: Text(sourceLocale.map(name(of:)) ?? "원문"),
                target: Text(targetLanguage.map(name(of:)) ?? "번역"),
                verticalPadding: 8
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            Divider()
            if model.blocks.isEmpty && !showsLiveRow {
                emptyState
            } else {
                transcript
            }
            Divider()
            footer
        }
        .background(Palette.paper)
        .frame(minWidth: 760, minHeight: 420)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Picker("원문 언어", selection: $sourceLocale) {
                    ForEach(sourceLocales, id: \.identifier) { locale in
                        Text(name(of: locale)).tag(Optional(locale))
                    }
                }
                .help("원문 언어")
                Picker("번역 언어", selection: $targetLanguage) {
                    ForEach(targetLanguages, id: \.maximalIdentifier) { language in
                        Text(name(of: language)).tag(Optional(language))
                    }
                }
                .help("번역 언어")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(allSourceText, forType: .string)
                } label: {
                    Label("원문 복사", systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(allSourceText.isEmpty)
                Button {
                    Task {
                        if model.isRunning {
                            await model.stop()
                        } else if let sourceLocale, let targetLanguage {
                            await model.start(locale: sourceLocale, target: targetLanguage)
                        }
                    }
                } label: {
                    Label(model.isRunning ? "중지" : "시작", systemImage: model.isRunning ? "stop.fill" : "record.circle")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(model.isBusy || (!model.isRunning && pairStatus != .installed))
            }
        }
        .toolbar(removing: .title)
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

    /// 대역본처럼 원문은 왼쪽, 번역은 오른쪽 열에 같은 높이로 맞춘다. 두 열 폭은 같다.
    private func columns(source: some View, target: some View, verticalPadding: CGFloat = 14) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            source
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
            target
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
        }
        // 여백을 괘선 배경 안에 두어 문단 사이에서 괘선이 끊기지 않게 한다.
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: Self.maxReadingWidth)
        .frame(maxWidth: .infinity)
        // 가운데 세로 괘선이 원문과 번역을 나눈다.
        .background {
            Rectangle()
                .fill(Palette.rule)
                .frame(width: 1)
        }
    }

    private var transcript: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(model.blocks.indices, id: \.self) { index in
                    let block = model.blocks[index]
                    columns(
                        source: Text(block.source)
                            .font(Typography.source)
                            .lineSpacing(5),
                        target: Text(block.translation ?? "번역 중…")
                            .font(Typography.translation)
                            .lineSpacing(4)
                            .foregroundStyle(color(of: block.stage))
                            // 보정본이 오면 연필색이 잉크색으로 바뀌는 것을 보여 준다.
                            .animation(.easeOut(duration: 0.6), value: block.stage)
                    )
                }
                if showsLiveRow {
                    liveRow
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($scrollPosition)
        // 내용이 늘었을 때 직전에 맨 아래를 보고 있었으면 따라 내려가고, 위로 올려 둔 상태면 그대로 둔다.
        .onScrollGeometryChange(for: ScrollState.self) { geometry in
            ScrollState(
                contentHeight: geometry.contentSize.height,
                // 1pt는 소수점 픽셀 오차만 흡수한다. 조금이라도 위로 올리면 맨 아래가 아니다.
                isAtBottom: geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 1
            )
        } action: { old, new in
            if new.contentHeight != old.contentHeight, old.isAtBottom {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }

    private var showsLiveRow: Bool {
        model.isRunning || !model.pending.isEmpty || !model.volatile.isEmpty
    }

    /// 진행 중 문단: 확정 원문을 이어 쓰고 전사 중 텍스트를 옅게 끝에 붙인다.
    /// 가운데 괘선 위에 송출등을 켜서 지금 듣고 있는 자리임을 보여 준다.
    private var liveRow: some View {
        let confirmed = model.pending.joined(separator: " ")
        let isEmpty = confirmed.isEmpty && model.volatile.isEmpty
        return columns(
            source: Group {
                if isEmpty {
                    Text("말하면 여기에 받아 적습니다.")
                        .foregroundStyle(.tertiary)
                } else {
                    Text("\(confirmed)\(confirmed.isEmpty ? "" : " ")\(Text(model.volatile).foregroundStyle(.secondary))")
                }
            }
            .font(Typography.source)
            .lineSpacing(5),
            target: Text(model.isRunning ? "듣는 중" : "")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.onAir)
        )
        .overlay(alignment: .top) {
            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(Palette.onAir)
                .symbolEffect(.pulse, isActive: model.isRunning)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Palette.paper))
                .opacity(model.isRunning ? 1 : 0)
                .padding(.top, 15)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("시작을 누르고 말해 보세요.")
                .font(.system(size: 20, design: .serif))
            Text("말한 내용은 왼쪽에, 번역은 오른쪽에 문단마다 쌓입니다.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 왼쪽은 설치·지원·상태 안내, 오른쪽은 번역 단계 색 범례.
    private var footer: some View {
        HStack(spacing: 12) {
            if pairStatus == .supported {
                Text("번역 언어팩 설치가 필요합니다.")
                Button("설치") {
                    downloadConfiguration = .init(source: sourceLocale?.language, target: targetLanguage)
                }
                .controlSize(.small)
            } else if pairStatus == .unsupported {
                Text("지원하지 않는 언어쌍입니다.")
            }
            if !model.status.isEmpty {
                Text(model.status)
            }
            Spacer(minLength: 16)
            HStack(spacing: 14) {
                Text("번역 중").foregroundStyle(.tertiary)
                Text("1차 번역").foregroundStyle(Palette.pencil)
                Text("보정본").foregroundStyle(Palette.ink)
            }
            .fontWeight(.medium)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func finishDownload() async {
        downloadConfiguration = nil
        guard let sourceLocale, let targetLanguage else { return }
        pairStatus = await Translator.status(from: sourceLocale.language, to: targetLanguage)
    }

    /// 블록 원문과 진행 중 확정 원문을 문단마다 빈 줄로 구분한다. 확정 전(전사 중) 텍스트는 뺀다.
    private var allSourceText: String {
        var paragraphs = model.blocks.map(\.source)
        if !model.pending.isEmpty {
            paragraphs.append(model.pending.joined(separator: " "))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// 번역 중은 옅게, 1차 번역은 연필색, 보정본은 잉크색.
    private func color(of stage: SessionModel.Block.Stage) -> Color {
        switch stage {
        case .translating: Color(nsColor: .tertiaryLabelColor)
        case .draft: Palette.pencil
        case .refined: Palette.ink
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

/// 원문은 세리프, 번역은 한 단계 큰 산세리프로 두어 글꼴만으로 두 열을 구분한다.
private enum Typography {
    /// 시스템 세리프에 일본어·한국어 명조를 대체 글꼴로 지정한다.
    /// 지정하지 않으면 한자는 명조, 가나 일부는 고딕으로 섞여 나온다.
    static let source: Font = {
        let size: CGFloat = 15
        let serif = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)!
        let cascade = ["HiraMinProN-W3", "AppleMyungjo"].map { NSFontDescriptor(name: $0, size: size) }
        return Font(NSFont(descriptor: serif.addingAttributes([.cascadeList: cascade]), size: size)!)
    }()
    static let translation = Font.system(size: 17)
}

/// 연필(1차 번역)과 잉크(보정본), 송출등(듣는 중)만 직접 정하고 나머지는 시스템 색을 따른다.
private enum Palette {
    static let ink = dynamic(light: 0x17263A, dark: 0xE9EDF3)
    static let pencil = dynamic(light: 0x667285, dark: 0x8F9BAD)
    static let onAir = dynamic(light: 0xC62F28, dark: 0xFF5D52)
    static let rule = Color(nsColor: .separatorColor)
    static let paper = Color(nsColor: .textBackgroundColor)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
