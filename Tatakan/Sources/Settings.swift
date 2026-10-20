import AppKit
import SwiftUI
import ServiceManagement

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var shakeEnabled: Bool { didSet { d.set(shakeEnabled, forKey: "shakeEnabled") } }
    @Published var shakeSensitivity: Double { didSet { d.set(shakeSensitivity, forKey: "shakeSensitivity") } }
    @Published var removeAfterDrag: Bool { didSet { d.set(removeAfterDrag, forKey: "removeAfterDrag") } }
    @Published var closeWhenEmpty: Bool { didSet { d.set(closeWhenEmpty, forKey: "closeWhenEmpty") } }
    @Published var excludedApps: [String] { didSet { d.set(excludedApps, forKey: "excludedApps") } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    // Notch
    @Published var notchEnabled: Bool { didSet { d.set(notchEnabled, forKey: "notchEnabled"); NotificationCenter.default.post(name: .tatakanNotchToggled, object: nil) } }
    @Published var notchOpenOnHover: Bool { didSet { d.set(notchOpenOnHover, forKey: "notchOpenOnHover") } }
    @Published var notchMediaPeek: Bool { didSet { d.set(notchMediaPeek, forKey: "notchMediaPeek") } }
    @Published var liveActivities: Bool { didSet { d.set(liveActivities, forKey: "liveActivities") } }

    private init() {
        d.register(defaults: ["shakeEnabled": true, "shakeSensitivity": 0.5,
                              "removeAfterDrag": true, "closeWhenEmpty": true,
                              "notchEnabled": true, "notchOpenOnHover": true, "notchMediaPeek": true,
                              "liveActivities": true])
        shakeEnabled = d.bool(forKey: "shakeEnabled")
        shakeSensitivity = d.double(forKey: "shakeSensitivity")
        removeAfterDrag = d.bool(forKey: "removeAfterDrag")
        closeWhenEmpty = d.bool(forKey: "closeWhenEmpty")
        excludedApps = d.stringArray(forKey: "excludedApps") ?? []
        notchEnabled = d.bool(forKey: "notchEnabled")
        notchOpenOnHover = d.bool(forKey: "notchOpenOnHover")
        notchMediaPeek = d.bool(forKey: "notchMediaPeek")
        liveActivities = d.bool(forKey: "liveActivities")
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSLog("Tatakan login item: \(error)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // Recent shelves (max 10)
    var recent: [Shelf.Snapshot] {
        get {
            guard let data = d.data(forKey: "recentShelves"),
                  let list = try? JSONDecoder().decode([Shelf.Snapshot].self, from: data) else { return [] }
            return list
        }
        set {
            let trimmed = Array(newValue.prefix(10))
            d.set(try? JSONEncoder().encode(trimmed), forKey: "recentShelves")
        }
    }
}

/// @State is a macro unavailable without Xcode → use a tiny ObservableObject.
extension Notification.Name { static let tatakanNotchToggled = Notification.Name("tatakanNotchToggled") }

final class PickState: ObservableObject { @Published var picked = "" }

struct SettingsView: View {
    @ObservedObject var s = Settings.shared
    @StateObject private var ui = PickState()

    private var runningApps: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a in a.bundleIdentifier.map { ($0, a.localizedName ?? $0) } }
            .filter { !s.excludedApps.contains($0.0) && $0.0 != Bundle.main.bundleIdentifier }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section("Notch") {
                Toggle("Use the notch (Nook + Tray)", isOn: $s.notchEnabled)
                Toggle("Open when the pointer reaches the notch", isOn: $s.notchOpenOnHover)
                    .disabled(!s.notchEnabled)
                Toggle("Show album art & bars beside the notch while music plays", isOn: $s.notchMediaPeek)
                    .disabled(!s.notchEnabled)
                Toggle("Live activities (battery, Bluetooth, timer)", isOn: $s.liveActivities)
                    .disabled(!s.notchEnabled)
                LabeledContent("Toggle the Nook", value: "⌃⌥N")
            }
            Section("Shelf") {
                Toggle("Open a shelf when I shake the pointer while dragging", isOn: $s.shakeEnabled)
                LabeledContent("Shake sensitivity") {
                    HStack {
                        Text("Calm").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $s.shakeSensitivity, in: 0...1).frame(width: 160)
                        Text("Eager").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!s.shakeEnabled)
                Toggle("Remove items after dragging them out", isOn: $s.removeAfterDrag)
                Toggle("Close the shelf when it becomes empty", isOn: $s.closeWhenEmpty)
            }
            Section("Shortcut") {
                LabeledContent("New shelf", value: "⌃⌥Space")
                LabeledContent("On a shelf", value: "Space Quick Look · ⌘C ⌘V · ⌫ remove · Esc close")
            }
            Section("Don't shake in these apps") {
                ForEach(s.excludedApps, id: \.self) { bid in
                    HStack {
                        Text(appName(bid))
                        Spacer()
                        Button { s.excludedApps.removeAll { $0 == bid } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Picker("Add app", selection: $ui.picked) {
                        Text("Choose a running app…").tag("")
                        ForEach(runningApps, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Button("Add") {
                        if !ui.picked.isEmpty { s.excludedApps.append(ui.picked); ui.picked = "" }
                    }.disabled(ui.picked.isEmpty)
                }
            }
            Section {
                Toggle("Launch at login", isOn: Binding(get: { s.launchAtLogin }, set: { s.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func appName(_ bid: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bid
    }
}
