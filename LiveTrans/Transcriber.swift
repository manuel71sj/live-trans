import AVFoundation
import Speech

#if os(macOS)
typealias InputDeviceID = AudioDeviceID
#else
// iOS는 입력 장치를 고르지 않고 시스템 라우트를 그대로 쓴다.
typealias InputDeviceID = Never
#endif

/// 마이크 입력을 SpeechAnalyzer로 전사한다.
@MainActor
final class Transcriber {
    private var engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    /// 음성 모델을 준비하고 전사를 시작한다. 반환된 시퀀스는 [주 언어, 보조 언어?] 순서이고, 중지 후 확정 결과까지 내보내고 끝난다.
    /// secondary가 있으면 같은 오디오를 그 언어로도 함께 전사한다.
    /// inputDevice가 nil이면 시스템 기본 입력 장치를 쓴다.
    func start(locale: Locale, secondary: Locale?, inputDevice: InputDeviceID?) async throws -> [some AsyncSequence<SpeechTranscriber.Result, any Error>] {
        // 신뢰도는 두 언어의 결과를 견줄 때만 쓴다. 보조 언어가 없으면 옵션도 예전 그대로 둔다.
        let attributes: Set<SpeechTranscriber.ResultAttributeOption> = secondary == nil
            ? [.audioTimeRange] : [.audioTimeRange, .transcriptionConfidence]
        let modules = [locale, secondary].compactMap { $0 }.map {
            SpeechTranscriber(
                locale: $0,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: attributes
            )
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }

        // 시작마다 엔진을 새로 만들어, 이전에 지정한 장치가 남지 않고 기본 장치로 돌아가게 한다.
        // 분석기를 띄우기 전에 지정해 실패해도 정리할 것이 없게 한다.
        engine = AVAudioEngine()
        #if os(macOS)
        if let inputDevice {
            try Self.setDevice(inputDevice, of: engine.inputNode)
        }
        #endif

        let converter = try await AnalyzerInputConverter.converter(compatibleWith: modules)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.start(inputSequence: stream)

        do {
            #if os(iOS)
            // 세션을 켜기 전에 inputNode를 건드리면 입력 형식이 무효(0 Hz)가 되어 installTap에서 죽는다.
            // 입력 장치는 고르지 않고 시스템 라우트를 그대로 쓴다.
            // 분석기를 띄운 뒤에 켜서, 그 전에 실패하면 돌려줄 세션이 없게 한다.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record)
            try session.setActive(true)
            #endif
            Self.installTap(on: engine.inputNode, converter: converter, continuation: continuation)
            engine.prepare()
            try engine.start()
        } catch {
            // 탭이 남으면 다음 시작에서 같은 버스에 중복 설치돼 앱이 종료된다.
            engine.inputNode.removeTap(onBus: 0)
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            throw error
        }

        self.analyzer = analyzer
        self.continuation = continuation
        return modules.map(\.results)
    }

    func stop() async throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        // 세션을 돌려주지 않으면 시작할 때 멈춘 다른 앱의 소리가 중지한 뒤에도 돌아오지 않는다.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        continuation?.finish()
        continuation = nil
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
    }

    #if os(macOS)
    /// 탭을 걸기 전에 지정해야 입력 형식이 그 장치 기준으로 잡힌다.
    private static func setDevice(_ device: AudioDeviceID, of node: AVAudioInputNode) throws {
        var device = device
        let status = node.withAudioUnit { unit in
            AudioUnitSetProperty(
                unit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &device,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
    #endif

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
