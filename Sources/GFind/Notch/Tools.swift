import AppKit
import Charts
import EventKit
import SwiftUI

private let dim = Color.white.opacity(0.55)

// MARK: Home

struct HomeTool: View {
    @ObservedObject var cal = CalendarStore.shared
    @ObservedObject var player = Player.shared
    @ObservedObject var lib = Library.shared
    @AppStorage("notchTheme") private var theme: NotchTheme = .playful

    var body: some View {
        HStack(spacing: 10) {
            Tile(tint: theme.color(0)) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ctx.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 38, weight: .bold, design: .rounded))
                        Text(ctx.date.formatted(.dateTime.weekday(.wide).day().month(.wide))).foregroundStyle(dim)
                        Spacer()
                        if let e = cal.nextEvent {
                            Label(e.title, systemImage: "calendar").lineLimit(1)
                            Text(e.startDate.formatted(date: .omitted, time: .shortened) + " · " + Format.relative(e.startDate))
                                .font(.caption).foregroundStyle(dim)
                        } else if !cal.eventsAllowed {
                            Button("Show your next event") { Task { await cal.connect() } }.buttonStyle(.link)
                        } else { Text("Nothing else today").foregroundStyle(dim) }
                    }
                }
            }
            VStack(spacing: 10) {
                Tile(tint: theme.color(1)) {
                    if let song = player.current {
                        HStack {
                            Image(systemName: "music.note").font(.title2)
                            Text(song.url.deletingPathExtension().lastPathComponent).lineLimit(2)
                            Spacer()
                            Button { player.skip(-1) } label: { Image(systemName: "backward.fill") }
                            Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                            Button { player.skip(1) } label: { Image(systemName: "forward.fill") }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Label("Nothing playing. Double-click a song in GFind.", systemImage: "music.note").foregroundStyle(dim)
                    }
                }
                Tile(tint: theme.color(2)) {
                    HStack(spacing: 8) {
                        launch("magnifyingglass", "Search") { QuickSearch.shared.show() }
                        launch("macwindow", "GFind") { AppState.shared.showMain() }
                        launch("arrow.down.circle", "Downloads") { NSWorkspace.shared.open(Paths.downloads) }
                        launch("camera.viewfinder", "Screenshot") {
                            Notch.shared.close()
                            Process.launchedProcess(launchPath: "/usr/sbin/screencapture", arguments: ["-i", "-c"])
                        }
                        launch("sparkles", "Clean Up") { AppState.shared.showMain(); AppState.shared.go(.cleanUp) }
                    }
                }
            }
        }
        .task { await cal.refresh() }
    }

    private func launch(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) { Image(systemName: symbol).font(.title3); Text(title).font(.caption2) }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Revenue

struct RevenueTool: View {
    @ObservedObject var rev = RevenueStore.shared
    @State private var key = ""
    @AppStorage("notchTheme") private var theme: NotchTheme = .playful

    var body: some View {
        if !rev.hasKey {
            VStack(alignment: .leading, spacing: 10) {
                Text("Connect Stripe").font(.title3.weight(.semibold))
                Text("Create a restricted key in Stripe with read access to Balance transactions only. It can read what you've earned and nothing else. It's stored in your login keychain and only sent to Stripe.")
                    .font(.callout).foregroundStyle(dim)
                HStack {
                    SecureField("rk_live_…", text: $key).textFieldStyle(.roundedBorder)
                    Button("Connect") { rev.setKey(key); key = "" }.disabled(key.isEmpty)
                }
                Link("Open Stripe API keys", destination: URL(string: "https://dashboard.stripe.com/apikeys")!).font(.callout)
            }
            .padding(8)
        } else {
            HStack(spacing: 10) {
                Tile(tint: theme.color(4)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Today").foregroundStyle(dim)
                        Text(rev.todayText).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("\(rev.transactions.filter { Calendar.current.isDateInToday($0.date) }.count) payments").foregroundStyle(dim)
                        Spacer()
                        if let e = rev.error { Text(e).font(.caption).foregroundStyle(.red) }
                        else if let u = rev.lastUpdate { Text("Updated \(Format.relative(u))").font(.caption).foregroundStyle(dim) }
                        HStack {
                            Button("Refresh") { Task { await rev.refresh() } }
                            Button("Disconnect") { rev.setKey("") }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
                .frame(width: 230)
                Tile {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(rev.transactions) { t in
                                HStack {
                                    Text(t.description).lineLimit(1)
                                    Spacer()
                                    Text(RevenueStore.money(t.amount, t.currency)).monospacedDigit()
                                    Text(Format.relative(t.date)).font(.caption).foregroundStyle(dim).frame(width: 80, alignment: .trailing)
                                }
                            }
                            if rev.transactions.isEmpty { Text("No payments in the last 7 days.").foregroundStyle(dim) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: Scratchpad & Notes

struct ScratchpadTool: View {
    @AppStorage("scratchpad") private var text = ""
    @AppStorage("liveActivity") private var live: LiveActivity = .clock
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.07)))
            HStack {
                Toggle("Pin first line to the notch", isOn: Binding(get: { live == .scratchpad }, set: { live = $0 ? .scratchpad : .clock }))
                    .toggleStyle(.checkbox)
                Spacer()
                Text("\(text.split { $0.isWhitespace || $0.isNewline }.count) words").foregroundStyle(dim)
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                Button("Clear") { text = "" }
            }
            .font(.caption).buttonStyle(.link)
        }
    }
}

struct NotesTool: View {
    @ObservedObject var store = NotesStore.shared
    @State private var selected: UUID?

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 4) {
                Button { let n = Note(text: "", updated: .now); store.notes.insert(n, at: 0); selected = n.id } label: {
                    Label("New note", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).padding(6)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.notes) { n in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(n.title.isEmpty ? "New note" : n.title).lineLimit(1)
                                Text(Format.relative(n.updated)).font(.caption2).foregroundStyle(dim)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(selected == n.id ? .white.opacity(0.14) : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { selected = n.id }
                            .contextMenu { Button("Delete") { store.notes.removeAll { $0.id == n.id } } }
                        }
                    }
                }
            }
            .frame(width: 190)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))

            if let i = store.notes.firstIndex(where: { $0.id == selected }) {
                TextEditor(text: Binding(get: { store.notes[i].text },
                                         set: { store.notes[i].text = $0; store.notes[i].updated = .now }))
                    .font(.system(size: 14)).scrollContentBackground(.hidden).padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.07)))
            } else {
                Text(store.notes.isEmpty ? "No notes yet." : "Pick a note.").foregroundStyle(dim).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selected = selected ?? store.notes.first?.id }
    }
}

