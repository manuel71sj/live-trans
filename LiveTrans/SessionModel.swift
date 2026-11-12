import AVFoundation
import Observation
import Speech

@Observable
@MainActor
final class SessionModel {
    struct Block {
        enum Stage {
            /// original: 문단 언어가 번역 언어와 같아 번역 없이 원문을 그대로 보이는 블록
            case translating, draft, refined, original
        }

        let source: String
        /// AI가 음성 인식 오류를 고친 전사. 전사 보정이 꺼져 있거나 보정에 실패하면 nil이고, 있으면 번역은 이것을 원문으로 쓴다.
        var corrected: String?
        var translation: String?
        var stage: Stage = .translating
    }

    /// 확정된 전사 결과 하나. 두 언어의 결과를 시간·신뢰도로 견주기 위해 구간을 함께 둔다.
    private struct Segment {
        let text: String
        let range: CMTimeRange
        let confidence: Double
        /// 함께 들을 언어(보조)의 결과인지
        let isSecondary: Bool
    }

    /// 문단은 끊김에서 마치되, 끊김 없이 이 시간을 넘으면 확정 결과(문장) 끝에서 마친다.
    private static let batchSeconds = 60.0
    /// 이 시간 동안 새 전사 결과가 없으면 대화가 끊긴 것으로 보고 바로 번역한다.
    private static let silenceSeconds = 10.0
    /// 끊김 시점에 쌓인 원문의 말한 시간이 이보다 짧으면 번역하지 않고 다음 말과 합친다.
    private static let minFragmentSeconds = 5.0

    private(set) var blocks: [Block] = []
    /// 아직 묶음으로 나가지 않은 확정 원문. 한 언어의 결과만 담는다.
    var pending: [String] { segments[flushedCount...].map(\.text) }
    /// 한글이 든 보조 언어의 진행 중 텍스트가 있으면 그것을, 아니면 주 언어의 것을 보인다.
    var volatile: String { Self.containsHangul(secondaryVolatile) ? secondaryVolatile : primaryVolatile }
    private(set) var status = ""
    private(set) var isRunning = false
    private(set) var isBusy = false

    private let transcriber = Transcriber()
    /// 이번 세션에 확정된 결과 전부. 앞에서 flushedCount개는 이미 블록으로 나갔고, 늦게 온 결과와 견주는 데 쓴다.
    private var segments: [Segment] = []
    private var flushedCount = 0
    private var primaryVolatile = ""
    private var secondaryVolatile = ""
    private var resultsTasks: [Task<Void, Never>] = []
    /// 앞 문단의 1차 번역. 값은 1차 번역이고, 실패하면 nil.
    private var translationTask: Task<String?, Never>?
    private var refineTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var pendingStart: CMTime? { segments[flushedCount...].first?.range.start }
    private var pendingEnd: CMTime { segments.last?.range.end ?? .zero }
    private var sourceLanguage: Locale.Language?
    /// 장치를 바꿀 때 같은 언어로 다시 시작하기 위해 둔다.
    private var locale: Locale?
    private var secondaryLocale: Locale?
    private var targetLanguage: Locale.Language?

    /// inputDevice가 nil이면 시스템 기본 입력 장치로 듣는다.
    /// secondary가 있으면 그 언어로도 함께 받아 적는다.
    func start(locale: Locale, secondary: Locale?, target: Locale.Language, inputDevice: AudioDeviceID?) async {
        self.locale = locale
        secondaryLocale = secondary
        sourceLanguage = locale.language
        targetLanguage = target
        isBusy = true
        defer { isBusy = false }

        guard await AVAudioApplication.requestRecordPermission() else {
            status = "마이크 권한이 없습니다. 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 허용해 주세요."
            return
        }
        status = "음성 모델 준비 중…"
        do {
            let results = try await transcriber.start(locale: locale, secondary: secondary, inputDevice: inputDevice)
            status = ""
            isRunning = true
            // 새 분석기의 오디오 시각은 0부터 다시 시작하므로 이전 세션의 구간을 남기지 않는다.
            segments = []
            flushedCount = 0
            primaryVolatile = ""
            secondaryVolatile = ""
            resultsTasks = results.enumerated().map { index, sequence in
                Task {
                    do {
                        for try await result in sequence {
                            receive(result, isSecondary: index == 1)
                            restartSilenceTimer()
                        }
                    } catch {
                        status = error.localizedDescription
                    }
                }
            }
        } catch {
            status = error.localizedDescription
        }
    }

