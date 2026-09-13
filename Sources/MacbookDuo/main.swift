import AppKit

/// Menu-bar agent. No dock icon, no windows other than the click-through overlay.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = FoldController()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()

        if !controller.start() {
            presentNoSensorAlert()
            return
        }
        controller.onStateChange = { [weak self] in self?.refreshMenu() }
        refreshMenu()

        if !controller.hasScreenAccess, !CommandLine.arguments.contains("--hold") {
            controller.requestScreenAccess()
            presentScreenAccessAlert()
        } else if CommandLine.arguments.contains("--hold") {
            if let path = ProcessInfo.processInfo.environment["DUO_IMAGE"] {
                if let image = NSImage(contentsOfFile: path),
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    controller.debugFrame = cgImage
                } else {
                    NSLog("MacbookDuo: could not load debug frame at \(path)")
                }
            }
            let strength = ProcessInfo.processInfo.environment["DUO_STRENGTH"].flatMap(Double.init) ?? 1.0
            let travel = ProcessInfo.processInfo.environment["DUO_TRAVEL"].flatMap(Double.init) ?? 18.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.controller.holdPreview(strength: strength, travel: travel)
            }
        } else if CommandLine.arguments.contains("--demo") {
            // Give the capture stream a moment to deliver its first frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.controller.runDemo()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "macbook.and.iphone",
            accessibilityDescription: "MacbookDuo"
        )
        item.menu = NSMenu()
        statusItem = item
        refreshMenu()
    }

    private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let angle = menu.addItem(
            withTitle: String(format: "Lid angle: %.0f°", controller.lastAngle),
            action: nil, keyEquivalent: ""
        )
        angle.isEnabled = false

        if !controller.hasScreenAccess {
            let warning = menu.addItem(
                withTitle: "Screen Recording not granted",
                action: #selector(openScreenRecordingSettings), keyEquivalent: ""
            )
            warning.target = self
        }

        let toggle = menu.addItem(
            withTitle: controller.isEnabled ? "Pause fold effect" : "Resume fold effect",
            action: #selector(toggleEnabled), keyEquivalent: ""
        )
        toggle.target = self

        let demo = menu.addItem(withTitle: "Preview fold effect", action: #selector(runDemo), keyEquivalent: "")
        demo.target = self
        demo.isEnabled = controller.isEnabled && controller.hasScreenAccess

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit MacbookDuo", action: #selector(quit), keyEquivalent: "q")
        quit.target = self

        // Keep the angle readout live while the menu is open.
        menu.delegate = self
    }

    @objc private func toggleEnabled() {
        controller.setEnabled(!controller.isEnabled)
    }

    @objc private func runDemo() {
        controller.runDemo()
    }

    @objc private func openScreenRecordingSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )!
        NSWorkspace.shared.open(url)
    }

    private func presentScreenAccessAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
        MacbookDuo freezes the current screen image while the lid moves, so it needs \
        Screen Recording access. Enable MacbookDuo under Privacy & Security > Screen \
        Recording, then relaunch the app.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func presentNoSensorAlert() {
        let alert = NSAlert()
        alert.messageText = "No lid angle sensor found"
        alert.informativeText = """
        MacbookDuo needs the built-in lid angle sensor, which is present on MacBooks from \
        2019 onwards. This Mac does not report one, so the fold effect cannot run.
        """
        alert.alertStyle = .warning
        alert.runModal()
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // The delegate is owned by the top-level scope for the lifetime of the process.
    withExtendedLifetime(delegate) {
        app.run()
    }
}
