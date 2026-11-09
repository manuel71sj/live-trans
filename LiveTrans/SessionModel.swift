import AVFoundation
import Observation

@Observable
@MainActor
final class SessionModel {
    struct Block {
        enum Stage {
            case translating, draft, refined
        }

        let source: String
        var translation: String?
        var stage: Stage = .translating
    }

    /// 문단은 끊김에서 마치되, 끊김 없이 이 시간을 넘으면 확정 결과(문장) 끝에서 마친다.
    private static let batchSeconds = 60.0
    /// 이 시간 동안 새 전사 결과가 없으면 대화가 끊긴 것으로 보고 바로 번역한다.
    private static let silenceSeconds = 10.0
    /// 끊김 시점에 쌓인 원문의 말한 시간이 이보다 짧으면 번역하지 않고 다음 말과 합친다.
    private static let minFragmentSeconds = 5.0

    private(set) var blocks: [Block] = []
    /// 아직 묶음으로 나가지 않은 확정 원문
    private(set) var pending: [String] = []
    private(set) var volatile = ""
    private(set) var status = ""
    private(set) var isRunning = false
    private(set) var isBusy = false

    private let transcriber = Transcriber()
    private var resultsTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var pendingStart: CMTime?
    private var pendingEnd: CMTime = .zero
    private var sourceLanguage: Locale.Language?
    private var targetLanguage: Locale.Language?

    /// inputDevice가 nil이면 시스템 기본 입력 장치로 듣는다.
    func start(locale: Locale, target: Locale.Language, inputDevice: AudioDeviceID?) async {
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
            let results = try await transcriber.start(locale: locale, inputDevice: inputDevice)
            status = ""
            isRunning = true
            resultsTask = Task {
                do {
                    for try await result in results {
                        let text = String(result.text.characters)
                        if result.isFinal {
                            volatile = ""
                            appendFinal(text, range: result.range)
                        } else {
                            volatile = text
                        }
                        restartSilenceTimer()
                    }
                } catch {
                    status = error.localizedDescription
                }
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func stop() async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await transcriber.stop()
        } catch {
            status = error.localizedDescription
        }
        await resultsTask?.value
        resultsTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        flushPending()
        isRunning = false
    }

    /// 묶음의 첫 결과 시작부터 이번 결과 끝까지가 60초 이상이면 묶음을 번역으로 내보낸다.
    private func appendFinal(_ text: String, range: CMTimeRange) {
        pending.append(text)
        let start = pendingStart ?? range.start
        pendingStart = start
        pendingEnd = range.end
        if (range.end - start).seconds >= Self.batchSeconds {
            flushPending()
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

    /// 남은 확정 원문을 한 블록으로 내보내고, 앞 블록 번역이 끝난 뒤
    /// 1차 번역 → 후보정 순으로 처리한다. 후보정이 실패하면 1차 번역을 그대로 둔다.
    private func flushPending() {
        guard !pending.isEmpty, let sourceLanguage, let targetLanguage else { return }
        let text = pending.joined(separator: " ")
        pending = []
        pendingStart = nil
        blocks.append(Block(source: text))
        let index = blocks.count - 1

        let previous = translationTask
        translationTask = Task {
            await previous?.value
            let draft: String
            do {
                draft = try await Translator.translate(text, from: sourceLanguage, to: targetLanguage)
            } catch {
                blocks[index].translation = "번역 실패: \(error.localizedDescription)"
                blocks[index].stage = .draft
                return
            }
            blocks[index].translation = draft
            blocks[index].stage = .draft

            let context = index > 0 ? blocks[index - 1] : nil
            let refined = try? await Translator.refine(
                source: text,
                draft: draft,
                previous: context.map { ($0.source, $0.translation ?? "") },
                target: targetLanguage
            )
            if let refined, !refined.isEmpty {
                blocks[index].translation = refined
                blocks[index].stage = .refined
            }
        }
    }
}
