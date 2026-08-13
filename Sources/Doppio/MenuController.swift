import AppKit

/// Builds and drives the menu-bar (`NSStatusItem`) UI. The menu stays lean —
/// status plus quick actions (manual, timer, watch) — while all configuration
/// lives in the Preferences window. Rebuilt on open so it always reflects
/// live state.
@MainActor
final class MenuController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let coordinator: AwakeCoordinator
    private lazy var preferences = PreferencesWindowController(coordinator: coordinator)

    init(coordinator: AwakeCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        coordinator.onStateChange = { [weak self] in self?.updateIcon() }
        updateIcon()
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let active = coordinator.isActive
        let symbol = active ? "cup.and.saucer.fill" : "cup.and.saucer"
        let desc = active ? "Doppio active" : "Doppio idle"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: desc) {
            img.isTemplate = true
            button.image = img
        } else {
            button.image = nil
        }

        // Live countdown, shown only while a timer is actually keeping us awake.
        if active, let remaining = coordinator.timeRemaining {
            button.title = " " + Self.formatCountdown(remaining)
            button.imagePosition = .imageLeft
        } else {
            button.title = button.image == nil ? (active ? "●" : "○") : ""
            button.imagePosition = .imageOnly
        }
        button.toolTip = "Doppio — \(coordinator.reasonSummary)"
    }

    /// Compact countdown: "M:SS" under an hour, "H:MM:SS" beyond.
    private static func formatCountdown(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    // MARK: - Menu construction

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // ---- Status header ----
        let statusTitle: String
        if coordinator.isActive {
            statusTitle = "Awake — \(coordinator.reasonSummary)"
        } else if coordinator.batterySuppressed {
            statusTitle = "Paused on battery — \(coordinator.reasonSummary)"
        } else {
            statusTitle = "Sleep allowed (idle)"
        }
        let header = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // ---- Manual toggle ----
        let manual = NSMenuItem(title: "Keep Awake Indefinitely",
                                action: #selector(toggleManual), keyEquivalent: "")
        manual.target = self
        manual.state = coordinator.manualIndefinite ? .on : .off
        menu.addItem(manual)

        // ---- Timer submenu ----
        let timerItem = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        let timerMenu = NSMenu()
        let durations: [(String, TimeInterval)] = [
            ("15 minutes", 15 * 60), ("30 minutes", 30 * 60), ("1 hour", 60 * 60),
            ("2 hours", 2 * 60 * 60), ("4 hours", 4 * 60 * 60), ("8 hours", 8 * 60 * 60),
        ]
        for (title, secs) in durations {
            let it = NSMenuItem(title: title, action: #selector(startDurationTimer(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = secs
            timerMenu.addItem(it)
        }
        timerMenu.addItem(.separator())
        let untilItem = NSMenuItem(title: "Until a Specific Time…", action: #selector(startUntilTimer), keyEquivalent: "")
        untilItem.target = self
        timerMenu.addItem(untilItem)
        if coordinator.timerActive {
            timerMenu.addItem(.separator())
            let stop = NSMenuItem(title: "Turn Off Timer", action: #selector(stopTimer), keyEquivalent: "")
            stop.target = self
            timerMenu.addItem(stop)
        }
        timerItem.submenu = timerMenu
        menu.addItem(timerItem)

        // ---- Watch a process ----
        let watchItem = NSMenuItem(title: "Keep Awake Until Process Exits…",
                                   action: #selector(watchProcess), keyEquivalent: "")
        watchItem.target = self
        menu.addItem(watchItem)
        if !coordinator.watched.isEmpty {
            let stopAll = NSMenuItem(title: "Stop Waiting on Processes",
                                     action: #selector(clearWatches), keyEquivalent: "")
            stopAll.target = self
            menu.addItem(stopAll)
        }

        menu.addItem(.separator())

        // ---- Preferences / About / Quit ----
        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        let about = NSMenuItem(title: "About Doppio", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit Doppio", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func toggleManual() {
        coordinator.setManualIndefinite(!coordinator.manualIndefinite)
    }

    @objc private func startDurationTimer(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? TimeInterval else { return }
        coordinator.setTimer(for: secs)
    }

    @objc private func startUntilTimer() {
        guard let date = promptForTime() else { return }
        coordinator.setTimer(until: date)
    }

    @objc private func stopTimer() { coordinator.clearTimer() }

    @objc private func watchProcess() {
        guard let picked = promptForProcess() else { return }
        coordinator.watch(pid: picked.pid, name: picked.name)
    }

    @objc private func clearWatches() { coordinator.clearWatches() }

    @objc private func openPreferences() { preferences.show() }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Doppio"
        alert.informativeText = """
        Keeps your Mac awake for Claude Code, omp, opencode, Codex, Gemini and \
        other agentic tasks — even when locked or with the lid closed.

        • System stays awake via IOKit power assertions.
        • Lid-closed mode uses `pmset disablesleep` (admin required).
        • Detection is presence-based, so long model calls never trigger sleep.
        """
        alert.alertStyle = .informational
        activateAndRun(alert)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Dialogs

    private func promptForTime() -> Date? {
        let alert = NSAlert()
        alert.messageText = "Keep Awake Until"
        alert.informativeText = "Choose the time to stay awake until. If it is earlier than now, it rolls over to tomorrow."
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")

        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.dateValue = Date().addingTimeInterval(60 * 60)
        alert.accessoryView = picker

        guard activateAndRun(alert) == .alertFirstButtonReturn else { return nil }

        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: picker.dateValue)
        var target = cal.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: Date()) ?? Date()
        if target <= Date() { target = cal.date(byAdding: .day, value: 1, to: target) ?? target }
        return target
    }

    private func promptForProcess() -> (pid: Int32, name: String)? {
        let procs = Self.userProcesses()
        guard !procs.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = "Keep Awake Until a Process Exits"
        alert.informativeText = "Choose a running process. Doppio stays awake until it quits."
        alert.addButton(withTitle: "Watch")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        for p in procs { popup.addItem(withTitle: "\(p.name) (\(p.pid))") }
        alert.accessoryView = popup
        guard activateAndRun(alert) == .alertFirstButtonReturn else { return nil }
        let idx = popup.indexOfSelectedItem
        guard idx >= 0, idx < procs.count else { return nil }
        return procs[idx]
    }

    private static func userProcesses() -> [(pid: Int32, name: String)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-xo", "pid=,comm="]
        let out = Pipe(); proc.standardOutput = out; proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let me = ProcessInfo.processInfo.processIdentifier
        var result: [(pid: Int32, name: String)] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let sp = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[..<sp]), pid != me else { continue }
            let name = (String(trimmed[trimmed.index(after: sp)...])
                .trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
            if !name.isEmpty { result.append((pid: pid, name: name)) }
        }
        return result.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Bring the (accessory) app forward so modal dialogs are usable, then run.
    @discardableResult
    private func activateAndRun(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
