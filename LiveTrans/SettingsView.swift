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
    /// 전사 원문을 AI로 보정하고 그 보정본으로 번역할지
    static let correctEnabled = "correctEnabled"
}

/// 언어 모델 설정 한 벌의 저장 키. 후보정과 전사 보정이 한 벌씩 따로 갖는다.
/// 제공자는 RefineProvider.rawValue, 모델·effort는 제공자마다 따로 저장한다. effort 빈 문자열은 보내지 않음.
struct LLMSettingsKeys: Sendable {
    let provider: String
    let openAIModel: String
    let openAIEffort: String
    let claudeModel: String
    let claudeEffort: String
    /// 로컬 LLM의 Base URL. `/v1`까지 적는다.
    let localBaseURL: String
    let localModel: String
    let localEffort: String

    static let refine = LLMSettingsKeys(
        provider: "refineProvider",
        openAIModel: "openAIModel", openAIEffort: "openAIEffort",
        claudeModel: "claudeModel", claudeEffort: "claudeEffort",
        localBaseURL: "localBaseURL", localModel: "localModel", localEffort: "localEffort"
    )
    static let correct = LLMSettingsKeys(
        provider: "correctProvider",
        openAIModel: "correctOpenAIModel", openAIEffort: "correctOpenAIEffort",
        claudeModel: "correctClaudeModel", claudeEffort: "correctClaudeEffort",
        localBaseURL: "correctLocalBaseURL", localModel: "correctLocalModel", localEffort: "correctLocalEffort"
    )
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

/// 언어 모델 호출 한 번에 쓰는 설정(후보정·전사 보정 공통). API 키는 담지 않고 호출할 때 키체인에서 읽는다.
struct RefineSettings: Sendable {
    let provider: RefineProvider
    let model: String
    let effort: String
    let baseURL: String

