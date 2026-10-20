import AppKit
import AVFoundation
import Darwin
import EventKit
import ImageIO
import IOKit.ps
import SwiftUI
import UniformTypeIdentifiers

// MARK: - System stats

@MainActor
final class StatsStore: ObservableObject {
    static let shared = StatsStore()

    @Published private(set) var cpu: Double = 0
    @Published private(set) var memoryUsed: Double = 0
    @Published private(set) var memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published private(set) var diskUsed: Double = 0
    @Published private(set) var diskTotal: Double = 1
    @Published private(set) var netIn: Double = 0
    @Published private(set) var netOut: Double = 0
    @Published private(set) var battery: (percent: Int, charging: Bool, health: Int?, cycles: Int?)?

    private var lastCPU: (busy: UInt64, total: UInt64)?
    private var lastNet: (inB: UInt64, outB: UInt64, at: Date)?
    private var timer: Timer?
    private var users = 0

    func begin() {
        users += 1
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in MainActor.assumeIsolated { StatsStore.shared.sample() } }
    }

    func end() {
        users -= 1
        if users <= 0 { timer?.invalidate(); timer = nil; users = 0 }
    }

    private func sample() {
        // CPU
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if kr == KERN_SUCCESS {
            let t = info.cpu_ticks
            let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3), total = busy + UInt64(t.2)
            if let l = lastCPU, total > l.total { cpu = Double(busy - l.busy) / Double(total - l.total) }
            lastCPU = (busy, total)
        }

        // Memory (app + wired + compressed, like Activity Monitor's "Memory Used")
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) }
        }
        if vr == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
            memoryUsed = (app + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
        }

        // Disk
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
           let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage {
            diskTotal = Double(total); diskUsed = Double(total) - Double(free)
        }

        // Network
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0, let first = ifap {
            var inB: UInt64 = 0, outB: UInt64 = 0
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let cur = p {
                let name = String(cString: cur.pointee.ifa_name)
                if cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), !name.hasPrefix("lo"),
                   let data = cur.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    inB += UInt64(data.pointee.ifi_ibytes); outB += UInt64(data.pointee.ifi_obytes)
                }
                p = cur.pointee.ifa_next
            }
            freeifaddrs(ifap)
            let now = Date()
            if let l = lastNet, inB >= l.inB, outB >= l.outB {
                let dt = now.timeIntervalSince(l.at)
                netIn = Double(inB - l.inB) / dt; netOut = Double(outB - l.outB) / dt
            }
            lastNet = (inB, outB, now)
        }

        // Battery
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
           let src = list.first,
           let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
           let cap = d[kIOPSCurrentCapacityKey] as? Int {
            var health: Int?, cycles: Int?
            let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if svc != 0 {
                func prop(_ k: String) -> Int? { IORegistryEntryCreateCFProperty(svc, k as CFString, nil, 0)?.takeRetainedValue() as? Int }
                if let maxCap = prop("AppleRawMaxCapacity") ?? prop("NominalChargeCapacity"), let design = prop("DesignCapacity"), design > 0 {
                    health = min(100, maxCap * 100 / design)
                }
                cycles = prop("CycleCount")
                IOObjectRelease(svc)
            }
            battery = (cap, (d[kIOPSIsChargingKey] as? Bool) ?? false, health, cycles)
        }
    }
}

// MARK: - Ambient sounds (synthesised on device, no audio files)

final class SoundEngine: ObservableObject {
    static let shared = SoundEngine()

    enum Ambience: String, CaseIterable, Identifiable {
        case rain, waves, wind, fire, brown, pink, white, hum
        var id: String { rawValue }
        var title: String {
            switch self {
            case .brown: "Brown noise"
            case .pink: "Pink noise"
            case .white: "White noise"
            case .hum: "Deep hum"
            default: rawValue.capitalized
            }
        }
        var symbol: String {
            switch self {
            case .rain: "cloud.rain"
            case .waves: "water.waves"
            case .wind: "wind"
            case .fire: "flame"
            case .brown: "circle.hexagongrid"
            case .pink: "circle.grid.cross"
            case .white: "circle.dotted"
            case .hum: "waveform.path"
            }
        }
    }