// MARK: Shelf

struct ShelfTool: View {
    @ObservedObject var shelf = ShelfStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if shelf.urls.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 34))
                    Text("Drag files onto the notch to park them here.")
                    Text("Drag them back out into any app when you need them.").font(.caption).foregroundStyle(dim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(dim))
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(shelf.urls, id: \.self) { u in ShelfItem(url: u) }
                    }
                    .padding(4)
                }
                HStack {
                    Text("\(shelf.urls.count) items").foregroundStyle(dim)
                    Spacer()
                    Button("Show All in Finder") { NSWorkspace.shared.activateFileViewerSelecting(shelf.urls) }
                    Button("Clear Shelf") { shelf.urls = [] }
                }
                .font(.caption).buttonStyle(.link)
            }
        }
    }
}

private struct ShelfItem: View {
    let url: URL
    @State private var hover = false
    var body: some View {
        let item = Scanner.makeItem(url, nil, includeUncategorized: true)
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                if let item { Thumbnail(item: item, size: 96).frame(width: 96, height: 86) }
                if hover {
                    Button { ShelfStore.shared.remove(url) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                }
            }
            Text(url.lastPathComponent).font(.caption).lineLimit(2).multilineTextAlignment(.center).frame(width: 100)
        }
        .onHover { hover = $0 }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Remove from Shelf") { ShelfStore.shared.remove(url) }
        }
    }
}

// MARK: Calendar

struct CalendarTool: View {
    @ObservedObject var cal = CalendarStore.shared
    @State private var newReminder = ""

    var body: some View {
        if !cal.eventsAllowed && !cal.remindersAllowed {
            VStack(spacing: 10) {
                Image(systemName: "calendar").font(.largeTitle)
                Text("See the next seven days and your reminders.")
                Button("Connect Calendar & Reminders") { Task { await cal.connect() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 10) {
                Tile {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            let byDay = Dictionary(grouping: cal.events) { Calendar.current.startOfDay(for: $0.startDate) }
                            ForEach(byDay.keys.sorted(), id: \.self) { day in
                                Text(day.formatted(.dateTime.weekday(.wide).day().month())).font(.caption.weight(.semibold)).foregroundStyle(dim)
                                ForEach(byDay[day] ?? [], id: \.eventIdentifier) { e in
                                    HStack(spacing: 8) {
                                        RoundedRectangle(cornerRadius: 2).fill(Color(cgColor: e.calendar.cgColor)).frame(width: 3)
                                        Text(e.isAllDay ? "All day" : e.startDate.formatted(date: .omitted, time: .shortened))
                                            .font(.caption).foregroundStyle(dim).frame(width: 64, alignment: .leading)
                                        Text(e.title ?? "").lineLimit(1)
                                    }
                                }
                            }
                            if cal.events.isEmpty { Text("Nothing in the next seven days.").foregroundStyle(dim) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Tile {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Reminders").font(.caption.weight(.semibold)).foregroundStyle(dim)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(cal.reminders, id: \.calendarItemIdentifier) { r in
                                    HStack {
                                        Button { cal.complete(r) } label: { Image(systemName: "circle") }.buttonStyle(.plain)
                                        Text(r.title ?? "").lineLimit(1)
                                        Spacer()
                                        if let d = r.dueDateComponents?.date { Text(Format.relative(d)).font(.caption).foregroundStyle(dim) }
                                    }
                                }
                            }
                        }
                        NotchField(placeholder: "Add a reminder", text: $newReminder) {
                            cal.addReminder(newReminder); newReminder = ""
                        }
                    }
                }
                .frame(width: 260)
            }
            .task { await cal.refresh() }
        }
    }
}

