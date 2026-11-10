import Speech
import SwiftUI
import Translation

struct ContentView: View {
    @State private var sourceLocales: [Locale] = []
    @State private var targetLanguages: [Locale.Language] = []
    @State private var sourceLocale: Locale?
    @State private var targetLanguage: Locale.Language?
    /// 원문 언어와 함께 받아 적을 언어. nil이면 원문 언어 하나만 듣는다.
    @State private var secondaryLocale: Locale?
    @State private var model = SessionModel()
    @State private var pairStatus: LanguageAvailability.Status?
    /// 설치가 필요한 언어쌍의 원문 언어
    @State private var downloadSource: Locale.Language?
    @State private var downloadConfiguration: TranslationSession.Configuration?
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @AppStorage(SettingsKey.fontFamily) private var fontFamily = ""
    @AppStorage(SettingsKey.fontSize) private var fontSize = 15.0
    @AppStorage(SettingsKey.inputDeviceUID) private var inputDeviceUID = ""
    /// 듣는 중일 때 시작하면서 실제로 연 입력 장치
    @State private var runningInput: AudioInputDevice?
    /// 멈춰 있을 때 다음 시작에 쓸 입력 장치
    @State private var nextInput: AudioInputDevice?

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
            .font(Typography.heading(size: 13))
            .foregroundStyle(Palette.mutedForeground)
            .background(Palette.background)
            Palette.rule.frame(height: 1)
            if model.blocks.isEmpty && !showsLiveRow {
                emptyState
            } else {
                transcript
            }
            Palette.rule.frame(height: 1)
            footer
        }
        .background(Palette.surface)
        .tint(Palette.primary)
        .frame(minWidth: 760, minHeight: 420)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Picker("원문 언어", selection: $sourceLocale) {
                    ForEach(sourceLocales, id: \.identifier) { locale in
                        Text(name(of: locale)).tag(Optional(locale))
                    }
                }
                .help("원문 언어")
                Picker("함께 들을 언어", selection: $secondaryLocale) {
                    Text("없음").tag(Locale?.none)
                    if let korean = sourceLocales.first(where: { $0.language.languageCode == "ko" }) {
                        Text(name(of: korean)).tag(Optional(korean))
                    }
                }
                .help("함께 들을 언어")
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
                            // 저장된 장치가 지금 연결돼 있지 않으면 시스템 기본 입력 장치로 듣는다.
                            let device = selectedInput
                            runningInput = device ?? AudioInputDevices.systemDefault()
                            await model.start(locale: sourceLocale, secondary: secondaryLocale, target: targetLanguage, inputDevice: device?.id)
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
        .task(id: [sourceLocale?.identifier, targetLanguage?.maximalIdentifier, secondaryLocale?.identifier]) {
            pairStatus = nil
            guard let required = await requiredPairStatus() else { return }
            // 그사이 언어쌍이 바뀌어 취소됐으면 이전 쌍의 결과를 반영하지 않는다.
            guard !Task.isCancelled else { return }
            pairStatus = required.status
            downloadSource = required.source
        }
        // 듣는 중에 장치를 바꾸면 바로 새 장치로 다시 시작한다.
        .onChange(of: inputDeviceUID) {
            guard model.isRunning else { return }
            let device = selectedInput
            runningInput = device ?? AudioInputDevices.systemDefault()
            Task { await model.switchInput(to: device?.id) }
        }
        // 설정을 바꾸거나 장치가 연결·분리되거나 시스템 기본 입력이 바뀌면 다시 고른다.
        .task(id: inputDeviceUID) {
            resolveNextInput()
            for await _ in AudioInputDevices.changes() {
                resolveNextInput()
            }
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
                            .font(sourceFont)
                            .foregroundStyle(Palette.foreground)
                            .lineSpacing(5),
                        target: Text(block.translation ?? "번역 중…")
                            .font(translationFont)
                            .lineSpacing(4)
                            .foregroundStyle(color(of: block.stage))
                            // 색을 못 구분해도 알 수 있게 1차 번역에만 점선 밑줄을 긋는다.
                            .underline(block.stage == .draft, pattern: .dot, color: Palette.draft)
                            // 보정본이 오면 호박색이 블루로 바뀌는 것을 보여 준다.
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

    /// 설정의 본문 글꼴·크기. 번역은 원문보다 한 단계(2pt) 크다.
    private var sourceFont: Font { Typography.body(family: fontFamily, size: fontSize) }
    private var translationFont: Font { Typography.body(family: fontFamily, size: fontSize + 2) }

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
                        .foregroundStyle(Palette.mutedForeground)
                } else {
                    Text("\(confirmed)\(confirmed.isEmpty ? "" : " ")\(Text(model.volatile).foregroundStyle(Palette.mutedForeground))")
                        .foregroundStyle(Palette.foreground)
                }
            }
            .font(sourceFont)
            .lineSpacing(5),
            target: Text(model.isRunning ? "듣는 중" : "")
                .font(Typography.label)
                .foregroundStyle(Palette.onAir)
        )
        .overlay(alignment: .top) {
            // 듣는 중이라는 건 글자가 알려 주므로 표시등은 깜빡이지 않고 켜져만 있다.
            Circle()
                .fill(Palette.onAir)
                .frame(width: 9, height: 9)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Palette.surface))
                .opacity(model.isRunning ? 1 : 0)
                .padding(.top, 15)
        }
    }

    /// 시작 전에도 실제 화면과 같은 2열 첫 줄 자리에 무엇이 쌓일지 적어 둔다.
    private var emptyState: some View {
        VStack(spacing: 0) {
            columns(
                source: Text("시작을 누르면 말한 내용이 여기에 쌓입니다.")
                    .font(sourceFont),
                target: Text("번역은 문단마다 이쪽에 붙습니다.")
                    .font(translationFont)
            )
            .foregroundStyle(Palette.mutedForeground)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Rectangle()
                .fill(Palette.rule)
                .frame(width: 1)
        }
    }

    /// 듣는 중에는 시작할 때 연 장치, 멈춰 있을 때는 다음 시작에 쓸 장치.
    private var currentInput: AudioInputDevice? {
        model.isRunning ? runningInput : nextInput
    }

    /// 고른 장치가 연결돼 있으면 그 장치, 아니면 시스템 기본 입력 장치
    private func resolveNextInput() {
        nextInput = selectedInput ?? AudioInputDevices.systemDefault()
    }

    /// 설정에서 고른 장치. 시스템 기본을 골랐거나 그 장치가 지금 연결돼 있지 않으면 nil
    private var selectedInput: AudioInputDevice? {
        AudioInputDevices.all().first { $0.uid == inputDeviceUID }
    }

    /// 왼쪽은 입력 장치와 설치·지원·상태 안내, 오른쪽은 번역 단계 색 범례.
    private var footer: some View {
        HStack(spacing: 12) {
            if let currentInput {
                Label(currentInput.name, systemImage: "mic")
                    .help("입력 장치")
            }
            if pairStatus == .supported {
                Text("번역 언어팩 설치가 필요합니다.")
                Button("설치") {
                    downloadConfiguration = .init(source: downloadSource, target: targetLanguage)
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
                Text("번역 중").foregroundStyle(Palette.translating)
                Text("1차 번역").foregroundStyle(Palette.draft)
                    .underline(pattern: .dot, color: Palette.draft)
                Text("보정본").foregroundStyle(Palette.refined)
            }
            .fontWeight(.medium)
        }
        .font(Typography.caption)
        .foregroundStyle(Palette.mutedForeground)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Palette.background)
    }

    private func finishDownload() async {
        downloadConfiguration = nil
        guard let required = await requiredPairStatus() else { return }
        pairStatus = required.status
        downloadSource = required.source
    }

    /// 번역에 필요한 언어쌍(원문 → 번역, 함께 들을 언어가 한국어면 한국어 → 번역도)을 모두 확인한다.
    /// 하나라도 지원하지 않으면 unsupported, 아니면 설치가 필요한 쌍이 있으면 supported(그 쌍의 원문 언어를 함께 돌려준다).
    private func requiredPairStatus() async -> (status: LanguageAvailability.Status, source: Locale.Language?)? {
        guard let sourceLocale, let targetLanguage else { return nil }
        var sources = [sourceLocale.language]
        if let secondaryLocale, targetLanguage.languageCode != "ko" {
            sources.append(secondaryLocale.language)
        }
        var result: (status: LanguageAvailability.Status, source: Locale.Language?) = (.installed, nil)
        for source in sources {
            switch await Translator.status(from: source, to: targetLanguage) {
            case .unsupported: return (.unsupported, nil)
            case .supported where result.status == .installed: result = (.supported, source)
            default: break
            }
        }
        return result
    }

    /// 블록 원문과 진행 중 확정 원문을 문단마다 빈 줄로 구분한다. 확정 전(전사 중) 텍스트는 뺀다.
    private var allSourceText: String {
        var paragraphs = model.blocks.map(\.source)
        if !model.pending.isEmpty {
            paragraphs.append(model.pending.joined(separator: " "))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// 번역 중은 보조 회색, 1차 번역은 호박색, 보정본은 브랜드 블루.
    private func color(of stage: SessionModel.Block.Stage) -> Color {
        switch stage {
        case .translating: Palette.translating
        case .draft: Palette.draft
        case .refined: Palette.refined
        case .original: Palette.foreground
        }
    }

    private nonisolated static func translationLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    /// 화면 문구가 한국어이므로 언어 이름도 한국어로 보인다.
    private static let displayLocale = Locale(identifier: "ko")

    private func name(of locale: Locale) -> String {
        Self.displayLocale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private func name(of language: Locale.Language) -> String {
        Self.displayLocale.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }
}

/// design-system/livetrans/MASTER.md: 제목은 세리프, 본문은 산세리프(번역이 한 단계 크다).
private enum Typography {
    /// 원문·번역 본문. 글꼴 가족이 비었거나 설치돼 있지 않으면 시스템 산세리프로 쓴다.
    @MainActor
    static func body(family: String, size: CGFloat) -> Font {
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size).map { Font($0) } ?? .system(size: size)
    }

    /// "듣는 중"처럼 본문 옆에 붙는 짧은 표시
    static let label = Font.system(size: 13, weight: .medium)
    /// 하단 상태 줄과 범례
    static let caption = Font.system(size: 12)

    /// 시스템 세리프에 일본어·한국어 명조를 대체 글꼴로 지정한다.
    /// 지정하지 않으면 한자는 명조, 가나 일부는 고딕으로 섞여 나온다.
    static func heading(size: CGFloat) -> Font {
        let serif = NSFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor.withDesign(.serif)!
        let cascade = ["HiraMinProN-W6", "AppleMyungjo"].map { NSFontDescriptor(name: $0, size: size) }
        return Font(NSFont(descriptor: serif.addingAttributes([.cascadeList: cascade]), size: size)!)
    }
}

/// design-system/livetrans/MASTER.md의 컬러 토큰. 잉크 블루(OKLCH 색상각 250°) 하나에서 밝기·채도만 바꿔 만들었다.
/// 글자색은 라이트·다크 모두 대비 5:1 이상이고, 단계 색은 블루·호박색 짝이라 적록 색각 이상에서도 구분된다.
private enum Palette {
    static let primary = dynamic(light: 0x165E98, dark: 0x6BBAF0)
    static let background = dynamic(light: 0xF2F6FB, dark: 0x0E141E)
    static let surface = dynamic(light: 0xFBFDFF, dark: 0x141C27)
    static let foreground = dynamic(light: 0x172232, dark: 0xDFE5EC)
    static let mutedForeground = dynamic(light: 0x5F6A77, dark: 0x969FAB)
    static let rule = dynamic(light: 0xDAE0E7, dark: 0x2B3340)
    static let translating = mutedForeground
    static let draft = dynamic(light: 0x97570D, dark: 0xEEB154)
    static let refined = primary
    static let onAir = dynamic(light: 0xC52C2A, dark: 0xF2716A)

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
