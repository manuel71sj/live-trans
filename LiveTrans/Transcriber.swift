import AVFoundation
import Speech

/// 마이크 입력을 SpeechAnalyzer로 전사한다.
@MainActor
final class Transcriber {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    /// 음성 모델을 준비하고 전사를 시작한다. 반환된 시퀀스는 중지 후 확정 결과까지 내보내고 끝난다.
    func start(locale: Locale) async throws -> some AsyncSequence<SpeechTranscriber.Result, any Error> {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputSequence: stream)

        Self.installTap(on: engine.inputNode, converter: converter, continuation: continuation)
        engine.prepare()
        try engine.start()

        self.analyzer = analyzer
        self.continuation = continuation
        return transcriber.results
    }

    func stop() async throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
    }

    /// 탭 콜백은 오디오 스레드에서 불리므로 메인 액터 밖에서 만든다.
    private nonisolated static func installTap(
        on node: AVAudioInputNode,
        converter: AnalyzerInputConverter,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        node.installTap(onBus: 0, bufferSize: 4096, format: node.outputFormat(forBus: 0)) { buffer, _ in
            guard let inputs = try? converter.convert(buffer, at: nil) else { return }
            for input in inputs {
                continuation.yield(input)
            }
        }
    }
}