// MARK: Timers

struct TimersTool: View {
    @ObservedObject var t = TimerStore.shared
    @AppStorage("notchTheme") private var theme: NotchTheme = .playful

    var body: some View {
        HStack(spacing: 8) {
            Tile(tint: theme.color(0)) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Pomodoro · \(t.phase.rawValue)", systemImage: "brain.head.profile").font(.caption).foregroundStyle(dim)
                    Text(TimerStore.clock(t.pomodoroRemaining)).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("\(t.cycles) cycles done").font(.caption).foregroundStyle(dim)
                    Spacer()
                    HStack {
                        if t.pomodoroEnd == nil && t.pomodoroPaused == nil { Button("Start") { t.startPomodoro() } }
                        else { Button(t.pomodoroPaused != nil ? "Resume" : "Pause") { t.pausePomodoro() }; Button("Reset") { t.resetPomodoro() } }
                    }
                    Text("\(t.focusMinutes)/\(t.breakMinutes) min").font(.caption2).foregroundStyle(dim)
                }
            }
            Tile(tint: theme.color(1)) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Countdown", systemImage: "timer").font(.caption).foregroundStyle(dim)
                    Text(t.countdownEnd.map { TimerStore.clock($0.timeIntervalSince(t.now)) } ?? "0:00")
                        .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach([5, 10, 25], id: \.self) { m in Button("\(m)m") { t.startCountdown(minutes: m) } }
                    }
                    if t.countdownEnd != nil { Button("Cancel") { t.countdownEnd = nil } }
                }
            }
            Tile(tint: theme.color(2)) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Stopwatch", systemImage: "stopwatch").font(.caption).foregroundStyle(dim)
                    Text(TimerStore.clock(t.stopwatchElapsed, tenths: true)).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(Array(t.laps.enumerated()), id: \.offset) { i, l in
                                Text("Lap \(t.laps.count - i)  \(TimerStore.clock(l, tenths: true))").font(.caption2).foregroundStyle(dim)
                            }
                        }
                    }
                    HStack {
                        Button(t.stopwatchStart == nil ? "Start" : "Stop") { t.toggleStopwatch() }
                        Button(t.stopwatchStart == nil ? "Reset" : "Lap") { t.stopwatchStart == nil ? t.resetStopwatch() : t.lap() }
                    }
                }
            }
            Tile(tint: theme.color(3)) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Hydration", systemImage: "drop").font(.caption).foregroundStyle(dim)
                    Image(systemName: t.hydration ? "drop.fill" : "drop").font(.system(size: 30))
                    Text(t.nextSip.map { "Next sip " + Format.relative($0) } ?? "A nudge every 30 minutes").font(.caption).foregroundStyle(dim)
                    Spacer()
                    Toggle("On", isOn: $t.hydration).toggleStyle(.switch).controlSize(.mini)
                }
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
    }
}

// MARK: Stats

struct StatsTool: View {
    @ObservedObject var s = StatsStore.shared
    @AppStorage("notchTheme") private var theme: NotchTheme = .playful

