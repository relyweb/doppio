import AppKit
import SwiftUI

/// Owns the single Preferences window. Uses the native macOS "preferences"
/// toolbar style (tabs live in the title bar, like System Settings) so the tab
/// controls can never overlap the title bar. Each tab swaps the hosted SwiftUI
/// content.
@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private let model: SettingsModel
    private var window: NSWindow?
    private var current: Tab = .general

    // Fixed content size keeps the window steady when switching tabs.
    private static let contentSize = NSSize(width: 480, height: 380)

    private enum Tab: String, CaseIterable {
        case general, integrations, schedule, advanced

        var title: String {
            switch self {
            case .general: return "General"
            case .integrations: return "Integrations"
            case .schedule: return "Schedule"
            case .advanced: return "Advanced"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .integrations: return "cpu"
            case .schedule: return "calendar"
            case .advanced: return "slider.horizontal.3"
            }
        }
        var id: NSToolbarItem.Identifier { .init(rawValue) }
    }

    init(coordinator: AwakeCoordinator) {
        self.model = SettingsModel(coordinator: coordinator)
        super.init()
    }

    func show() {
        model.reload()   // reflect changes made from the menu/hotkey since last open

        if window == nil { buildWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if let window, !window.isVisible { window.center() }
    }

    // MARK: - Window

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.delegate = self

        let toolbar = NSToolbar(identifier: "DoppioPreferencesToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = current.id
        win.toolbar = toolbar
        win.toolbarStyle = .preference

        window = win
        select(current)
        win.center()
    }

    private func select(_ tab: Tab) {
        current = tab
        window?.title = tab.title
        window?.toolbar?.selectedItemIdentifier = tab.id

        let root = tabView(tab).frame(width: Self.contentSize.width, height: Self.contentSize.height)
        let hosting = NSHostingController(rootView: root)
        window?.contentViewController = hosting
        window?.setContentSize(Self.contentSize)
    }

    @ViewBuilder
    private func tabView(_ tab: Tab) -> some View {
        switch tab {
        case .general:      GeneralSettings(model: model)
        case .integrations: IntegrationsSettings(model: model)
        case .schedule:     ScheduleSettings(model: model)
        case .advanced:     AdvancedSettings(model: model)
        }
    }

    @objc private func selectTab(_ sender: NSToolbarItem) {
        if let tab = Tab(rawValue: sender.itemIdentifier.rawValue) { select(tab) }
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = Tab(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(selectTab(_:))
        item.isBordered = true
        return item
    }

    private var tabIDs: [NSToolbarItem.Identifier] { Tab.allCases.map(\.id) }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { tabIDs }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { tabIDs }
    func toolbarSelectableItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { tabIDs }
}
