import AppKit
import SwiftUI
import EventKit
import IOKit.ps
import AVFoundation
import IOBluetooth

// MARK: - Now Playing (via the perl-hosted MediaRemote adapter)

final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    @Published var title = ""
    @Published var artist = ""
    @Published var bundle = ""
    @Published var playing = false
    @Published var duration: Double = 0
    @Published var art: NSImage?
    private var elapsed: Double = 0
    private var stamp: Double = 0
    private var rate: Double = 0
    private var artPath = ""

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var restarts = 0

    var hasMedia: Bool { !title.isEmpty }
    var appName: String {
        guard !bundle.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return "" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Current position, extrapolated between updates.
    func position(at date: Date = Date()) -> Double {
        guard playing, rate > 0 else { return min(elapsed, duration) }
        return min(elapsed + (date.timeIntervalSince1970 - stamp) * rate, duration)
    }

    func start() {
        guard process == nil,
              let lib = Bundle.main.url(forResource: "libTatakanMedia", withExtension: "dylib") else { return }
        let loader = #"use DynaLoader; my $l = DynaLoader::dl_load_file($ARGV[0], 0) or die; my $f = DynaLoader::dl_find_symbol($l, "tatakan_stream") or die; DynaLoader::dl_install_xsub("main::run_stream", $f); run_stream();"#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", loader, lib.path]
        var env = ProcessInfo.processInfo.environment
        env["TATAKAN_ART_DIR"] = Ingest.cacheDir.appendingPathComponent("NowPlaying").path
        p.environment = env
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                self.restarts += 1
                if self.restarts < 5 { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start() } }
            }
        }
        do { try p.run(); process = p; input = inp.fileHandleForWriting } catch { NSLog("Tatakan media: \(error)") }
    }

    func stop() { process?.terminationHandler = nil; process?.terminate(); process = nil }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            title = o["title"] as? String ?? ""
            artist = o["artist"] as? String ?? ""
            bundle = o["bundle"] as? String ?? ""
            playing = o["playing"] as? Bool ?? false
            duration = o["duration"] as? Double ?? 0
            elapsed = o["elapsed"] as? Double ?? 0
            stamp = o["timestamp"] as? Double ?? Date().timeIntervalSince1970
            rate = o["rate"] as? Double ?? 0
            if playing && rate == 0 { rate = 1 }
            let a = o["art"] as? String ?? ""
            if a != artPath {
                artPath = a
                art = a.isEmpty ? nil : NSImage(contentsOfFile: a)
            }
        }
    }

    private func send(_ cmd: String) { input?.write((cmd + "\n").data(using: .utf8)!) }
    func toggle() { playing.toggle(); send("toggle") }
    func next() { send("next") }
    func previous() { send("prev") }
    func seek(_ t: Double) {
        elapsed = t; stamp = Date().timeIntervalSince1970
        send("seek \(t)")
    }
}

// MARK: - Calendar

final class CalendarModel: ObservableObject {
    static let shared = CalendarModel()
    private let store = EKEventStore()
    @Published var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published var day = Calendar.current.startOfDay(for: Date())
    @Published var events: [EKEvent] = []

    var granted: Bool { access == .fullAccess || access == .authorized }

    func request() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.access = EKEventStore.authorizationStatus(for: .event)
                self?.reload()
            }
        }
    }

    func reload() {
        access = EKEventStore.authorizationStatus(for: .event)
        guard granted else { events = []; return }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let pred = store.predicateForEvents(withStart: day, end: end, calendars: nil)
        events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
    }

    func shift(_ days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day)!
        reload()
    }
}

// MARK: - Timer

final class TimerModel: ObservableObject {
    static let shared = TimerModel()
    @Published var total: TimeInterval = 25 * 60
    @Published var remaining: TimeInterval = 25 * 60
    @Published var running = false
    @Published var finished = false
    private var end: Date?
    private var tick: Timer?
    var onFinish: (() -> Void)?

    func set(minutes: Int) {
        stop()
        total = TimeInterval(minutes * 60); remaining = total; finished = false
    }

    func nudge(_ minutes: Int) {
        let v = max(60, min(remaining + TimeInterval(minutes * 60), 180 * 60))
        if running { end = Date().addingTimeInterval(v) }
        remaining = v
        if !running { total = v }
    }

    func toggle() { running ? pause() : startRun() }

