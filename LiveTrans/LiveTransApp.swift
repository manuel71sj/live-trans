import SwiftUI

@main
struct LiveTransApp: App {
    @AppStorage(SettingsKey.theme) private var theme = Theme.system

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onChange(of: theme, initial: true, applyTheme)
        }
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