    var body: some View {
        HStack(spacing: 10) {
            ring("CPU", s.cpu, "\(Int(s.cpu * 100))%", 0)
            ring("Memory", s.memoryUsed / s.memoryTotal, Format.size(Int64(s.memoryUsed)), 1)
            ring("Disk", s.diskUsed / s.diskTotal, "\(Format.size(Int64(s.diskTotal - s.diskUsed))) free", 2)
            Tile {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Network", systemImage: "network").font(.caption).foregroundStyle(dim)
                    Label(Format.size(Int64(s.netIn)) + "/s", systemImage: "arrow.down").monospacedDigit()
                    Label(Format.size(Int64(s.netOut)) + "/s", systemImage: "arrow.up").monospacedDigit()
                    Divider()
                    if let b = s.battery {
                        Label("\(b.percent)%\(b.charging ? " · charging" : "")", systemImage: b.charging ? "battery.100.bolt" : "battery.75")
                        if let h = b.health { Text("Health \(h)%\(b.cycles.map { " · \($0) cycles" } ?? "")").font(.caption).foregroundStyle(dim) }
                    } else { Label("No battery", systemImage: "powerplug").foregroundStyle(dim) }
                }
            }
        }
        .onAppear { s.begin() }
        .onDisappear { s.end() }
    }

    private func ring(_ title: String, _ value: Double, _ label: String, _ i: Int) -> some View {
        Tile(tint: theme.color(i)) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(.white.opacity(0.1), lineWidth: 9)
                    Circle().trim(from: 0, to: max(0.01, min(1, value)))
                        .stroke(theme.color(i), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: theme == .neon ? theme.color(i) : .clear, radius: 4)
                        .animation(.easeOut, value: value)
                    Text("\(Int(value * 100))%").font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .frame(width: 84, height: 84)
                Text(title).font(.callout.weight(.semibold))
                Text(label).font(.caption).foregroundStyle(dim).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Screen Time

struct ScreenTimeTool: View {
    @ObservedObject var st = ScreenTimeStore.shared
    @AppStorage("notchTheme") private var theme: NotchTheme = .playful

    var body: some View {
        let today = st.usage(daysAgo: 0)
        let total = today.values.reduce(0, +)
        let week = (0..<7).reversed().map { d -> (String, Double) in
            let day = Calendar.current.date(byAdding: .day, value: -d, to: .now)!
            return (day.formatted(.dateTime.weekday(.narrow)) + "\(d)", st.usage(daysAgo: d).values.reduce(0, +) / 3600)
        }
        HStack(spacing: 10) {
            Tile(tint: theme.color(0)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today").foregroundStyle(dim)
                    Text(duration(total)).font(.system(size: 30, weight: .bold, design: .rounded))
                    if let top = today.max(by: { $0.value < $1.value }) {
                        Text("Most used: \(top.key)").font(.caption).foregroundStyle(dim)
                    }
                    Chart(week, id: \.0) { d in
                        BarMark(x: .value("Day", d.0), y: .value("Hours", d.1)).foregroundStyle(theme.color(0)).cornerRadius(3)
                    }
                    .chartXAxis { AxisMarks { v in AxisValueLabel { Text((v.as(String.self) ?? "").prefix(1)) } } }
                    .chartYAxis(.hidden)
                }
            }
            Tile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(today.sorted { $0.value > $1.value }.prefix(12).enumerated()), id: \.element.key) { i, e in
                            HStack {
                                Text(e.key).lineLimit(1)
                                Spacer()
                                Text(duration(e.value)).monospacedDigit().foregroundStyle(dim)
                            }
                            GeometryReader { g in
                                Capsule().fill(theme.color(i)).frame(width: g.size.width * e.value / max(total, 1))
                            }
                            .frame(height: 4)
                        }
                        if today.isEmpty { Text("Tracking starts now. Counts the app in front while you're active, on this Mac only.").foregroundStyle(dim) }
                    }
                }
            }
        }
    }

    private func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}

// MARK: Weather

struct WeatherTool: View {
    @ObservedObject var w = WeatherStore.shared
    @State private var city = WeatherStore.shared.city

