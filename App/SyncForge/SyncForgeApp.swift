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
            CommandGroup(replacing: .undoRedo) {
                Button(undoTitle) { undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!canUndo)
                Button(redoTitle) { redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!canRedo)
            }
            CommandMenu("Audio") {
                Toggle("SyncForge Active", isOn: model.engine.enabledBinding)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.calibration.isRunning)
                Button("Calibrate Speakers") {
                    model.section = .calibration
                    model.calibrate()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!model.engine.isEnabled || model.calibration.isRunning)
                Divider()
                Button("Volume Up") { model.nudgeMasterVolume(0.05) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(model.calibration.isRunning)
                Button("Volume Down") { model.nudgeMasterVolume(-0.05) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(model.calibration.isRunning)
                Button(model.settings.masterMuted ? "Unmute" : "Mute") { model.toggleMasterMute() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                    .disabled(model.calibration.isRunning)
            }
            CommandGroup(after: .sidebar) {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { model.section = section }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
    }

    // Preserve ordinary text-field undo while editing names or numbers. Outside a field, Cmd-Z
    // operates on audio edits, including a whole slider drag as one change.
    private var activeTextEditor: NSTextView? {
        _ = model.textEditingRevision
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable else { return nil }
        return editor
    }

    private var undoTitle: String {
        if let editor = activeTextEditor { return editor.undoManager?.undoMenuItemTitle ?? "Undo" }
        let name = model.engine.undoActionName
        return name.isEmpty ? "Undo" : "Undo \(name)"
    }

    private var redoTitle: String {
        if let editor = activeTextEditor { return editor.undoManager?.redoMenuItemTitle ?? "Redo" }
        let name = model.engine.redoActionName
        return name.isEmpty ? "Redo" : "Redo \(name)"
    }

    private var canUndo: Bool {
        guard !model.calibration.isRunning else { return false }
        if let editor = activeTextEditor { return editor.undoManager?.canUndo ?? false }
        return model.engine.canUndo
    }

    private var canRedo: Bool {
        guard !model.calibration.isRunning else { return false }
        if let editor = activeTextEditor { return editor.undoManager?.canRedo ?? false }
        return model.engine.canRedo
    }

    private func undo() {
        guard !model.calibration.isRunning else { return }
        if let editor = activeTextEditor { editor.undoManager?.undo() }
        else { model.engine.undo() }
    }

    private func redo() {
        guard !model.calibration.isRunning else { return }
        if let editor = activeTextEditor { editor.undoManager?.redo() }
        else { model.engine.redo() }
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