    @Published private(set) var active: Set<Ambience> = []
    @Published var volume: Float = 0.6 { didSet { engine.mainMixerNode.outputVolume = volume } }
    @Published var fadeOutAt: Date?

    private let engine = AVAudioEngine()
    private var gains: [Ambience: Float] = [:]       // current
    private var targets: [Ambience: Float] = [:]     // where each is fading to
    private let lock = NSLock()
    private var fadeTimer: Timer?

    private init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, brown: Float = 0, wind: Float = 0, hum: Double = 0
        var t: Double = 0, crackle: Float = 0, drop: Float = 0
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frames, abl -> OSStatus in
            let buf = UnsafeMutableAudioBufferListPointer(abl)[0]
            let out = buf.mData!.assumingMemoryBound(to: Float.self)
            self.lock.lock()
            var g = self.gains
            let tg = self.targets
            self.lock.unlock()
            for i in 0..<Int(frames) {
                let w = Float.random(in: -1...1)
                b0 = 0.99765 * b0 + w * 0.0990460; b1 = 0.96300 * b1 + w * 0.2965164; b2 = 0.57000 * b2 + w * 1.0526913
                let pink = (b0 + b1 + b2 + w * 0.1848) * 0.12
                brown = (brown + 0.02 * w) / 1.02
                let br = brown * 3.2
                t += 1 / 44_100
                var s: Float = 0
                for (a, cur) in g {
                    let target = tg[a] ?? 0
                    let next = cur + (target - cur) * 0.00008
                    g[a] = next
                    guard next > 0.0005 else { continue }
                    var v: Float
                    switch a {
                    case .white: v = w * 0.25
                    case .pink: v = pink
                    case .brown: v = br
                    case .rain:
                        if Float.random(in: 0...1) < 0.0009 { drop = Float.random(in: 0.2...0.6) }
                        drop *= 0.992
                        v = pink * 0.7 + w * drop * 0.5
                    case .waves:
                        let swell = Float(0.55 + 0.45 * sin(2 * .pi * t / 9))
                        v = br * swell * 1.1
                    case .wind:
                        wind = wind * 0.995 + w * 0.005
                        let gust = Float(0.5 + 0.5 * sin(2 * .pi * t / 13) * sin(2 * .pi * t / 5.3))
                        v = wind * 9 * gust
                    case .fire:
                        if Float.random(in: 0...1) < 0.0015 { crackle = Float.random(in: 0.3...1) }
                        crackle *= 0.96
                        v = br * 0.6 + w * crackle * 0.6
                    case .hum:
                        hum += 2 * .pi * 55 / 44_100
                        v = Float(sin(hum) * 0.18 + sin(hum * 1.5) * 0.06) + pink * 0.15
                    }
                    s += v * next
                }
                out[i] = max(-1, min(1, s))
            }
            self.lock.lock()
            for (a, v) in g where self.gains[a] != nil { self.gains[a] = v }
            self.lock.unlock()
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
    }

    func toggle(_ a: Ambience) {
        lock.lock()
        if active.contains(a) { targets[a] = 0 } else { targets[a] = 1; if gains[a] == nil { gains[a] = 0 } }
        lock.unlock()
        if active.contains(a) { active.remove(a) } else { active.insert(a) }
        if !active.isEmpty && !engine.isRunning { try? engine.start() }
    }

    func stopAll() {
        lock.lock(); for k in targets.keys { targets[k] = 0 }; lock.unlock()
        active = []
        fadeOutAt = nil
    }

    func fadeOut(after minutes: Int?) {
        fadeTimer?.invalidate()
        guard let minutes else { fadeOutAt = nil; return }
        fadeOutAt = .now + Double(minutes * 60)
        fadeTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes * 60), repeats: false) { [weak self] _ in self?.stopAll() }
    }
}