    var body: some View {
        if w.city.isEmpty || w.current == nil && w.error != nil {
            VStack(spacing: 10) {
                Image(systemName: "cloud.sun").font(.largeTitle)
                Text("Which city?")
                NotchField(placeholder: "e.g. Mumbai", text: $city) { w.city = city; Task { await w.refresh() } }.frame(width: 260)
                if let e = w.error { Text(e).font(.caption).foregroundStyle(.red) }
                Text("Forecasts from Open-Meteo.").font(.caption2).foregroundStyle(dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let c = w.current {
            HStack(spacing: 10) {
                Tile {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(w.place ?? w.city).lineLimit(1)
                            Spacer()
                            Button { w.city = "" } label: { Image(systemName: "pencil") }.buttonStyle(.plain).foregroundStyle(dim)
                        }
                        HStack(alignment: .top) {
                            Image(systemName: WeatherStore.symbol(c.code)).symbolRenderingMode(.multicolor).font(.system(size: 34))
                            Text("\(Int(c.temp.rounded()))°").font(.system(size: 40, weight: .bold, design: .rounded))
                        }
                        Text("Feels \(Int(c.feels.rounded()))° · \(Int(c.humidity))% humidity").font(.caption).foregroundStyle(dim)
                        Text("Wind \(Int(c.wind)) km/h · Rain \(String(format: "%.1f", c.rain)) mm").font(.caption).foregroundStyle(dim)
                        Spacer()
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(w.hours) { h in
                                    VStack(spacing: 2) {
                                        Text(h.id.formatted(.dateTime.hour())).font(.caption2).foregroundStyle(dim)
                                        Image(systemName: WeatherStore.symbol(h.code)).symbolRenderingMode(.multicolor)
                                        Text("\(Int(h.temp.rounded()))°").font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }
                Tile {
                    let lo = w.days.map(\.min).min() ?? 0, hi = w.days.map(\.max).max() ?? 1
                    VStack(spacing: 5) {
                        ForEach(w.days) { d in
                            HStack(spacing: 6) {
                                Text(Calendar.current.isDateInToday(d.id) ? "Today" : d.id.formatted(.dateTime.weekday(.abbreviated)))
                                    .frame(width: 44, alignment: .leading)
                                Image(systemName: WeatherStore.symbol(d.code)).symbolRenderingMode(.multicolor).frame(width: 22)
                                Text("\(Int(d.min.rounded()))°").foregroundStyle(dim).frame(width: 30)
                                GeometryReader { g in
                                    let span = max(hi - lo, 1)
                                    Capsule().fill(LinearGradient(colors: [.cyan, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: g.size.width * (d.max - d.min) / span, height: 5)
                                        .offset(x: g.size.width * (d.min - lo) / span, y: g.size.height / 2 - 2.5)
                                }
                                Text("\(Int(d.max.rounded()))°").frame(width: 30)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).task { await w.refreshIfStale() }
        }
    }
}

// MARK: Clipboard

struct ClipboardTool: View {
    @ObservedObject var clips = ClipboardStore.shared
    @State private var query = ""

    var body: some View {
        let list = clips.entries.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.source.localizedCaseInsensitiveContains(query) }
        VStack(spacing: 6) {
            HStack {
                NotchField(placeholder: "Search \(clips.entries.count) copies", text: $query)
                Button("Clear") { clips.clear() }.buttonStyle(.link).font(.caption)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(list) { e in
                        HStack(spacing: 10) {
                            Group {
                                if e.kind == .image, let u = clips.imageURL(e), let img = NSImage(contentsOf: u) {
                                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Image(systemName: e.kind == .link ? "link" : e.kind == .file ? "doc" : "text.alignleft")
                                }
                            }
                            .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 6))
                            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.07)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.kind == .file ? e.text.components(separatedBy: "\n").map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") : e.text)
                                    .lineLimit(2)
                                Text("\(e.source) · \(e.detail) · \(Format.relative(e.date))").font(.caption2).foregroundStyle(dim)
                            }
                            Spacer()
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.04)))
                        .contentShape(Rectangle())
                        .onTapGesture { clips.paste(e) }
                        .contextMenu { Button("Copy") { clips.paste(e) }; Button("Delete") { clips.delete(e) } }
                    }
                    if list.isEmpty { Text(clips.entries.isEmpty ? "Copy something and it'll show up here." : "No matches.").foregroundStyle(dim).padding() }
                }
            }
        }
    }
}

// MARK: Files (convert & shrink)

struct FilesTool: View {
    @ObservedObject var shelf = ShelfStore.shared
    @State private var source: URL?
    @State private var format: ImageConverter.Format = .jpeg
    @State private var quality = 0.8
    @State private var maxSize = 0
    @State private var result: String?
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 6) {
                if let source, let item = Scanner.makeItem(source, nil, includeUncategorized: true) {
                    Thumbnail(item: item, size: 140).frame(height: 130)
                    Text(source.lastPathComponent).font(.caption).lineLimit(1)
                    Text(Format.size(item.size)).font(.caption2).foregroundStyle(dim)
                } else {
                    Image(systemName: "photo.badge.arrow.down").font(.system(size: 34))
                    Text("Drop an image here").font(.callout)
                    if let img = shelf.urls.first(where: { ["png", "jpg", "jpeg", "heic", "tiff", "webp", "gif"].contains($0.pathExtension.lowercased()) }) {
                        Button("Use \(img.lastPathComponent) from the Shelf") { source = img }.buttonStyle(.link).font(.caption)
                    }
                }
            }
            .frame(width: 220).frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(targeted ? .white : dim))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                _ = providers.first?.loadObject(ofClass: URL.self) { u, _ in DispatchQueue.main.async { source = u; result = nil } }
                return true
            }

            Tile {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Format", selection: $format) { ForEach(ImageConverter.Format.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                    if format == .jpeg || format == .heic {
                        HStack { Text("Quality"); Slider(value: $quality, in: 0.1...1); Text("\(Int(quality * 100))%").monospacedDigit().frame(width: 40) }
                    }
                    Picker("Max size", selection: $maxSize) {
                        Text("Original").tag(0); Text("4096 px").tag(4096); Text("2048 px").tag(2048)
                        Text("1280 px").tag(1280); Text("800 px").tag(800)
                    }
                    HStack {
                        Button("Convert") { convert() }.buttonStyle(.borderedProminent).disabled(source == nil)
                        if source != nil { Button("Clear") { source = nil; result = nil } }
                    }
                    if let result { Text(result).font(.caption).foregroundStyle(dim) }
                    Spacer()
                    Text("Happens on your Mac. Nothing is uploaded. The result is saved next to the original and put on the Shelf.")
                        .font(.caption2).foregroundStyle(dim)
                }
            }
        }
    }

    private func convert() {
        guard let source else { return }
        do {
            let before = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let out = try ImageConverter.convert(source, to: format, quality: quality, maxPixels: maxSize == 0 ? nil : maxSize)
            let after = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            shelf.add(out)
            result = "\(out.lastPathComponent): \(Format.size(Int64(before))) → \(Format.size(Int64(after)))"
        } catch { result = error.localizedDescription }
    }
}

