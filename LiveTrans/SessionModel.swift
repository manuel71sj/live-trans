import AVFoundation
import Observation

@Observable
@MainActor
final class SessionModel {
    struct Block {
        let source: String
        /// nil이면 번역 중
        var translation: String?
    }

    private static let batchSeconds = 30.0
    /// 이 시간 동안 새 전사 결과가 없으면 대화가 끊긴 것으로 보고 바로 번역한다.
    private static let silenceSeconds = 5.0

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
    private var sourceLanguage: Locale.Language?
    private var targetLanguage: Locale.Language?

    func start(locale: Locale, target: Locale.Language) async {
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
            let results = try await transcriber.start(locale: locale)
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

    /// 묶음의 첫 결과 시작부터 이번 결과 끝까지가 30초 이상이면 묶음을 번역으로 내보낸다.
    private func appendFinal(_ text: String, range: CMTimeRange) {
        pending.append(text)
        let start = pendingStart ?? range.start
        pendingStart = start
        if (range.end - start).seconds >= Self.batchSeconds {
            flushPending()
        }
    }

    /// 새 결과가 올 때마다 다시 걸어, 5초 동안 결과가 없으면 쌓인 원문을 바로 번역한다.
    private func restartSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task {
            try? await Task.sleep(for: .seconds(Self.silenceSeconds))
            guard !Task.isCancelled else { return }
            flushPending()
        }
    }

    /// 남은 확정 원문을 한 블록으로 내보내고, 앞 블록 번역이 끝난 뒤 번역한다.
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
            do {
                blocks[index].translation = try await Translator.translate(text, from: sourceLanguage, to: targetLanguage)
            } catch {
                blocks[index].translation = "번역 실패: \(error.localizedDescription)"
            }
        }
    }
}