    private func startRun() {
        if remaining <= 0 { remaining = total }
        finished = false
        end = Date().addingTimeInterval(remaining)
        running = true
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.update() }
    }

    func pause() { update(); running = false; tick?.invalidate(); end = nil }
    func stop() { running = false; tick?.invalidate(); end = nil; remaining = total; finished = false }

    private func update() {
        guard let end else { return }
        remaining = max(0, end.timeIntervalSinceNow)
        if remaining <= 0 {
            running = false; tick?.invalidate(); self.end = nil; finished = true
            NSSound(named: "Glass")?.play()
            onFinish?()
        }
    }

    var label: String {
        let s = Int(remaining.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Notes & To-do (stored in UserDefaults)

struct TodoItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var done = false
    var starred = false
}

final class NotesModel: ObservableObject {
    static let shared = NotesModel()
    private let d = UserDefaults.standard
    @Published var note: String { didSet { d.set(note, forKey: "nookNote") } }
    @Published var todos: [TodoItem] { didSet { d.set(try? JSONEncoder().encode(todos), forKey: "nookTodos") } }
    @Published var draft = ""

    private init() {
        note = d.string(forKey: "nookNote") ?? ""
        todos = (d.data(forKey: "nookTodos").flatMap { try? JSONDecoder().decode([TodoItem].self, from: $0) }) ?? []
    }

    func add() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        todos.insert(TodoItem(text: t), at: 0); draft = ""
    }

    func toggle(_ t: TodoItem) {
        guard let i = todos.firstIndex(of: t) else { return }
        todos[i].done.toggle()
        // done tasks sink to the bottom; more than 12 done → oldest are archived away
        todos.sort { ($0.done ? 1 : 0, $0.starred ? 0 : 1) < ($1.done ? 1 : 0, $1.starred ? 0 : 1) }
        let done = todos.filter(\.done)
        if done.count > 12 { let drop = Set(done.suffix(done.count - 12).map(\.id)); todos.removeAll { drop.contains($0.id) } }
    }

    func star(_ t: TodoItem) {
        guard let i = todos.firstIndex(of: t) else { return }
        todos[i].starred.toggle()
        todos.sort { ($0.done ? 1 : 0, $0.starred ? 0 : 1) < ($1.done ? 1 : 0, $1.starred ? 0 : 1) }
    }

    func remove(_ t: TodoItem) { todos.removeAll { $0.id == t.id } }
}

// MARK: - Live activities (battery, Bluetooth, timer, track changes)

struct LiveActivity: Equatable {
    var symbol: String
    var left: String
    var right: String
    var accent = false
}

final class LiveActivities: ObservableObject {
    static let shared = LiveActivities()
    @Published var current: LiveActivity?
    private var hide: DispatchWorkItem?
    private var powerSource: CFRunLoopSource?
    private var lastCharging: Bool?
    private var lastLowWarned = false
    private var btConnectNote: IOBluetoothUserNotification?
    private var btDisconnectNotes: [IOBluetoothUserNotification] = []
    private var startedAt = Date()

    func show(_ a: LiveActivity, seconds: Double = 3) {
        current = a
        hide?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.current = nil }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    static func battery() -> (percent: Int, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cap = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (cap * 100 / max, charging)
        }
        return nil
    }

    func start() {
        lastCharging = LiveActivities.battery()?.charging
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<LiveActivities>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.powerChanged() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            powerSource = src
        }
        // Event-driven Bluetooth: the system calls us on connect/disconnect (no polling).
        startedAt = Date()
        btConnectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(btConnected(_:device:)))
    }

    @objc private func btConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let d = device.register(forDisconnectNotification: self, selector: #selector(btDisconnected(_:device:))) {
            btDisconnectNotes.append(d)
        }
        // The register call replays devices already connected at launch; stay quiet for those.
        guard Date().timeIntervalSince(startedAt) > 2, Settings.shared.liveActivities else { return }
        show(LiveActivity(symbol: LiveActivities.symbol(for: device), left: device.name ?? "Device", right: "Connected", accent: true))
    }

    @objc private func btDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        btDisconnectNotes.removeAll { $0 === note }
        guard Settings.shared.liveActivities else { return }
        show(LiveActivity(symbol: LiveActivities.symbol(for: device), left: device.name ?? "Device", right: "Disconnected"))
    }

    static func symbol(for d: IOBluetoothDevice) -> String {
        switch d.deviceClassMajor {
        case 0x04: return "headphones"                    // audio/video
        case 0x05: return d.deviceClassMinor & 0x10 != 0 ? "keyboard" : "computermouse"   // peripheral
        case 0x02: return "iphone"
        default: return "dot.radiowaves.left.and.right"
        }
    }

    private func powerChanged() {
        guard Settings.shared.liveActivities, let b = LiveActivities.battery() else { return }
        if b.charging != lastCharging {
            lastCharging = b.charging
            show(LiveActivity(symbol: b.charging ? "bolt.fill" : "battery.75percent",
                              left: b.charging ? "Charging" : "On battery", right: "\(b.percent)%", accent: b.charging))
        } else if !b.charging && b.percent <= 20 && !lastLowWarned {
            lastLowWarned = true
            show(LiveActivity(symbol: "battery.25percent", left: "Low battery", right: "\(b.percent)%", accent: true), seconds: 4)
        }
        if b.percent > 25 { lastLowWarned = false }
    }

}

// MARK: - Mirror (front camera)

final class MirrorModel: ObservableObject {
    static let shared = MirrorModel()
    let session = AVCaptureSession()
    @Published var running = false
    @Published var denied = false
    private let q = DispatchQueue(label: "tatakan.mirror")
    private var configured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { ok ? self.run() : (self.denied = true) } }
        default: denied = true
        }
    }

    private func run() {
        q.async {
            if !self.configured {
                guard let cam = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: cam) else { return }
                self.session.beginConfiguration()
                self.session.sessionPreset = .medium
                if self.session.canAddInput(input) { self.session.addInput(input) }
                self.session.commitConfiguration()
                self.configured = true
            }
            self.session.startRunning()
            DispatchQueue.main.async { self.running = true }
        }
    }

    func stop() {
        q.async { self.session.stopRunning(); DispatchQueue.main.async { self.running = false } }
    }
}

struct MirrorPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let l = AVCaptureVideoPreviewLayer(session: session)
        l.videoGravity = .resizeAspectFill
        l.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1)) // mirror
        v.layer = l
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}