// MARK: Links

struct LinksTool: View {
    struct SavedLink: Codable, Hashable { var title: String; var url: String }
    static let engines: [(String, String)] = [
        ("Google", "https://www.google.com/search?q="), ("DuckDuckGo", "https://duckduckgo.com/?q="),
        ("Perplexity", "https://www.perplexity.ai/search?q="), ("YouTube", "https://www.youtube.com/results?search_query="),
        ("GitHub", "https://github.com/search?q="),
    ]
    @AppStorage("links.engine") private var engine = "Google"
    @State private var query = ""
    @State private var links: [SavedLink] = Store.load("links.json", as: [SavedLink].self) ?? [
        SavedLink(title: "GitHub", url: "https://github.com"), SavedLink(title: "Gmail", url: "https://mail.google.com"),
        SavedLink(title: "Claude", url: "https://claude.ai"), SavedLink(title: "X", url: "https://x.com"),
    ]
    @State private var newURL = ""

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("", selection: $engine) { ForEach(Self.engines, id: \.0) { Text($0.0).tag($0.0) } }.frame(width: 130)
                NotchField(placeholder: "Search \(engine)", text: $query) { search() }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(links, id: \.self) { l in
                    Button { if let u = URL(string: l.url) { NSWorkspace.shared.open(u) } } label: {
                        HStack {
                            Image(systemName: "globe")
                            Text(l.title).lineLimit(1)
                            Spacer()
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Remove") { links.removeAll { $0 == l }; Store.save(links, "links.json") } }
                }
            }
            Spacer()
            NotchField(placeholder: "Add a site (https://…)", text: $newURL) {
                var s = newURL.trimmingCharacters(in: .whitespaces)
                if !s.contains("://") { s = "https://" + s }
                if let u = URL(string: s), let host = u.host {
                    links.append(SavedLink(title: host.replacingOccurrences(of: "www.", with: ""), url: s))
                    Store.save(links, "links.json")
                }
                newURL = ""
            }
        }
    }

    private func search() {
        guard let base = Self.engines.first(where: { $0.0 == engine })?.1,
              let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let u = URL(string: base + q) else { return }
        NSWorkspace.shared.open(u)
        query = ""
    }
}

// MARK: Emoji

struct EmojiTool: View {
    @State private var query = ""
    @State private var group = "Smileys"
    @AppStorage("emoji.recent") private var recent = ""

    var body: some View {
        let items = query.isEmpty ? EmojiCatalog.all.filter { $0.group == group }
            : EmojiCatalog.all.filter { $0.name.contains(query.lowercased()) }
        VStack(spacing: 6) {
            HStack {
                NotchField(placeholder: "Search emoji", text: $query)
                ForEach(EmojiCatalog.groups, id: \.0) { g in
                    Button { group = g.0; query = "" } label: { Image(systemName: g.1).foregroundStyle(group == g.0 && query.isEmpty ? .white : dim) }
                        .buttonStyle(.plain).help(g.0)
                }
            }
            if !recent.isEmpty && query.isEmpty {
                HStack(spacing: 2) {
                    ForEach(recent.map(String.init), id: \.self) { e in cell(e, name: "recent") }
                    Spacer()
                }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 2)], spacing: 2) {
                    ForEach(items) { e in cell(e.id, name: e.name) }
                }
            }
        }
    }

    private func cell(_ e: String, name: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(e, forType: .string)
            recent = String((e + recent.replacingOccurrences(of: e, with: "")).prefix(16))
            Notch.shared.show(banner: "Copied \(e)", seconds: 1.2)
        } label: { Text(e).font(.system(size: 24)).frame(width: 34, height: 34) }
        .buttonStyle(.plain)
        .help(name.capitalized)
    }
}

// MARK: Sounds

struct SoundsTool: View {
    @ObservedObject var engine = SoundEngine.shared
    @AppStorage("notchTheme") private var theme: NotchTheme = .playful

    var body: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Array(SoundEngine.Ambience.allCases.enumerated()), id: \.element) { i, a in
                    let on = engine.active.contains(a)
                    Button { engine.toggle(a) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: a.symbol).font(.title2)
                            Text(a.title).font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 74)
                        .foregroundStyle(on ? .black : .white)
                        .background(RoundedRectangle(cornerRadius: 12).fill(on ? theme.color(i) : .white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: $engine.volume, in: 0...1).frame(width: 160)
                Spacer()
                Menu(engine.fadeOutAt.map { "Fades " + Format.relative($0) } ?? "Fade out") {
                    ForEach([15, 30, 60, 90], id: \.self) { m in Button("After \(m) minutes") { engine.fadeOut(after: m) } }
                    Button("Never") { engine.fadeOut(after: nil) }
                }
                .frame(width: 150)
                Button("Stop all") { engine.stopAll() }.disabled(engine.active.isEmpty)
            }
            .font(.caption)
        }
    }
}

