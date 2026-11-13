import SwiftUI
#if os(macOS)
import Sparkle
#endif

@main
struct LiveTransApp: App {
    @AppStorage(SettingsKey.theme) private var theme = Theme.system

    #if os(macOS) && !DEBUG
    // 디버그 빌드는 설치된 앱과 번들 ID·defaults를 공유해 업데이트로 릴리스 빌드에 교체될 수 있어 릴리스에서만 켠다.
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            ContentView()
                .onChange(of: theme, initial: true, applyTheme)
            #else
            // iOS는 NavigationStack이 없으면 .toolbar가 보이지 않는다.
            NavigationStack { ContentView() }
                .onChange(of: theme, initial: true, applyTheme)
            #endif
        }
        #if os(macOS) && !DEBUG
        .commands {
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인…") { updaterController.checkForUpdates(nil) }
            }
        }
        #endif
        #if os(macOS)
        Settings {
            SettingsView()
                .onChange(of: theme, initial: true, applyTheme)
        }
        #endif
    }

    /// 앱 전체 외관을 바꿔 본 창과 설정 창이 함께 바뀐다. Palette의 동적 색도 이 외관을 따른다.
    private func applyTheme() {
        #if os(macOS)
        NSApp.appearance = theme.appearance
        #else
        // 설정 시트도 같은 window에 뜨므로 window 외관을 바꾸면 함께 바뀐다.
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = theme.appearance
            }
        }
        #endif
    }
}
