import AppKit
import ServiceManagement
import Carbon.HIToolbox

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
            button.image = nil
        }

        // Live countdown, shown only while a timer is running.
        if coordinator.isActive, let remaining = coordinator.timeRemaining {
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
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
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
        let header = NSMenuItem(
            title: statusTitle,
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

        // ---- Integrations ----
        let intHeader = NSMenuItem(title: "Stay Awake While Running", action: nil, keyEquivalent: "")
        intHeader.isEnabled = false
        menu.addItem(intHeader)
        let snap = coordinator.currentSnapshot
        addIntegration(to: menu, title: "Claude Code", running: snap.hits["Claude Code"] == true,
                       isOn: prefs.integrationClaude, action: #selector(toggleClaude))
        addIntegration(to: menu, title: "Oh My Pi", running: snap.hits["Oh My Pi"] == true,
                       isOn: prefs.integrationOmp, action: #selector(toggleOmp))
        addIntegration(to: menu, title: "OpenCode", running: snap.hits["OpenCode"] == true,
                       isOn: prefs.integrationOpencode, action: #selector(toggleOpencode))
        addIntegration(to: menu, title: "Codex", running: snap.hits["Codex"] == true,
                       isOn: prefs.integrationCodex, action: #selector(toggleCodex))
        addIntegration(to: menu, title: "Gemini", running: snap.hits["Gemini"] == true,
                       isOn: prefs.integrationGemini, action: #selector(toggleGemini))
        let custom = NSMenuItem(title: "Custom Processes…", action: #selector(editCustomProcesses), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)

        menu.addItem(.separator())

        // ---- Options ----
        addToggle(to: menu, title: "Keep Display On", isOn: prefs.keepDisplayOn, action: #selector(toggleDisplay))
        addToggle(to: menu, title: "Pause on Battery", isOn: prefs.pauseOnBattery,
                  action: #selector(toggleBattery))
        addToggle(to: menu, title: "Allow When Lid Closed (AC power only, needs admin)",
                  isOn: prefs.allowLidClosed, action: #selector(toggleLid))
        addToggle(to: menu, title: "Global Hotkey (\(hotkeyDisplay()))",
                  isOn: prefs.globalHotkeyEnabled, action: #selector(toggleHotkey))
        let changeHotkey = NSMenuItem(title: "Change Hotkey…",
                                      action: #selector(changeHotkey), keyEquivalent: "")
        changeHotkey.target = self
        menu.addItem(changeHotkey)
        addToggle(to: menu,
                  title: prefs.scheduleEnabled ? "On Schedule (\(scheduleSummary()))" : "Keep Awake on Schedule",
                  isOn: prefs.scheduleEnabled, action: #selector(toggleSchedule))
        let editSched = NSMenuItem(title: "Configure Schedule…",
                                   action: #selector(configureSchedule), keyEquivalent: "")
        editSched.target = self
        menu.addItem(editSched)
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
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        if running {
            // Green "running" indicator. NSMenuItem titles are otherwise plain
            // text (menu-default color), so the dot is colored via an
            // attributed title while the label keeps the adaptive default.
            let label = "\(title)  ●"
            let attributed = NSMutableAttributedString(string: label)
            let dot = (label as NSString).range(of: "●", options: .backwards)
            attributed.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: dot)
            item.attributedTitle = attributed
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
    @objc private func toggleCodex() {
        prefs.integrationCodex.toggle(); coordinator.reconfigureMonitor()
    }
    @objc private func toggleGemini() {
        prefs.integrationGemini.toggle(); coordinator.reconfigureMonitor()
    }

    @objc private func toggleDisplay() {
        prefs.keepDisplayOn.toggle(); coordinator.optionsChanged()
    }

    @objc private func toggleLid() {
        prefs.allowLidClosed.toggle(); coordinator.optionsChanged()
    }

    @objc private func toggleBattery() {
        prefs.pauseOnBattery.toggle(); coordinator.optionsChanged()
    }

    @objc private func toggleHotkey() {
        prefs.globalHotkeyEnabled.toggle()
        if prefs.globalHotkeyEnabled { registerHotkey() }
        else { HotKeyManager.shared.unregister() }
    }

    @objc private func changeHotkey() {
        guard let hk = recordHotKey() else { return }
        prefs.hotKeyCode = Int(hk.keyCode)
        prefs.hotKeyModifiers = Int(hk.modifiers)
        prefs.hotKeyLabel = hk.label
        prefs.globalHotkeyEnabled = true
        if !registerHotkey() {
            let alert = NSAlert()
            alert.messageText = "Couldn't set that shortcut"
            alert.informativeText = "\(hotkeyDisplay()) is unavailable (already used by the system or another app). Try a different combination."
            alert.alertStyle = .warning
            activateAndRun(alert)
        }
    }

    private func hotkeyDisplay() -> String {
        HotKeyManager.display(modifiers: UInt32(prefs.hotKeyModifiers), label: prefs.hotKeyLabel)
    }

    @discardableResult
    private func registerHotkey() -> Bool {
        HotKeyManager.shared.register(keyCode: UInt32(prefs.hotKeyCode),
                                      modifiers: UInt32(prefs.hotKeyModifiers))
    }

    @objc private func toggleSchedule() {
        prefs.scheduleEnabled.toggle(); coordinator.optionsChanged()
    }

    @objc private func configureSchedule() {
        if promptForSchedule() { coordinator.optionsChanged() }
    }

    @objc private func watchProcess() {
        guard let picked = promptForProcess() else { return }
        coordinator.watch(pid: picked.pid, name: picked.name)
    }

    @objc private func clearWatches() { coordinator.clearWatches() }

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
        Keeps your Mac awake for Claude Code, omp, opencode, Codex, Gemini and \
        other agentic tasks — even when locked or with the lid closed.

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

    // MARK: - Schedule & process helpers

    private func scheduleSummary() -> String {
        let days = Self.weekdaysLabel(Set(prefs.scheduleWeekdays))
        return "\(days) \(Schedule.formatMinutes(prefs.scheduleStartMinutes))–\(Schedule.formatMinutes(prefs.scheduleEndMinutes))"
    }

    private static func weekdaysLabel(_ days: Set<Int>) -> String {
        if days == Set(2...6) { return "Mon–Fri" }
        if days == Set(1...7) { return "Every day" }
        if days == [1, 7] { return "Weekends" }
        let syms = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return days.sorted().compactMap { $0 >= 1 && $0 <= 7 ? syms[$0] : nil }.joined(separator: ",")
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

    private func promptForSchedule() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Keep Awake on Schedule"
        alert.informativeText = "Stay awake during this weekly window."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 120))
        let startPicker = NSDatePicker(frame: NSRect(x: 60, y: 90, width: 90, height: 24))
        let endPicker = NSDatePicker(frame: NSRect(x: 210, y: 90, width: 90, height: 24))
        for (p, m) in [(startPicker, prefs.scheduleStartMinutes), (endPicker, prefs.scheduleEndMinutes)] {
            p.datePickerStyle = .textFieldAndStepper
            p.datePickerElements = .hourMinute
            p.dateValue = Self.dateForMinutes(m)
        }
        view.addSubview(Self.label("From", x: 8, y: 92, width: 46))
        view.addSubview(startPicker)
        view.addSubview(Self.label("to", x: 176, y: 92, width: 30))
        view.addSubview(endPicker)

        let syms: [(Int, String)] = [(1, "Sun"), (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat")]
        let current = Set(prefs.scheduleWeekdays)
        var boxes: [(Int, NSButton)] = []
        var x: CGFloat = 4
        for (wd, s) in syms {
            let b = NSButton(checkboxWithTitle: s, target: nil, action: nil)
            b.frame = NSRect(x: x, y: 40, width: 46, height: 20)
            b.state = current.contains(wd) ? .on : .off
            view.addSubview(b)
            boxes.append((wd, b))
            x += 46
        }
        alert.accessoryView = view
        guard activateAndRun(alert) == .alertFirstButtonReturn else { return false }

        prefs.scheduleStartMinutes = Self.minutes(from: startPicker.dateValue)
        prefs.scheduleEndMinutes = Self.minutes(from: endPicker.dateValue)
        prefs.scheduleWeekdays = boxes.filter { $0.1.state == .on }.map { $0.0 }
        prefs.scheduleEnabled = true
        return true
    }

    private static func dateForMinutes(_ m: Int) -> Date {
        Calendar.current.date(bySettingHour: (m / 60) % 24, minute: m % 60, second: 0, of: Date()) ?? Date()
    }

    private static func minutes(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private static func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.frame = NSRect(x: x, y: y, width: width, height: 18)
        return l
    }

    // MARK: - Hotkey recorder

    /// Modal capture of the next key combination. Returns nil on cancel/Esc.
    private func recordHotKey() -> (keyCode: UInt32, modifiers: UInt32, label: String)? {
        let alert = NSAlert()
        alert.messageText = "Change Hotkey"
        alert.informativeText = "Press the new shortcut (must include ⌘, ⌥, ⌃ or ⇧).\nCurrent: \(hotkeyDisplay())   ·   Esc to cancel"
        alert.addButton(withTitle: "Cancel")

        var result: (keyCode: UInt32, modifiers: UInt32, label: String)?
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                NSApp.stopModal(withCode: .cancel); return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods: UInt32 = 0
            if flags.contains(.command) { mods |= UInt32(cmdKey) }
            if flags.contains(.option)  { mods |= UInt32(optionKey) }
            if flags.contains(.control) { mods |= UInt32(controlKey) }
            if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
            guard mods != 0 else { return nil }   // need a modifier; keep waiting
            result = (UInt32(event.keyCode), mods, Self.keyLabel(for: event))
            NSApp.stopModal(withCode: .stop)
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSEvent.removeMonitor(monitor)
        return result
    }

    private static func keyLabel(for event: NSEvent) -> String {
        let specials: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let s = specials[Int(event.keyCode)] { return s }
        if let ch = event.charactersIgnoringModifiers, let first = ch.unicodeScalars.first,
           first.value >= 0x20 {
            return ch.uppercased()
        }
        return "key\(event.keyCode)"
    }
}
