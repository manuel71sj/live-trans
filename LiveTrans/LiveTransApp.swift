import SwiftUI
import Sparkle

@main
struct LiveTransApp: App {
    @AppStorage(SettingsKey.theme) private var theme = Theme.system

    #if !DEBUG
    // 디버그 빌드는 설치된 앱과 번들 ID·defaults를 공유해 업데이트로 릴리스 빌드에 교체될 수 있어 릴리스에서만 켠다.
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onChange(of: theme, initial: true, applyTheme)
        }
        #if !DEBUG
        .commands {
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인…") { updaterController.checkForUpdates(nil) }
            }
        }
        #endif
        Settings {
            SettingsView()
                .onChange(of: theme, initial: true, applyTheme)
        }
    }

    /// 앱 전체 외관을 바꿔 본 창과 설정 창이 함께 바뀐다. Palette의 동적 색도 이 외관을 따른다.
    private func applyTheme() {
        NSApp.appearance = theme.appearance
    }
}
