import AppKit
import SwiftUI

/// @AppStorage 키. 설정 창과 본 창이 같은 값을 읽는다.
enum SettingsKey {
    static let theme = "theme"
    /// 빈 문자열은 시스템 기본 글꼴
    static let fontFamily = "fontFamily"
    /// 원문 본문 크기. 번역은 이보다 2pt 크다.
    static let fontSize = "fontSize"
    /// 빈 문자열은 시스템 기본 입력 장치
    static let inputDeviceUID = "inputDeviceUID"
}

enum Theme: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: "시스템 설정"
        case .light: "라이트"
        case .dark: "다크"
        }
    }

    /// nil이면 시스템 외관을 따른다.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct SettingsView: View {
    @AppStorage(SettingsKey.theme) private var theme = Theme.system
    @AppStorage(SettingsKey.fontFamily) private var fontFamily = ""
    @AppStorage(SettingsKey.fontSize) private var fontSize = 15.0
    @AppStorage(SettingsKey.inputDeviceUID) private var inputDeviceUID = ""
    @State private var fontFamilies: [String] = []
    @State private var inputDevices: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section("화면") {
                Picker("테마", selection: $theme) {
                    ForEach(Theme.allCases, id: \.self) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                Picker("본문 글꼴", selection: $fontFamily) {
                    Text("시스템 기본").tag("")
                    Divider()
                    ForEach(fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                LabeledContent("글자 크기") {
                    Text("원문 \(Int(fontSize))pt · 번역 \(Int(fontSize) + 2)pt")
                    Stepper("글자 크기", value: $fontSize, in: 11...32, step: 1)
                        .labelsHidden()
                }
            }
            Section("오디오") {
                Picker("입력 장치", selection: $inputDeviceUID) {
                    Text("시스템 기본").tag("")
                    Divider()
                    ForEach(inputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        // 설정 창 높이를 내용에 맞춘다. 지정하지 않으면 Form이 늘어나 아래가 빈다.
        .fixedSize(horizontal: false, vertical: true)
        .task {
            fontFamilies = NSFontManager.shared.availableFontFamilies.sorted()
            inputDevices = AudioInputDevices.all()
        }
    }
}
