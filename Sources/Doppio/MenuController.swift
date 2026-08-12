import AppKit
import ServiceManagement

/// Builds and drives the menu-bar (`NSStatusItem`) UI. The menu is rebuilt each
/// time it opens so status, countdown, and checkmarks always reflect live state.
final class MenuController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let coordinator: AwakeCoordinator
    private let prefs = Preferences.shared

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
            button.title = active ? "●" : "○"
        }
        button.toolTip = "Doppio — \(coordinator.reasonSummary)"
    }

    // MARK: - Menu construction

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // ---- Status header ----
        let active = coordinator.isActive
        let header = NSMenuItem(
            title: active ? "Awake — \(coordinator.reasonSummary)" : "Sleep allowed (idle)",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // ---- Manual toggle ----
        addToggle(to: menu, title: "Keep Awake Indefinitely",
                  isOn: coordinator.manualIndefinite,
                  action: #selector(toggleManual))

        // ---- Timer submenu ----
        let timerItem = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        let timerMenu = NSMenu()
        let durations: [(String, TimeInterval)] = [
            ("15 minutes", 15 * 60),
            ("30 minutes", 30 * 60),
            ("1 hour", 60 * 60),
            ("2 hours", 2 * 60 * 60),
            ("4 hours", 4 * 60 * 60),
            ("8 hours", 8 * 60 * 60),
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

        menu.addItem(.separator())

        // ---- Integrations ----
        let intHeader = NSMenuItem(title: "Stay Awake While Running", action: nil, keyEquivalent: "")
        intHeader.isEnabled = false
        menu.addItem(intHeader)
        let snap = coordinator.currentSnapshot
        addIntegration(to: menu, title: "Claude Code", running: snap.hits["Claude Code"] == true,
                       isOn: prefs.integrationClaude, action: #selector(toggleClaude))
        addIntegration(to: menu, title: "omp", running: snap.hits["omp"] == true,
                       isOn: prefs.integrationOmp, action: #selector(toggleOmp))
        addIntegration(to: menu, title: "opencode", running: snap.hits["opencode"] == true,
                       isOn: prefs.integrationOpencode, action: #selector(toggleOpencode))
        let custom = NSMenuItem(title: "Custom Processes…", action: #selector(editCustomProcesses), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)

        menu.addItem(.separator())

        // ---- Options ----
        addToggle(to: menu, title: "Keep Display On", isOn: prefs.keepDisplayOn, action: #selector(toggleDisplay))
        addToggle(to: menu, title: "Allow When Lid Closed (needs admin)",
                  isOn: prefs.allowLidClosed, action: #selector(toggleLid))
        addToggle(to: menu, title: "Start at Login", isOn: isLoginEnabled(), action: #selector(toggleLogin))

        menu.addItem(.separator())

        // ---- Footer ----
        let about = NSMenuItem(title: "About Doppio", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit Doppio", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Menu helpers

    private func addToggle(to menu: NSMenu, title: String, isOn: Bool, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        menu.addItem(item)
    }

    private func addIntegration(to menu: NSMenu, title: String, running: Bool, isOn: Bool, action: Selector) {
        let label = running ? "\(title)  ●" : title
        let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        if running {
            item.toolTip = "\(title) is currently running"
        }
        menu.addItem(item)
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

    @objc private func toggleClaude() {
        prefs.integrationClaude.toggle(); coordinator.reconfigureMonitor()
    }
    @objc private func toggleOmp() {
        prefs.integrationOmp.toggle(); coordinator.reconfigureMonitor()
    }
    @objc private func toggleOpencode() {
        prefs.integrationOpencode.toggle(); coordinator.reconfigureMonitor()
    }

    @objc private func toggleDisplay() {
        prefs.keepDisplayOn.toggle(); coordinator.optionsChanged()
    }

    @objc private func toggleLid() {
        prefs.allowLidClosed.toggle(); coordinator.optionsChanged()
    }

    @objc private func toggleLogin() {
        setLoginEnabled(!isLoginEnabled())
    }

    @objc private func editCustomProcesses() {
        let current = prefs.customProcesses.joined(separator: "\n")
        guard let text = promptForText(
            title: "Custom Processes",
            message: "One process name per line. Any running process whose command matches will keep the Mac awake.",
            initial: current) else { return }
        let names = text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        prefs.customProcesses = names
        coordinator.reconfigureMonitor()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Doppio"
        alert.informativeText = """
        Keeps your Mac awake for Claude Code, omp, opencode and other agentic \
        tasks — even when locked or with the lid closed.

        • System stays awake via IOKit power assertions.
        • Lid-closed mode uses `pmset disablesleep` (admin required).
        • Detection is presence-based, so long model calls never trigger sleep.
        """
        alert.alertStyle = .informational
        activateAndRun(alert)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Login item (SMAppService)

    private func isLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    private func setLoginEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change login item"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            activateAndRun(alert)
        }
    }

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

        // Combine today's date with the chosen time; roll to tomorrow if past.
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: picker.dateValue)
        var target = cal.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: Date()) ?? Date()
        if target <= Date() { target = cal.date(byAdding: .day, value: 1, to: target) ?? target }
        return target
    }

    private func promptForText(title: String, message: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        let textView = NSTextView(frame: scroll.bounds)
        textView.string = initial
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll

        guard activateAndRun(alert) == .alertFirstButtonReturn else { return nil }
        return textView.string
    }

    /// Bring the (accessory) app forward so modal dialogs are usable, then run.
    @discardableResult
    private func activateAndRun(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
