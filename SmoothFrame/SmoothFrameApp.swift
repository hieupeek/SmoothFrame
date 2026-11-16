import SwiftUI

/// SmoothFrame — standalone macOS frame-interpolation player.
/// Swift 6, SwiftUI, macOS 14+, Apple Silicon.
/// NOTE: written on a Linux VM without Xcode/Swift — NOT yet compiled or run
/// on a Mac. Open SmoothFrame.xcodeproj in Xcode 16 on a Mac to build.
@main
struct SmoothFrameApp: App {
    @AppStorage("showStats") private var showStats = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") {
                    NotificationCenter.default.post(name: .smoothFrameOpenFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("View") {
                Toggle("Show Stats", isOn: $showStats)
                    .keyboardShortcut("i", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let smoothFrameOpenFile = Notification.Name("com.hieupeek.SmoothFrame.openFile")
}
