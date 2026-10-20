import AppKit
import Security
import SwiftUI
import UniformTypeIdentifiers

/// Small JSON persistence helper for the notch tools.
enum Store {
    static func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let d = try? Data(contentsOf: Paths.support.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        if let d = try? JSONEncoder().encode(value) { try? d.write(to: Paths.support.appendingPathComponent(name), options: .atomic) }
    }
}

// MARK: - Shelf

@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()
    @Published var urls: [URL] = (UserDefaults.standard.stringArray(forKey: "shelf") ?? [])
        .map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) } {
        didSet { UserDefaults.standard.set(urls.map(\.path), forKey: "shelf") }
    }

    func add(_ providers: [NSItemProvider]) {
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in ShelfStore.shared.add(url) }
            }
        }
    }

    func add(_ url: URL) { if !urls.contains(url) { urls.insert(url, at: 0) } }
    func remove(_ url: URL) { urls.removeAll { $0 == url } }
}

// MARK: - Clipboard history

struct ClipEntry: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case text, link, image, file }
    var id = UUID()
    var kind: Kind
    var text: String
    var imageFile: String?
    var source: String
    var date: Date

    var detail: String {
        switch kind {
        case .text: "\(text.split { $0.isWhitespace || $0.isNewline }.count) words"
        case .link: URL(string: text)?.host ?? "Link"
        case .image: "Image"
        case .file: text.components(separatedBy: "\n").count == 1 ? "File" : "\(text.components(separatedBy: "\n").count) files"
        }
    }
}

@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()
    @Published private(set) var entries: [ClipEntry] = Store.load("clipboard.json", as: [ClipEntry].self) ?? []
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private let imageDir: URL = {
        let u = Paths.support.appendingPathComponent("clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    var enabled: Bool { NotchTool.clipboard.isEnabled }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardStore.shared.check() }
        }
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard enabled else { return }
        let types = pb.types ?? []
        // Respect password managers and apps that mark copies as private.
        if types.contains(where: { $0.rawValue.contains("Concealed") || $0.rawValue.contains("Transient") }) { return }
        let front = NSWorkspace.shared.frontmostApplication
        guard ClipboardPrivacy.shouldRecord(from: front) else { return }
        let source = front?.localizedName ?? "Unknown"

        var entry: ClipEntry?
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            entry = ClipEntry(kind: .file, text: files.map(\.path).joined(separator: "\n"), source: source, date: .now)
        } else if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let isLink = (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")) && !trimmed.contains(" ")
            entry = ClipEntry(kind: isLink ? .link : .text, text: String(s.prefix(50_000)), source: source, date: .now)
        } else if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let name = UUID().uuidString + ".png"
            try? png.write(to: imageDir.appendingPathComponent(name))
            entry = ClipEntry(kind: .image, text: "\(Int(img.size.width))×\(Int(img.size.height))", imageFile: name, source: source, date: .now)
        }
        guard let entry else { return }
        entries.removeAll { $0.kind == entry.kind && $0.text == entry.text && entry.kind != .image }
        entries.insert(entry, at: 0)
        if entries.count > 300 { entries.dropTail(entries.count - 300).forEach(cleanup) }
        persist()
    }

    func imageURL(_ e: ClipEntry) -> URL? { e.imageFile.map { imageDir.appendingPathComponent($0) } }

    func paste(_ e: ClipEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch e.kind {
        case .text, .link: pb.setString(e.text, forType: .string)
        case .file: pb.writeObjects(e.text.components(separatedBy: "\n").map { URL(fileURLWithPath: $0) as NSURL })
        case .image: if let u = imageURL(e), let img = NSImage(contentsOf: u) { pb.writeObjects([img]) }
        }
        lastChange = pb.changeCount
        Notch.shared.show(banner: "Copied", seconds: 1.5)
    }

    func delete(_ e: ClipEntry) { entries.removeAll { $0.id == e.id }; cleanup(e); persist() }
    func clear() { entries.forEach(cleanup); entries = []; persist() }
    private func cleanup(_ e: ClipEntry) { if let u = imageURL(e) { try? FileManager.default.removeItem(at: u) } }
    private func persist() { Store.save(entries, "clipboard.json") }
}

extension Array {
    mutating func dropTail(_ k: Int) -> [Element] {
        let tail = Array(suffix(k)); removeSubrange((count - k)...); return tail
    }
}

// MARK: - Notes

struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var updated: Date
    var title: String { text.split(separator: "\n").first.map(String.init) ?? "New note" }
}

