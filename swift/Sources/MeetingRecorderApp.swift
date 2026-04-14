import SwiftUI

@main
struct MeetingRecorderApp: App {
    @StateObject private var state = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanelView(state: state)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Window("Meeting Recorder", id: "main") {
            MainView(state: state, recordingStore: state.recordingStore)
                .onAppear {
                    // Auto-open on first launch
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 860, height: 560)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        if state.isRecording {
            HStack(spacing: 4) {
                Image(systemName: "record.circle.fill")
                    .foregroundColor(.red)
                Text(state.elapsedString)
                    .monospacedDigit()
            }
        } else if state.transcribeStep == .running || state.saveStep == .running {
            HStack(spacing: 4) {
                Image(systemName: "mic.fill")
                Text("...")
            }
        } else {
            Image(systemName: "mic.fill")
        }
    }
}
