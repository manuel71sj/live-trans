import AppKit
import Security
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
    /// 후보정 제공자(RefineProvider.rawValue). 모델·effort는 제공자마다 따로 저장한다. effort 빈 문자열은 보내지 않음.
    static let refineProvider = "refineProvider"
    static let openAIModel = "openAIModel"
    static let openAIEffort = "openAIEffort"
    static let claudeModel = "claudeModel"
    static let claudeEffort = "claudeEffort"
    /// 로컬 LLM의 Base URL. `/v1`까지 적는다.
    static let localBaseURL = "localBaseURL"
    static let localModel = "localModel"
    static let localEffort = "localEffort"
}

enum RefineProvider: String, CaseIterable {
    case onDevice, openAI, claude, local

    var label: String {
        switch self {
        case .onDevice: "온디바이스"
        case .openAI: "OpenAI API"
        case .claude: "Claude API"
        case .local: "로컬 LLM (OpenAI 호환)"
        }
    }
}

/// 후보정 한 번에 쓰는 설정. API 키는 담지 않고 호출할 때 키체인에서 읽는다.
struct RefineSettings: Sendable {
    let provider: RefineProvider
    let model: String
    let effort: String
    let baseURL: String

    static func current() -> RefineSettings {
        let defaults = UserDefaults.standard
        func string(_ key: String) -> String { defaults.string(forKey: key) ?? "" }
        let provider = RefineProvider(rawValue: string(SettingsKey.refineProvider)) ?? .onDevice
        switch provider {
        case .onDevice:
            return RefineSettings(provider: provider, model: "", effort: "", baseURL: "")
        case .openAI:
            return RefineSettings(provider: provider, model: string(SettingsKey.openAIModel), effort: string(SettingsKey.openAIEffort), baseURL: "")
        case .claude:
            return RefineSettings(provider: provider, model: string(SettingsKey.claudeModel), effort: string(SettingsKey.claudeEffort), baseURL: "")
        case .local:
            return RefineSettings(provider: provider, model: string(SettingsKey.localModel), effort: string(SettingsKey.localEffort), baseURL: string(SettingsKey.localBaseURL))
        }
    }
}

/// API 키는 로그인 키체인에 제공자별로 둔다. 서명이 ad-hoc이라 데이터 보호 키체인은 쓰지 않는다.
private let keychainService = "kr.manuel71.LiveTrans"

private func keychainQuery(_ provider: RefineProvider) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: provider.rawValue,
    ]
}

nonisolated func readAPIKey(for provider: RefineProvider) -> String {
    var query = keychainQuery(provider)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
    return String(decoding: data, as: UTF8.self)
}

/// 갱신하고, 항목이 없을 때만 추가한다. 지운 뒤 추가하면 추가가 실패할 때 기존 키를 잃는다.
nonisolated func writeAPIKey(_ key: String, for provider: RefineProvider) {
    let data = Data(key.utf8)
    let status = SecItemUpdate(keychainQuery(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
        var attributes = keychainQuery(provider)
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }
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
    @AppStorage(SettingsKey.refineProvider) private var provider = RefineProvider.onDevice
    @AppStorage(SettingsKey.openAIModel) private var openAIModel = ""
    @AppStorage(SettingsKey.openAIEffort) private var openAIEffort = ""
    @AppStorage(SettingsKey.claudeModel) private var claudeModel = ""
    @AppStorage(SettingsKey.claudeEffort) private var claudeEffort = ""
    @AppStorage(SettingsKey.localBaseURL) private var localBaseURL = ""
    @AppStorage(SettingsKey.localModel) private var localModel = ""
    @AppStorage(SettingsKey.localEffort) private var localEffort = ""
    @State private var apiKey = ""
    @State private var fontFamilies: [String] = []
    @State private var inputDevices: [AudioInputDevice] = []

    /// 고른 제공자의 모델·effort 저장 값
    private var model: Binding<String> {
        switch provider {
        case .onDevice: .constant("")
        case .openAI: $openAIModel
        case .claude: $claudeModel
        case .local: $localModel
        }
    }

    private var effort: Binding<String> {
        switch provider {
        case .onDevice: .constant("")
        case .openAI: $openAIEffort
        case .claude: $claudeEffort
        case .local: $localEffort
        }
    }

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
            Section("후보정") {
                Picker("제공자", selection: $provider) {
                    ForEach(RefineProvider.allCases, id: \.self) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                if provider != .onDevice {
                    if provider == .local {
                        TextField("Base URL", text: $localBaseURL, prompt: Text("http://192.168.0.10:8000/v1"))
                    }
                    TextField("모델", text: model)
                    Picker("Effort", selection: effort) {
                        Text("지정 안 함").tag("")
                        Text("low").tag("low")
                        Text("medium").tag("medium")
                        Text("high").tag("high")
                    }
                    SecureField(provider == .local ? "API 키 (선택)" : "API 키", text: $apiKey)
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
        // 제공자를 바꾸면 그 제공자의 키를 다시 읽는다.
        .task(id: provider) {
            if provider != .onDevice { apiKey = readAPIKey(for: provider) }
        }
        .onChange(of: apiKey) {
            if provider != .onDevice { writeAPIKey(apiKey, for: provider) }
        }
    }
}