    static func current(_ keys: LLMSettingsKeys = .refine) -> RefineSettings {
        let defaults = UserDefaults.standard
        func string(_ key: String) -> String { defaults.string(forKey: key) ?? "" }
        let provider = RefineProvider(rawValue: string(keys.provider)) ?? .onDevice
        switch provider {
        case .onDevice:
            return RefineSettings(provider: provider, model: "", effort: "", baseURL: "")
        case .openAI:
            return RefineSettings(provider: provider, model: string(keys.openAIModel), effort: string(keys.openAIEffort), baseURL: "")
        case .claude:
            return RefineSettings(provider: provider, model: string(keys.claudeModel), effort: string(keys.claudeEffort), baseURL: "")
        case .local:
            return RefineSettings(provider: provider, model: string(keys.localModel), effort: string(keys.localEffort), baseURL: string(keys.localBaseURL))
        }
    }
}

extension Notification.Name {
    /// 키체인의 API 키가 바뀌었다. 같은 제공자를 보이는 다른 설정 구획이 키를 다시 읽는다.
    static let apiKeyChanged = Notification.Name("apiKeyChanged")
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

/// 제공자의 모델 목록 API(GET <base>/models)에서 모델 id를 받아 온다.
nonisolated func fetchModelIDs(provider: RefineProvider, baseURL: String, apiKey: String) async throws -> [String] {
    let base: String
    switch provider {
    case .onDevice: return []
    case .openAI: base = "https://api.openai.com/v1"
    case .claude: base = "https://api.anthropic.com/v1"
    case .local: base = baseURL
    }
    guard var url = URL(string: base)?.appending(path: "models") else { throw URLError(.badURL) }
    // Claude는 한 번에 20개만 주므로 최대치로 받는다.
    if provider == .claude { url.append(queryItems: [URLQueryItem(name: "limit", value: "1000")]) }
    var request = URLRequest(url: url)
    if provider == .claude {
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    } else if !apiKey.isEmpty {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }
    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode(ModelList.self, from: data).data.map(\.id).sorted()
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
    @AppStorage(SettingsKey.correctEnabled) private var correctEnabled = false
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
            Section("전사 보정") {
                Toggle("AI로 전사 보정", isOn: $correctEnabled)
                if correctEnabled {
                    LLMSettingsFields(keys: .correct)
                }
            }
            Section("후보정") {
                LLMSettingsFields(keys: .refine)
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

/// 언어 모델 설정 한 벌의 입력 칸(제공자·Base URL·모델·Effort·API 키). 후보정과 전사 보정 구획이 함께 쓴다.
private struct LLMSettingsFields: View {
    @AppStorage private var provider: RefineProvider
    @AppStorage private var openAIModel: String
    @AppStorage private var openAIEffort: String
    @AppStorage private var claudeModel: String
    @AppStorage private var claudeEffort: String
    @AppStorage private var localBaseURL: String
    @AppStorage private var localModel: String
    @AppStorage private var localEffort: String
    @State private var apiKey = ""
    /// 고른 제공자의 API에서 받아 온 모델 id. 비어 있으면 모델을 직접 입력한다.
    @State private var models: [String] = []

    init(keys: LLMSettingsKeys) {
        _provider = AppStorage(wrappedValue: .onDevice, keys.provider)
        _openAIModel = AppStorage(wrappedValue: "", keys.openAIModel)
        _openAIEffort = AppStorage(wrappedValue: "", keys.openAIEffort)
        _claudeModel = AppStorage(wrappedValue: "", keys.claudeModel)
        _claudeEffort = AppStorage(wrappedValue: "", keys.claudeEffort)
        _localBaseURL = AppStorage(wrappedValue: "", keys.localBaseURL)
        _localModel = AppStorage(wrappedValue: "", keys.localModel)
        _localEffort = AppStorage(wrappedValue: "", keys.localEffort)
    }

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
        Group {
            Picker("제공자", selection: $provider) {
                ForEach(RefineProvider.allCases, id: \.self) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            if provider != .onDevice {
                if provider == .local {
                    TextField("Base URL", text: $localBaseURL, prompt: Text("http://192.168.0.10:8000/v1"))
                }
                if models.isEmpty {
                    TextField("모델", text: model)
                } else {
                    Picker("모델", selection: model) {
                        // 저장된 값이 목록에 없으면 그 값도 보여 고른 것이 바뀌지 않게 한다.
                        if !models.contains(model.wrappedValue) {
                            Text(model.wrappedValue.isEmpty ? "선택 안 함" : model.wrappedValue).tag(model.wrappedValue)
                        }
                        ForEach(models, id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }
                }
                Picker("Effort", selection: effort) {
                    Text("지정 안 함").tag("")
                    Text("low").tag("low")
                    Text("medium").tag("medium")
                    Text("high").tag("high")
                }
                SecureField(provider == .local ? "API 키 (선택)" : "API 키", text: $apiKey)
            }
        }
        // 제공자를 바꾸면 그 제공자의 키를 다시 읽는다.
        .task(id: provider) {
            if provider != .onDevice { apiKey = readAPIKey(for: provider) }
        }
        // 제공자·주소·키가 바뀌면 모델 목록을 다시 받는다. 받지 못하면 직접 입력 칸이 남는다.
        // 잠깐 기다렸다 보내므로, 키를 입력하는 도중의 값이나 제공자를 바꾼 직후의 이전 제공자 키는 나가지 않는다.
        .task(id: [provider.rawValue, localBaseURL, apiKey]) {
            models = []
            guard provider != .onDevice else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            models = (try? await fetchModelIDs(provider: provider, baseURL: localBaseURL, apiKey: apiKey)) ?? []
        }
        .onChange(of: apiKey) {
            guard provider != .onDevice, apiKey != readAPIKey(for: provider) else { return }
            writeAPIKey(apiKey, for: provider)
            NotificationCenter.default.post(name: .apiKeyChanged, object: nil)
        }
        // 키는 제공자별로 하나라, 다른 구획에서 같은 제공자의 키를 바꾸면 여기 칸도 따라간다.
        .onReceive(NotificationCenter.default.publisher(for: .apiKeyChanged)) { _ in
            if provider != .onDevice { apiKey = readAPIKey(for: provider) }
        }
    }
}
