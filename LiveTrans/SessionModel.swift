import AVFoundation
import Observation

@Observable
@MainActor
final class SessionModel {
    private(set) var finalized: [String] = []
    private(set) var volatile = ""
    private(set) var status = ""
    private(set) var isRunning = false
    private(set) var isBusy = false

    private let transcriber = Transcriber()
    private var resultsTask: Task<Void, Never>?

    func start(locale: Locale) async {
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
                            finalized.append(text)
                            volatile = ""
                        } else {
                            volatile = text
                        }
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
        isRunning = false
    }
}