// MARK: Message

struct MessageTool: View {
    @ObservedObject var m = MessageStore.shared
    @AppStorage("liveActivity") private var live: LiveActivity = .clock
    static let swatches = ["33FF99", "FF3DBB", "33D9FF", "FFD60A", "B266FF", "FF7A33", "FFFFFF"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DotMatrixMessage(width: 640).frame(height: 34).background(RoundedRectangle(cornerRadius: 8).fill(.black))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.1)))
            NotchField(placeholder: "Your message", text: $m.text)
            HStack {
                Picker("Animation", selection: $m.animation) { ForEach(MessageStore.Animation.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                    .frame(width: 200)
                ForEach(Self.swatches, id: \.self) { s in
                    Circle().fill(MessageStore.color(hex: s)).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.white, lineWidth: m.colorHex == s ? 2 : 0))
                        .onTapGesture { m.colorHex = s }
                }
            }
            HStack {
                Text("Speed"); Slider(value: $m.speed, in: 10...120).frame(width: 160)
                Spacer()
                Toggle("Show on the notch", isOn: Binding(get: { m.onNotch && live == .message },
                                                          set: { m.onNotch = $0; live = $0 ? .message : .clock; Notch.shared.layout() }))
                    .toggleStyle(.switch)
                Button("Flash") { Notch.shared.flash() }
            }
        }
    }
}

extension MessageStore {
    static func color(hex: String) -> Color {
        let v = UInt32(hex, radix: 16) ?? 0xFFFFFF
        return Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// The message drawn as lit dots, with a few animations.
struct DotMatrixMessage: View {
    let width: CGFloat
    @ObservedObject var m = MessageStore.shared

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let chars = Array(m.text.uppercased())
            let charW: CGFloat = 9
            let textW = CGFloat(chars.count) * charW
            let offset = m.animation == .scroll || m.animation == .rainbow || m.animation == .wave
                ? width - CGFloat((t * m.speed).truncatingRemainder(dividingBy: Double(width + textW)))
                : (width - textW) / 2
            HStack(spacing: 0) {
                ForEach(Array(chars.enumerated()), id: \.offset) { i, c in
                    Text(String(c))
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .frame(width: charW)
                        .foregroundStyle(color(i, t))
                        .offset(y: dy(i, t))
                        .opacity(alpha(i, t))
                }
            }
            .fixedSize()
            .offset(x: offset)
            .frame(width: width, alignment: .leading)
            .mask(DotGrid())
            .shadow(color: m.color.opacity(0.8), radius: 3)
            .clipped()
        }
    }

    private func color(_ i: Int, _ t: Double) -> Color {
        m.animation == .rainbow ? Color(hue: (Double(i) * 0.06 + t * 0.3).truncatingRemainder(dividingBy: 1), saturation: 0.9, brightness: 1) : m.color
    }
    private func dy(_ i: Int, _ t: Double) -> CGFloat {
        switch m.animation {
        case .bounce: CGFloat(-abs(sin(t * 4)) * 4)
        case .wave: CGFloat(sin(t * 6 + Double(i) * 0.6) * 3)
        default: 0
        }
    }
    private func alpha(_ i: Int, _ t: Double) -> Double {
        switch m.animation {
        case .pulse: 0.45 + 0.55 * abs(sin(t * 3))
        case .sparkle: sin(t * 9 + Double(i * 7 % 13)) > -0.2 ? 1 : 0.25
        default: 1
        }
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 2
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width { ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(.white)); x += step }
                y += step
            }
        }
    }
}

// MARK: Claude

struct ClaudeTool: View {
    @ObservedObject var store = ClaudeStore.shared
    let orange = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        Group {
            if let u = store.usage {
                HStack(spacing: 10) {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            stat("Tokens today", compact(u.tokensToday))
                            stat("Streak", "\(u.streak) day\(u.streak == 1 ? "" : "s")")
                        }
                        HStack(spacing: 8) {
                            stat("Messages", "\(u.messagesToday)")
                            stat("Tool calls", "\(u.toolCallsToday)")
                            stat("Sessions", "\(u.sessionsToday)")
                        }
                    }
                    Tile(tint: orange) {
                        VStack(alignment: .leading, spacing: 6) {
                            if let p = u.project { Label(p, systemImage: "folder").lineLimit(1) }
                            Heatmap(perDay: u.perDay, color: orange)
                            ForEach(u.perProject.prefix(3), id: \.0) { p in
                                HStack { Text(p.0).lineLimit(1); Spacer(); Text(compact(p.1)).foregroundStyle(dim) }.font(.caption)
                            }
                        }
                    }
                    .frame(width: 290)
                }
            } else if store.loading {
                ProgressView("Reading Claude Code logs…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "sparkle").font(.largeTitle).foregroundStyle(orange)
                    Text("No Claude Code activity found in ~/.claude/projects.")
                    Button("Check again") { store.refresh() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { store.refreshIfStale() }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        Tile(tint: orange) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(dim)
                Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            }
        }
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000_000_000 ? String(format: "%.1fB", Double(n) / 1e9)
            : n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6)
            : n >= 1_000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
    }
}

