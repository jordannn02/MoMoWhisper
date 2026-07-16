import AppKit
import SwiftUI

@main
struct MoMoWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandMenu("音訊") {
                Button("開始/停止錄音") {
                    appDelegate.requestRecordingToggle()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("測試系統音訊") {
                    appDelegate.requestSystemAudioTest()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Button("開啟螢幕與系統錄音設定") {
                    SpeechTranscriptionService.openSystemAudioPermissionSettings()
                }
                .keyboardShortcut(",", modifiers: [.command, .option])
            }
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private enum TerminationState {
        case idle
        case flushing
        case approved
    }

    private let transcriber = SpeechTranscriptionService()
    private var window: NSWindow?
    private var terminationState: TerminationState = .idle
    private var terminationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch terminationState {
        case .approved:
            return .terminateNow
        case .flushing:
            return .terminateLater
        case .idle:
            break
        }

        window?.makeFirstResponder(nil)
        window?.ignoresMouseEvents = true
        terminationState = .flushing
        terminationTask = Task { @MainActor [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            let saved = await transcriber.prepareForTermination()
            terminationTask = nil
            if saved {
                terminationState = .approved
            } else {
                terminationState = .idle
                window?.ignoresMouseEvents = false
                showMainWindow()
            }
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

    private func showMainWindow() {
        if window == nil {
            let contentView = ContentView()
                .environmentObject(transcriber)

            let hostingController = NSHostingController(rootView: contentView)
            let mainWindow = NSWindow(
                contentRect: NSRect(x: 80, y: 90, width: 1180, height: 712),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            mainWindow.title = "MoMoWhisper"
            mainWindow.contentViewController = hostingController
            mainWindow.isReleasedWhenClosed = false
            mainWindow.setFrameAutosaveName("MoMoWhisperMainWindow")
            window = mainWindow
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func requestSystemAudioTest() {
        guard terminationState == .idle else { return }
        showMainWindow()
        Task { @MainActor in
            await transcriber.testSystemAudioCapture()
        }
    }

    func requestRecordingToggle() {
        guard terminationState == .idle else { return }
        showMainWindow()
        Task { @MainActor in
            await transcriber.toggleRecording()
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "結束 MoMoWhisper",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let audioMenuItem = NSMenuItem()
        let audioMenu = NSMenu(title: "音訊")

        let testItem = NSMenuItem(
            title: "測試系統音訊",
            action: #selector(testSystemAudioCapture(_:)),
            keyEquivalent: "u"
        )
        testItem.keyEquivalentModifierMask = [.command, .shift]
        testItem.target = self
        audioMenu.addItem(testItem)

        let permissionItem = NSMenuItem(
            title: "開啟螢幕與系統錄音設定",
            action: #selector(openSystemAudioPermissionSettings(_:)),
            keyEquivalent: ","
        )
        permissionItem.keyEquivalentModifierMask = [.command, .option]
        permissionItem.target = self
        audioMenu.addItem(permissionItem)

        audioMenuItem.submenu = audioMenu
        mainMenu.addItem(audioMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func testSystemAudioCapture(_ sender: Any?) {
        requestSystemAudioTest()
    }

    @objc private func openSystemAudioPermissionSettings(_ sender: Any?) {
        SpeechTranscriptionService.openSystemAudioPermissionSettings()
    }

    nonisolated func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        true
    }
}