// MARK: - Weather (Open-Meteo, no key needed)

@MainActor
final class WeatherStore: ObservableObject {
    static let shared = WeatherStore()

    struct Current { let temp, feels, humidity, wind, rain: Double; let code: Int }
    struct Hour: Identifiable { let id: Date; let temp: Double; let code: Int }
    struct Day: Identifiable { let id: Date; let min, max: Double; let code: Int }

    @AppStorage("weather.city") var city = ""
    @Published private(set) var place: String?
    @Published private(set) var current: Current?
    @Published private(set) var hours: [Hour] = []
    @Published private(set) var days: [Day] = []
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var fetched: Date?

    func refreshIfStale() async {
        if let f = fetched, Date.now.timeIntervalSince(f) < 900 { return }
        await refresh()
    }

    func refresh() async {
        let name = city.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        loading = true; defer { loading = false }
        do {
            var g = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            g.queryItems = [.init(name: "name", value: name), .init(name: "count", value: "1")]
            let (gd, _) = try await URLSession.shared.data(from: g.url!)
            guard let gj = try JSONSerialization.jsonObject(with: gd) as? [String: Any],
                  let r = (gj["results"] as? [[String: Any]])?.first,
                  let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else { error = "Couldn't find “\(name)”"; return }
            place = [r["name"] as? String, r["country"] as? String].compactMap { $0 }.joined(separator: ", ")

            var f = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            f.queryItems = [
                .init(name: "latitude", value: "\(lat)"), .init(name: "longitude", value: "\(lon)"),
                .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,precipitation,weather_code"),
                .init(name: "hourly", value: "temperature_2m,weather_code"),
                .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code"),
                .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "7"),
            ]
            let (fd, _) = try await URLSession.shared.data(from: f.url!)
            guard let j = try JSONSerialization.jsonObject(with: fd) as? [String: Any] else { return }
            if let c = j["current"] as? [String: Any] {
                current = Current(temp: c["temperature_2m"] as? Double ?? 0, feels: c["apparent_temperature"] as? Double ?? 0,
                                  humidity: c["relative_humidity_2m"] as? Double ?? 0, wind: c["wind_speed_10m"] as? Double ?? 0,
                                  rain: c["precipitation"] as? Double ?? 0, code: c["weather_code"] as? Int ?? 0)
            }
            let iso = DateFormatter(); iso.dateFormat = "yyyy-MM-dd'T'HH:mm"
            let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
            if let h = j["hourly"] as? [String: Any], let times = h["time"] as? [String], let temps = h["temperature_2m"] as? [Double],
               let codes = h["weather_code"] as? [Int] {
                hours = zip(times.indices, times).compactMap { i, t in iso.date(from: t).map { Hour(id: $0, temp: temps[i], code: codes[i]) } }
                    .filter { $0.id > .now.addingTimeInterval(-3600) }.prefix(12).map { $0 }
            }
            if let d = j["daily"] as? [String: Any], let times = d["time"] as? [String], let mx = d["temperature_2m_max"] as? [Double],
               let mn = d["temperature_2m_min"] as? [Double], let codes = d["weather_code"] as? [Int] {
                days = times.indices.compactMap { i in day.date(from: times[i]).map { Day(id: $0, min: mn[i], max: mx[i], code: codes[i]) } }
            }
            error = nil
            fetched = .now
        } catch { self.error = error.localizedDescription }
    }

    static func symbol(_ code: Int) -> String {
        switch code {
        case 0: "sun.max.fill"
        case 1, 2: "cloud.sun.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
}

// MARK: - Calendar & reminders

@MainActor
final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()
    let store = EKEventStore()
    @Published private(set) var events: [EKEvent] = []
    @Published private(set) var reminders: [EKReminder] = []
    @Published private(set) var eventsAllowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published private(set) var remindersAllowed = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess

    func connect() async {
        eventsAllowed = (try? await store.requestFullAccessToEvents()) ?? false
        remindersAllowed = (try? await store.requestFullAccessToReminders()) ?? false
        await refresh()
    }

    func refresh() async {
        if eventsAllowed {
            let start = Calendar.current.startOfDay(for: .now)
            let pred = store.predicateForEvents(withStart: .now.addingTimeInterval(-3600), end: start.addingTimeInterval(7 * 86_400), calendars: nil)
            events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
        }
        if remindersAllowed {
            let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            let items: [EKReminder] = await withCheckedContinuation { c in
                store.fetchReminders(matching: pred) { c.resume(returning: $0 ?? []) }
            }
            reminders = items.sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
        }
    }

    var nextEvent: EKEvent? { events.first { $0.endDate > .now && !$0.isAllDay } }

    func complete(_ r: EKReminder) {
        r.isCompleted = true
        try? store.save(r, commit: true)
        reminders.removeAll { $0 == r }
    }

    func addReminder(_ title: String) {
        guard remindersAllowed, let cal = store.defaultCalendarForNewReminders() else { return }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = cal
        try? store.save(r, commit: true)
        Task { await refresh() }
    }
}

