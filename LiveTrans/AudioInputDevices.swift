import CoreAudio

/// Core Audio에 연결된 입력 장치. 설정에는 다시 연결해도 바뀌지 않는 UID를 저장한다.
struct AudioInputDevice: Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioInputDevices {
    /// 입력 스트림이 있는 장치만 고른다. 출력 전용 장치(스피커 등)는 빠진다.
    static func all() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap(device)
    }

    /// 시스템 설정 > 사운드 > 입력에서 고른 기본 입력 장치
    static func systemDefault() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else {
            return nil
        }
        return device(id)
    }

    /// 장치가 연결·분리되거나 시스템 기본 입력 장치가 바뀔 때마다 알린다.
    static func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
            // 등록과 해제에 같은 블록 객체를 넘겨야 해제된다. 만든 뒤 바뀌지 않으므로 해제 클로저에 넘겨도 안전하다.
            nonisolated(unsafe) let block: AudioObjectPropertyListenerBlock = { _, _ in continuation.yield() }
            for selector in selectors {
                var address = systemAddress(selector)
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            }
            continuation.onTermination = { _ in
                for selector in selectors {
                    var address = systemAddress(selector)
                    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
                }
            }
        }
    }

    private static func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func device(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard hasInput(id),
              let uid = string(kAudioDevicePropertyDeviceUID, of: id),
              let name = string(kAudioObjectPropertyName, of: id)
        else { return nil }
        return AudioInputDevice(id: id, uid: uid, name: name)
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
