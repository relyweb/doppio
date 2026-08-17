// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Tabbed Preferences UI. All persistence/side effects live in `SettingsModel`.
struct PreferencesView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }
            IntegrationsSettings(model: model).tabItem { Label("Integrations", systemImage: "cpu") }
            ScheduleSettings(model: model).tabItem { Label("Schedule", systemImage: "calendar") }
            AdvancedSettings(model: model).tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 470, height: 360)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel
    private let floors = Array(stride(from: 30, through: 90, by: 10))

    var body: some View {
        Form {
            Toggle("Keep display on", isOn: $model.keepDisplayOn)
            Toggle("Pause on battery when low", isOn: $model.pauseOnBattery)
            Picker("Pause below", selection: $model.batteryFloor) {
                ForEach(floors, id: \.self) { Text("\($0)%").tag($0) }
            }
            .frame(width: 180)
            .disabled(!model.pauseOnBattery)
            Text("Automatic reasons (integrations, watched process, schedule) pause below this level. Manual and timer keep-awake still hold down to \(AwakeCoordinator.hardBatteryFloor)%, below which the Mac always sleeps to protect the battery.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Allow when lid closed (AC only · needs admin)", isOn: $model.allowLidClosed)
            Toggle("Show notifications", isOn: $model.notificationsEnabled)
            Toggle("Start at login", isOn: $model.startAtLogin)

            Divider()

            Toggle("Global hotkey", isOn: $model.hotkeyEnabled)
            HStack {
                Text("Shortcut:")
                Text(model.hotkeyDisplay).font(.system(.body, design: .monospaced)).bold()
                Spacer()
                Button("Change…") { model.changeHotkey() }
            }
            .disabled(!model.hotkeyEnabled)
        }
        .padding()
    }
}

// MARK: - Integrations

struct IntegrationsSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Text("Keep the Mac awake while any of these is running:")
                .foregroundColor(.secondary)
            Toggle("Claude Code", isOn: $model.claude)
            Toggle("Oh My Pi", isOn: $model.omp)
            Toggle("OpenCode", isOn: $model.opencode)
            Toggle("Codex", isOn: $model.codex)
            Toggle("Gemini", isOn: $model.gemini)

            Divider()

            Text("Custom processes (one name per line):").foregroundColor(.secondary)
            TextEditor(text: $model.customProcesses)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
        }
        .padding()
    }
}

// MARK: - Schedule

struct ScheduleSettings: View {
    @ObservedObject var model: SettingsModel
    private static let dayLabels = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        Form {
            Toggle("Keep awake on a weekly schedule", isOn: $model.scheduleEnabled)

            DatePicker("From", selection: $model.scheduleStart, displayedComponents: .hourAndMinute)
                .disabled(!model.scheduleEnabled)
            DatePicker("To", selection: $model.scheduleEnd, displayedComponents: .hourAndMinute)
                .disabled(!model.scheduleEnabled)

            VStack(alignment: .leading, spacing: 6) {
                Text("Days").foregroundColor(.secondary)
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { wd in
                        Toggle(Self.dayLabels[wd], isOn: dayBinding(wd))
                            .toggleStyle(.button)
                            .controlSize(.small)
                    }
                }
            }
            .disabled(!model.scheduleEnabled)

            Text("Overnight windows (e.g. 22:00–06:00) are supported.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding()
    }

    private func dayBinding(_ wd: Int) -> Binding<Bool> {
        Binding(
            get: { model.weekdays.contains(wd) },
            set: { on in
                if on { model.weekdays.insert(wd) } else { model.weekdays.remove(wd) }
            })
    }
}

// MARK: - Advanced

struct AdvancedSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            HStack {
                Text("Grace period after a task ends:")
                Spacer()
                Text("\(Int(model.graceSeconds))s").monospacedDigit()
            }
            Slider(value: $model.graceSeconds, in: 0...600, step: 15)

            HStack {
                Text("Process poll interval:")
                Spacer()
                Text("\(String(format: "%.0f", model.pollSeconds))s").monospacedDigit()
            }
            Slider(value: $model.pollSeconds, in: 1...30, step: 1)

            Text("Detection is presence-based, so long model calls never let the Mac sleep mid-task.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding()
    }
}

// MARK: - Headless render (QA)

/// Renders a single Preferences tab to a PNG via `ImageRenderer` — used by the
/// `--render-prefs <tab> <path>` command to verify layout without a display.
@MainActor
enum PreferencesRenderer {
    static func render(tab: String, to path: String) {
        let model = SettingsModel(coordinator: AwakeCoordinator())
        // (Renders with current settings; no persistence side effects.)

        let content: AnyView
        switch tab {
        case "general":      content = AnyView(GeneralSettings(model: model))
        case "integrations": content = AnyView(IntegrationsSettings(model: model))
        case "schedule":     content = AnyView(ScheduleSettings(model: model))
        case "advanced":     content = AnyView(AdvancedSettings(model: model))
        default:             content = AnyView(PreferencesView(model: model))
        }
        let view = content
            .frame(width: 470, height: 340)
            .background(Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