// MARK: - Claude Code usage (read from ~/.claude/projects, never uploaded)

struct ClaudeUsage {
    var tokensToday = 0
    var messagesToday = 0
    var toolCallsToday = 0
    var sessionsToday = 0
    var project: String?
    var streak = 0
    var perDay: [Date: Int] = [:]   // tokens per day
    var perProject: [(String, Int)] = []
}

@MainActor
final class ClaudeStore: ObservableObject {
    static let shared = ClaudeStore()
    @Published private(set) var usage: ClaudeUsage?
    @Published private(set) var loading = false
    @Published private(set) var missing = false
    private var loaded: Date?

    func refreshIfStale() {
        if let l = loaded, Date.now.timeIntervalSince(l) < 120 { return }
        refresh()
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            let result = await Task.detached(priority: .utility) { Self.compute() }.value
            usage = result
            missing = result == nil
            loading = false
            loaded = .now
        }
    }

    nonisolated static func compute() -> ClaudeUsage? {
        let root = Paths.home.appendingPathComponent(".claude/projects")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let horizon = today.addingTimeInterval(-120 * 86_400)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var u = ClaudeUsage()
        var sessions = Set<String>(), lastSeen: Date = .distantPast
        var projects: [String: Int] = [:]
        for case let f as URL in en where f.pathExtension == "jsonl" {
            guard let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > horizon,
                  let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard line.contains("\"timestamp\""),
                      let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let ts = (obj["timestamp"] as? String).flatMap(iso.date) else { continue }
                let type = obj["type"] as? String
                guard type == "assistant" || type == "user" else { continue }
                let day = cal.startOfDay(for: ts)
                var tokens = 0
                let msg = obj["message"] as? [String: Any]
                if let usage = msg?["usage"] as? [String: Any] {
                    for k in ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
                        tokens += usage[k] as? Int ?? 0
                    }
                }
                u.perDay[day, default: 0] += max(tokens, 1)
                let cwd = obj["cwd"] as? String
                if day == today {
                    u.tokensToday += tokens
                    u.messagesToday += 1
                    if let s = obj["sessionId"] as? String { sessions.insert(s) }
                    if let content = msg?["content"] as? [[String: Any]] {
                        u.toolCallsToday += content.filter { $0["type"] as? String == "tool_use" }.count
                    }
                    if let cwd { projects[(cwd as NSString).lastPathComponent, default: 0] += tokens }
                }
                if ts > lastSeen, let cwd { lastSeen = ts; u.project = (cwd as NSString).lastPathComponent }
            }
        }
        guard !u.perDay.isEmpty else { return nil }
        u.sessionsToday = sessions.count
        u.perProject = projects.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        var d = u.perDay[today] != nil ? today : today.addingTimeInterval(-86_400)
        while u.perDay[d] != nil { u.streak += 1; d = cal.date(byAdding: .day, value: -1, to: d)! }
        return u
    }
}