    /// 듣는 중에 입력 장치를 바꾼다. 중지한 뒤 같은 언어로 새 장치에서 다시 시작한다.
    /// 진행 중 문단은 이 시점에 마쳐 번역하고, 이미 받아 적은 내용은 그대로 둔다.
    /// 엔진만 새 장치로 바꿔 끼우면 장치 지정 뒤 비동기 구성 변경이 엔진을 멈춰 받아 적지 못했다(실측).
    func switchInput(to inputDevice: AudioDeviceID?) async {
        guard isRunning, let locale, let targetLanguage else { return }
        await stop()
        await start(locale: locale, secondary: secondaryLocale, target: targetLanguage, inputDevice: inputDevice)
    }

    func stop() async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await transcriber.stop()
        } catch {
            status = error.localizedDescription
        }
        for task in resultsTasks {
            await task.value
        }
        resultsTasks = []
        silenceTask?.cancel()
        silenceTask = nil
        flushPending()
        isRunning = false
    }

    private func receive(_ result: SpeechTranscriber.Result, isSecondary: Bool) {
        if result.isFinal {
            if isSecondary { secondaryVolatile = "" } else { primaryVolatile = "" }
            acceptFinal(result, isSecondary: isSecondary)
        } else {
            let text = String(result.text.characters)
            if isSecondary { secondaryVolatile = text } else { primaryVolatile = text }
        }
    }

    /// 확정 결과를 도착 즉시 판정한다. 함께 들을 언어가 없으면 그대로 붙인다.
    /// 한국어는 한글이 있을 때만 받고 받으면 버리지 않으며, 일본어는 시간의 절반 이상이 더 높은 신뢰도의 한국어와 겹칠 때만 지운다.
    private func acceptFinal(_ result: SpeechTranscriber.Result, isSecondary: Bool) {
        let text = String(result.text.characters)
        guard secondaryLocale != nil else {
            appendFinal(Segment(text: text, range: result.range, confidence: 0, isSecondary: false))
            return
        }
        let segment = Segment(
            text: text,
            range: result.range,
            confidence: Self.averageConfidence(of: result.text),
            isSecondary: isSecondary
        )
        if isSecondary {
            guard Self.containsHangul(text) else { return }
            // 이미 블록으로 나간 일본어는 지울 수 없으므로 아직 나가지 않은 것만 본다.
            let kept = segments[flushedCount...].filter {
                $0.isSecondary || !Self.mostlyOverlaps($0.range, segment.range) || $0.confidence >= segment.confidence
            }
            segments.replaceSubrange(flushedCount..., with: kept)
        } else if segments.contains(where: {
            $0.isSecondary && Self.mostlyOverlaps(segment.range, $0.range) && $0.confidence > segment.confidence
        }) {
            return
        }
        appendFinal(segment)
    }

    /// 묶음의 첫 결과 시작부터 이번 결과 끝까지가 60초 이상이면 묶음을 번역으로 내보낸다.
    /// 언어가 바뀌면 한 문단에 한 언어만 담기 위해 길이와 관계없이 먼저 묶음을 마친다.
    private func appendFinal(_ segment: Segment) {
        if let last = segments[flushedCount...].last, last.isSecondary != segment.isSecondary {
            flushPending()
        }
        segments.append(segment)
        if let start = pendingStart, (segment.range.end - start).seconds >= Self.batchSeconds {
            flushPending()
        }
    }

    /// 일본어 구간 japanese의 절반 이상이 korean과 겹치는지. 끝만 맞닿은 일본어 문장이 통째로 지워지지 않게 한다(실측).
    private static func mostlyOverlaps(_ japanese: CMTimeRange, _ korean: CMTimeRange) -> Bool {
        let overlap = (min(japanese.end, korean.end) - max(japanese.start, korean.start)).seconds
        return overlap > 0 && overlap >= japanese.duration.seconds / 2
    }

    /// transcriptionConfidence가 붙은 run의 단순 평균. 없으면 0.
    private static func averageConfidence(of text: AttributedString) -> Double {
        let values = text.runs[\.transcriptionConfidence].compactMap(\.0)
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// 한글 자모·호환 자모·음절 문자가 하나라도 있는지
    static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) || (0xAC00...0xD7A3).contains($0.value)
        }
    }

    /// 새 결과가 올 때마다 다시 걸어, 10초 동안 결과가 없으면 쌓인 원문을 바로 번역한다.
    /// 쌓인 원문이 5초 미만으로 짧으면 맥락이 부족하므로 남겨 두고 다음 말과 합친다.
    private func restartSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task {
            try? await Task.sleep(for: .seconds(Self.silenceSeconds))
            guard !Task.isCancelled, let pendingStart else { return }
            guard (pendingEnd - pendingStart).seconds >= Self.minFragmentSeconds else { return }
            flushPending()
        }
    }

    /// 남은 확정 원문을 한 블록으로 내보내고 (전사 보정 →) 1차 번역 → 후보정 순으로 처리한다. 후보정이 실패하면 1차 번역을 그대로 둔다.
    private func flushPending() {
        guard flushedCount < segments.count, let sourceLanguage, let targetLanguage else { return }
        guard let language = segments[flushedCount].isSecondary ? secondaryLocale?.language : sourceLanguage else { return }
        let text = pending.joined(separator: " ")
        flushedCount = segments.count
        // 문단 언어가 번역 언어와 같으면 번역하지 않고 원문을 그대로 보인다.
        if language.languageCode == targetLanguage.languageCode {
            blocks.append(Block(source: text, translation: text, stage: .original))
            return
        }
        blocks.append(Block(source: text))
        let index = blocks.count - 1

        // 1차 번역은 앞 문단의 1차 번역만 기다리고, 후보정은 앞 문단의 후보정을 기다린다.
        // 외부 모델이 느려도 다음 문단의 1차 번역이 밀리지 않는다.
        let previousTranslation = translationTask
        let translation = Task<String?, Never> {
            _ = await previousTranslation?.value
            // 전사 보정이 켜져 있으면 보정본으로 번역한다. 보정이 실패하면 원문 그대로 번역한다.
            var source = text
            if UserDefaults.standard.bool(forKey: SettingsKey.correctEnabled) {
                let context = index > 0 ? blocks[index - 1] : nil
                let corrected = try? await Translator.correct(
                    source: text,
                    previous: context.map { $0.corrected ?? $0.source },
                    language: language,
                    settings: RefineSettings.current(.correct)
                )
                if let corrected, !corrected.isEmpty {
                    blocks[index].corrected = corrected
                    source = corrected
                }
            }
            let draft: String
            do {
                draft = try await Translator.translate(source, from: language, to: targetLanguage)
            } catch {
                blocks[index].translation = "번역 실패: \(error.localizedDescription)"
                blocks[index].stage = .draft
                return nil
            }
            blocks[index].translation = draft
            blocks[index].stage = .draft
            return draft
        }
        translationTask = translation

        let previousRefine = refineTask
        refineTask = Task {
            await previousRefine?.value
            guard let draft = await translation.value else { return }
            let context = index > 0 ? blocks[index - 1] : nil
            let refined = try? await Translator.refine(
                source: blocks[index].corrected ?? text,
                draft: draft,
                previous: context.map { ($0.corrected ?? $0.source, $0.translation ?? "") },
                target: targetLanguage,
                settings: RefineSettings.current()
            )
            if let refined, !refined.isEmpty {
                blocks[index].translation = refined
                blocks[index].stage = .refined
            }
        }
    }
}