@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()
    @Published var notes: [Note] = Store.load("notes.json", as: [Note].self) ?? [] {
        didSet { Store.save(notes, "notes.json") }
    }
}

// MARK: - Timers

@MainActor
final class TimerStore: ObservableObject {
    static let shared = TimerStore()

    enum Phase: String { case focus = "Focus", rest = "Break" }

    @Published var pomodoroEnd: Date?
    @Published var pomodoroPaused: TimeInterval?
    @Published var phase: Phase = .focus
    @Published var cycles = UserDefaults.standard.integer(forKey: "pomodoroCycles") {
        didSet { UserDefaults.standard.set(cycles, forKey: "pomodoroCycles") }
    }
    @Published var countdownEnd: Date?
    @Published var stopwatchStart: Date?
    @Published var stopwatchAccum: TimeInterval = 0
    @Published var laps: [TimeInterval] = []
    @Published var hydration = UserDefaults.standard.bool(forKey: "hydration") {
        didSet { UserDefaults.standard.set(hydration, forKey: "hydration"); nextSip = hydration ? .now + 1800 : nil }
    }
    @Published var nextSip: Date?
    @Published var now = Date()
    @AppStorage("focusMinutes") var focusMinutes = 25
    @AppStorage("breakMinutes") var breakMinutes = 5
    private var timer: Timer?

    init() {
        if hydration { nextSip = .now + 1800 }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { TimerStore.shared.tick() }
        }
    }

    private func tick() {
        now = .now
        if let end = pomodoroEnd, end <= now {
            NSSound(named: "Glass")?.play()
            if phase == .focus { cycles += 1; phase = .rest; pomodoroEnd = now + Double(breakMinutes * 60); Notch.shared.show(banner: "Break time") }
            else { phase = .focus; pomodoroEnd = nil; Notch.shared.show(banner: "Break over") }
        }
        if let end = countdownEnd, end <= now {
            countdownEnd = nil
            NSSound(named: "Glass")?.play()
            Notch.shared.show(banner: "Time's up")
        }
        if let sip = nextSip, sip <= now {
            nextSip = now + 1800
            NSSound(named: "Pop")?.play()
            Notch.shared.show(banner: "Drink some water 💧", seconds: 8)
        }
    }

    func startPomodoro() { phase = .focus; pomodoroPaused = nil; pomodoroEnd = .now + Double(focusMinutes * 60) }
    func pausePomodoro() {
        if let p = pomodoroPaused { pomodoroEnd = .now + p; pomodoroPaused = nil }
        else if let e = pomodoroEnd { pomodoroPaused = e.timeIntervalSinceNow; pomodoroEnd = nil }
    }
    func resetPomodoro() { pomodoroEnd = nil; pomodoroPaused = nil; phase = .focus }

    var pomodoroRemaining: TimeInterval {
        pomodoroPaused ?? pomodoroEnd.map { max(0, $0.timeIntervalSince(now)) } ?? Double(focusMinutes * 60)
    }

    func startCountdown(minutes: Int) { countdownEnd = .now + Double(minutes * 60) }

    var stopwatchElapsed: TimeInterval { stopwatchAccum + (stopwatchStart.map { now.timeIntervalSince($0) } ?? 0) }
    func toggleStopwatch() {
        if let s = stopwatchStart { stopwatchAccum += Date.now.timeIntervalSince(s); stopwatchStart = nil } else { stopwatchStart = .now }
    }
    func lap() { laps.insert(stopwatchElapsed, at: 0) }
    func resetStopwatch() { stopwatchStart = nil; stopwatchAccum = 0; laps = [] }

    /// What the collapsed notch shows while something is running.
    var liveText: String? {
        if let e = pomodoroEnd { return "\(phase.rawValue) " + Self.clock(e.timeIntervalSince(now)) }
        if let e = countdownEnd { return Self.clock(e.timeIntervalSince(now)) }
        if stopwatchStart != nil { return Self.clock(stopwatchElapsed) }
        return nil
    }
    var liveSymbol: String { pomodoroEnd != nil ? "brain.head.profile" : countdownEnd != nil ? "timer" : "stopwatch" }

    static func clock(_ t: TimeInterval, tenths: Bool = false) -> String {
        let s = max(0, Int(t))
        let base = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
        return tenths ? base + String(format: ".%d", Int((t - floor(t)) * 10)) : base
    }
}

// MARK: - Message