// MARK: - Emoji (built from Unicode data, names from the system)

struct EmojiItem: Identifiable, Hashable { let id: String; let name: String; let group: String }

enum EmojiCatalog {
    static let groups: [(String, String, [ClosedRange<UInt32>])] = [
        ("Smileys", "face.smiling", [0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97F, 0x1F9D0...0x1F9DF]),
        ("People", "hand.wave", [0x1F440...0x1F4AF, 0x1F930...0x1F94F, 0x1F9B0...0x1F9CF, 0x1FAE0...0x1FAFF]),
        ("Nature", "leaf", [0x1F300...0x1F33F, 0x1F400...0x1F43F, 0x1F980...0x1F9AF, 0x1FAB0...0x1FABF]),
        ("Food", "fork.knife", [0x1F340...0x1F37F, 0x1F950...0x1F96F, 0x1FAD0...0x1FADF]),
        ("Activities", "sportscourt", [0x1F380...0x1F3FF, 0x1F93A...0x1F94F, 0x1FA70...0x1FAAF]),
        ("Travel", "airplane", [0x1F680...0x1F6FF, 0x1F5FA...0x1F5FF]),
        ("Objects", "lightbulb", [0x1F4B0...0x1F5F9, 0x1F9E0...0x1F9FF, 0x231A...0x23FF]),
        ("Symbols", "heart", [0x2600...0x27BF, 0x1F7E0...0x1F7EB, 0x2B00...0x2BFF]),
    ]

    static let all: [EmojiItem] = {
        var seen = Set<String>(), out: [EmojiItem] = []
        for (group, _, ranges) in groups {
            for r in ranges {
                for v in r {
                    guard let s = Unicode.Scalar(v), s.properties.isEmojiPresentation, let name = s.properties.name else { continue }
                    let ch = String(s)
                    if seen.insert(ch).inserted { out.append(EmojiItem(id: ch, name: name.lowercased(), group: group)) }
                }
            }
        }
        return out
    }()
}

// MARK: - Image conversion

enum ImageConverter {
    enum Format: String, CaseIterable, Identifiable {
        case jpeg = "JPEG", png = "PNG", heic = "HEIC", pdf = "PDF"
        var id: String { rawValue }
        var ext: String { self == .jpeg ? "jpg" : rawValue.lowercased() }
        var type: UTType { switch self { case .jpeg: .jpeg; case .png: .png; case .heic: .heic; case .pdf: .pdf } }
    }

    /// Converts an image on this Mac and returns the new file next to the original.
    static func convert(_ url: URL, to format: Format, quality: Double, maxPixels: Int?) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw err("Not an image") }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 4000, h = props?[kCGImagePropertyPixelHeight] as? Int ?? 4000
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels ?? max(w, h),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw err("Couldn't read the image") }

        var out = url.deletingPathExtension().appendingPathExtension(format.ext)
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(n).\(format.ext)")
            n += 1
        }

        if format == .pdf {
            var box = CGRect(x: 0, y: 0, width: img.width, height: img.height)
            guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw err("Couldn't create the PDF") }
            ctx.beginPDFPage(nil); ctx.draw(img, in: box); ctx.endPDFPage(); ctx.closePDF()
        } else {
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, format.type.identifier as CFString, 1, nil) else {
                throw err("This Mac can't write \(format.rawValue)")
            }
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw err("Couldn't save the file") }
        }
        return out
    }

    private static func err(_ s: String) -> NSError { NSError(domain: "GFind", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}
