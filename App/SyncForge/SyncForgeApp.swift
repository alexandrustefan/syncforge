import AppKit
import SwiftUI
import SyncForgeCore

@main
struct SyncForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("SyncForge", id: "main") {
            MainWindow()
                .environment(model)
        }
        .defaultSize(width: 980, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Audio") {
                Toggle("SyncForge Active", isOn: model.engine.enabledBinding)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Calibrate Speakers") {
                    model.section = .calibration
                    model.calibrate()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!model.engine.isEnabled || model.calibration.isRunning)
                Divider()
                Button("Volume Up") { model.nudgeMasterVolume(0.05) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Volume Down") { model.nudgeMasterVolume(-0.05) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button(model.settings.masterMuted ? "Unmute" : "Mute") { model.toggleMasterMute() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
            }
            CommandGroup(after: .sidebar) {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { model.section = section }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
    }
}

/// Menu bar icon: reflects whether the engine is active, calibrating or has a problem.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let engine = model.engine
        let symbol: String = {
            if model.calibration.micInUse || model.liveSync.micInUse { return "waveform.badge.mic" }
            if !engine.isEnabled { return "hifispeaker" }
            if case .failed = engine.captureStatus { return "exclamationmark.triangle" }
            return "hifispeaker.2.fill"
        }()
        Image(systemName: symbol)
            .accessibilityLabel("SyncForge")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created at launch so a previously active configuration resumes without opening any UI.
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // A menu bar utility: show the main window on the very first launch only.
        let key = "hasLaunchedBefore"
        if UserDefaults.standard.bool(forKey: key) {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true { window.close() }
            }
        } else {
            UserDefaults.standard.set(true, forKey: key)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop the tap so normal playback resumes immediately (the system would also clean up the
        // private tap and aggregate device if we crashed).
        model.engine.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