private struct Heatmap: View {
    let perDay: [Date: Int]
    let color: Color
    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let weeks = 17
        let maxV = Double(perDay.values.max() ?? 1)
        HStack(spacing: 3) {
            ForEach(0..<weeks, id: \.self) { w in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { d in
                        let offset = (weeks - 1 - w) * 7 + (6 - d)
                        let day = cal.date(byAdding: .day, value: -offset, to: today)!
                        let v = Double(perDay[day] ?? 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(v == 0 ? Color.white.opacity(0.08) : color.opacity(0.3 + 0.7 * sqrt(v / maxV)))
                            .frame(width: 11, height: 11)
                    }
                }
            }
        }
    }
}

// MARK: Units

struct UnitsTool: View {
    enum Kind: String, CaseIterable, Identifiable {
        case length, mass, temperature, volume, speed, data, time, area
        var id: String { rawValue }
        var units: [(String, Dimension)] {
            switch self {
            case .length: [("km", UnitLength.kilometers), ("m", UnitLength.meters), ("cm", UnitLength.centimeters), ("mm", UnitLength.millimeters),
                           ("mi", UnitLength.miles), ("yd", UnitLength.yards), ("ft", UnitLength.feet), ("in", UnitLength.inches)]
            case .mass: [("kg", UnitMass.kilograms), ("g", UnitMass.grams), ("lb", UnitMass.pounds), ("oz", UnitMass.ounces), ("st", UnitMass.stones)]
            case .temperature: [("°C", UnitTemperature.celsius), ("°F", UnitTemperature.fahrenheit), ("K", UnitTemperature.kelvin)]
            case .volume: [("L", UnitVolume.liters), ("mL", UnitVolume.milliliters), ("gal", UnitVolume.gallons), ("cup", UnitVolume.cups),
                           ("fl oz", UnitVolume.fluidOunces), ("tbsp", UnitVolume.tablespoons), ("tsp", UnitVolume.teaspoons)]
            case .speed: [("km/h", UnitSpeed.kilometersPerHour), ("mph", UnitSpeed.milesPerHour), ("m/s", UnitSpeed.metersPerSecond), ("kn", UnitSpeed.knots)]
            case .data: [("GB", UnitInformationStorage.gigabytes), ("MB", UnitInformationStorage.megabytes), ("KB", UnitInformationStorage.kilobytes),
                         ("TB", UnitInformationStorage.terabytes), ("GiB", UnitInformationStorage.gibibytes), ("MiB", UnitInformationStorage.mebibytes),
                         ("bit", UnitInformationStorage.bits), ("byte", UnitInformationStorage.bytes)]
            case .time: [("h", UnitDuration.hours), ("min", UnitDuration.minutes), ("s", UnitDuration.seconds), ("ms", UnitDuration.milliseconds)]
            case .area: [("m²", UnitArea.squareMeters), ("km²", UnitArea.squareKilometers), ("ft²", UnitArea.squareFeet),
                         ("acre", UnitArea.acres), ("ha", UnitArea.hectares)]
            }
        }
    }

    @State private var kind: Kind = .length
    @State private var value = "1"
    @State private var from = 0
    @State private var to = 4

    var body: some View {
        let units = kind.units
        let v = Double(value.replacingOccurrences(of: ",", with: ".")) ?? 0
        let f = units[min(from, units.count - 1)], t = units[min(to, units.count - 1)]
        let result = Measurement(value: v, unit: f.1).converted(to: t.1).value
        VStack(spacing: 12) {
            Picker("", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                .pickerStyle(.segmented)
                .onChange(of: kind) { from = 0; to = min(1, kind.units.count - 1) }
            HStack(spacing: 10) {
                NotchField(placeholder: "Value", text: $value).frame(width: 140).font(.title3)
                Picker("", selection: $from) { ForEach(units.indices, id: \.self) { Text(units[$0].0).tag($0) } }.frame(width: 90)
                Button { swap(&from, &to) } label: { Image(systemName: "arrow.left.arrow.right") }.buttonStyle(.plain)
                Picker("", selection: $to) { ForEach(units.indices, id: \.self) { Text(units[$0].0).tag($0) } }.frame(width: 90)
            }
            Text("\(v.formatted()) \(f.0) = \(result.formatted(.number.precision(.significantDigits(1...8)))) \(t.0)")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.top, 6)
    }
}