@MainActor
final class MessageStore: ObservableObject {
    static let shared = MessageStore()
    enum Animation: String, CaseIterable, Identifiable { case scroll, bounce, wave, sparkle, pulse, rainbow; var id: String { rawValue } }
    @AppStorage("message.text") var text = "Hello from the notch"
    @AppStorage("message.on") var onNotch = false
    @AppStorage("message.animation") var animation: Animation = .scroll
    @AppStorage("message.color") var colorHex = "33FF99"
    @AppStorage("message.speed") var speed = 40.0

    var color: Color {
        let v = UInt32(colorHex, radix: 16) ?? 0x33FF99
        return Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Screen Time

/// Records which app is in front, every few seconds, while you're active. Stays on this Mac.
@MainActor
final class ScreenTimeStore: ObservableObject {
    static let shared = ScreenTimeStore()
    /// day ("yyyy-MM-dd") → app name → seconds
    @Published private(set) var days: [String: [String: Double]] = Store.load("screentime.json", as: [String: [String: Double]].self) ?? [:]
    private var timer: Timer?
    private var ticks = 0
    static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { ScreenTimeStore.shared.sample() }
        }
    }

    private func sample() {
        guard NotchTool.screenTime.isEnabled else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 120, let app = NSWorkspace.shared.frontmostApplication?.localizedName else { return }
        let key = Self.fmt.string(from: .now)
        days[key, default: [:]][app, default: 0] += 5
        ticks += 1
        if ticks % 12 == 0 { Store.save(days, "screentime.json") }
    }

    func usage(daysAgo: Int) -> [String: Double] {
        let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
        return days[Self.fmt.string(from: d)] ?? [:]
    }
}

// MARK: - Keychain

enum Keychain {
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "GFind",
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "GFind",
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Revenue (Stripe)

/// Today's Stripe takings, read with a restricted read-only key kept in the login keychain.
@MainActor
final class RevenueStore: ObservableObject {
    static let shared = RevenueStore()

    struct Txn: Identifiable, Hashable { let id: String; let amount: Int; let currency: String; let date: Date; let description: String }

    @Published private(set) var transactions: [Txn] = []
    @Published private(set) var error: String?
    @Published private(set) var lastUpdate: Date?
    @Published var hasKey = Keychain.get("stripe") != nil
    private var seen = Set<String>()
    private var timer: Timer?

    var todayTotal: Int { transactions.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.amount } }
    var currency: String { transactions.first?.currency ?? "usd" }
    var todayText: String { Self.money(todayTotal, currency) }
    var todayShort: String {
        let v = Double(todayTotal) / 100
        return v >= 1000 ? String(format: "%@%.1fk", Self.symbol(currency), v / 1000) : Self.money(todayTotal, currency)
    }

    static func symbol(_ c: String) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = c.uppercased()
        return f.currencySymbol
    }

    static func money(_ cents: Int, _ currency: String) -> String {
        (Double(cents) / 100).formatted(.currency(code: currency.uppercased()))
    }

    func setKey(_ key: String) {
        Keychain.set("stripe", key.trimmingCharacters(in: .whitespacesAndNewlines))
        hasKey = Keychain.get("stripe") != nil
        seen = []; transactions = []
        Task { await refresh() }
    }

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await RevenueStore.shared.refresh() }
        }
    }

    func refresh() async {
        guard NotchTool.revenue.isEnabled, let key = Keychain.get("stripe") else { return }
        let since = Int(Calendar.current.startOfDay(for: .now).addingTimeInterval(-6 * 86_400).timeIntervalSince1970)
        var req = URLRequest(url: URL(string: "https://api.stripe.com/v1/balance_transactions?limit=100&created[gte]=\(since)")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if (resp as? HTTPURLResponse)?.statusCode != 200 {
                error = ((json["error"] as? [String: Any])?["message"] as? String) ?? "Stripe returned an error"
                return
            }
            let list = (json["data"] as? [[String: Any]] ?? []).compactMap { t -> Txn? in
                guard let id = t["id"] as? String, let amount = t["amount"] as? Int, let created = t["created"] as? Double,
                      let type = t["type"] as? String, ["charge", "payment"].contains(type) else { return nil }
                return Txn(id: id, amount: amount, currency: t["currency"] as? String ?? "usd",
                           date: Date(timeIntervalSince1970: created), description: t["description"] as? String ?? "Payment")
            }
            let fresh = list.filter { !seen.contains($0.id) && Calendar.current.isDateInToday($0.date) }
            if !seen.isEmpty { for t in fresh { Notch.shared.show(banner: "+" + Self.money(t.amount, t.currency)) } }
            seen.formUnion(list.map(\.id))
            transactions = list
            error = nil
            lastUpdate = .now
        } catch {
            self.error = error.localizedDescription
        }
    }
}
