import AppKit
import SwiftUI

enum NotchTool: String, CaseIterable, Identifiable {
    case home, revenue, scratchpad, shelf, calendar, timers, stats, screenTime, weather, clipboard
    case notes, files, links, emoji, sounds, message, claude, units

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenTime: "Screen Time"
        case .claude: "Claude"
        default: rawValue.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .revenue: "dollarsign.circle"
        case .scratchpad: "square.and.pencil"
        case .shelf: "tray.full"
        case .calendar: "calendar"
        case .timers: "timer"
        case .stats: "cpu"
        case .screenTime: "hourglass"
        case .weather: "cloud.sun"
        case .clipboard: "doc.on.clipboard"
        case .notes: "note.text"
        case .files: "photo.badge.arrow.down"
        case .links: "link"
        case .emoji: "face.smiling"
        case .sounds: "waveform"
        case .message: "text.bubble"
        case .claude: "sparkle"
        case .units: "ruler"
        }
    }

    var isEnabled: Bool { UserDefaults.standard.object(forKey: "tool.\(rawValue)") as? Bool ?? true }
}

enum NotchTheme: String, CaseIterable, Identifiable {
    case minimal, playful, neon
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    static let pastel: [Color] = [
        Color(red: 1, green: 0.55, blue: 0.62), Color(red: 0.62, green: 0.55, blue: 1), Color(red: 1, green: 0.72, blue: 0.35),
        Color(red: 0.4, green: 0.72, blue: 1), Color(red: 0.45, green: 0.85, blue: 0.6), Color(red: 0.95, green: 0.82, blue: 0.35),
    ]
    static let neonColors: [Color] = [
        Color(red: 0.2, green: 1, blue: 0.6), Color(red: 1, green: 0.2, blue: 0.75), Color(red: 0.2, green: 0.85, blue: 1),
        Color(red: 1, green: 0.85, blue: 0.1), Color(red: 0.7, green: 0.4, blue: 1), Color(red: 1, green: 0.45, blue: 0.2),
    ]

    func color(_ i: Int) -> Color {
        switch self {
        case .minimal: .white
        case .playful: Self.pastel[abs(i) % Self.pastel.count]
        case .neon: Self.neonColors[abs(i) % Self.neonColors.count]
        }
    }

    var accent: Color { color(0) }
    var glow: CGFloat { self == .neon ? 6 : 0 }
}

enum LiveActivity: String, CaseIterable, Identifiable {
    case none, clock, revenue, scratchpad, message
    var id: String { rawValue }
    var title: String { self == .none ? "Nothing" : rawValue.capitalized }
}

/// The black panel that lives in (or simulates) the MacBook notch.
@MainActor
final class Notch: NSObject, ObservableObject {
    static let shared = Notch()

    @Published var expanded = false
    @Published var tool: NotchTool = NotchTool(rawValue: UserDefaults.standard.string(forKey: "notchTool") ?? "") ?? .home {
        didSet { UserDefaults.standard.set(tool.rawValue, forKey: "notchTool") }
    }
    @Published var pinned = false
    @Published var banner: String?
    @Published var flashing = false
    @Published private(set) var notchSize = CGSize(width: 190, height: 32)
    @Published private(set) var hasRealNotch = false

    let expandedSize = CGSize(width: 700, height: 340)
    private var panel: Panel?
    private var poll: Timer?
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var hiddenForFullscreen = false

    final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private var defaults: UserDefaults { .standard }
    var enabled: Bool { defaults.object(forKey: "notchEnabled") as? Bool ?? true }
    private var hoverDelay: Double { defaults.object(forKey: "notchHoverDelay") as? Double ?? 0.15 }
    private var hoverToOpen: Bool { defaults.object(forKey: "notchHoverOpen") as? Bool ?? true }
    private var hideInFullscreen: Bool { defaults.object(forKey: "notchHideFullscreen") as? Bool ?? true }

    /// Extra width on each side of the notch when something is shown on the collapsed bar.
    var wing: CGFloat {
        if banner != nil || TimerStore.shared.liveText != nil { return 90 }
        switch LiveActivity(rawValue: defaults.string(forKey: "liveActivity") ?? "") ?? .clock {
        case .none: return 0
        case .message: return MessageStore.shared.onNotch ? 150 : 0
        case .scratchpad: return 130
        default: return 80
        }
    }

    var collapsedSize: CGSize { CGSize(width: notchSize.width + wing * 2, height: notchSize.height) }

    // MARK: Lifecycle

    func start() {
        guard enabled else { stop(); return }
        if panel == nil {
            let p = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar + 1
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.isMovable = false
            p.hidesOnDeactivate = false
            let host = NSHostingView(rootView: NotchRoot().environmentObject(self))
            host.sizingOptions = []   // the controller sizes the window; don't let SwiftUI fight it
            p.contentView = host
            panel = p
            let nc = NotificationCenter.default, wc = NSWorkspace.shared.notificationCenter
            nc.addObserver(self, selector: #selector(layoutChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            wc.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            wc.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        }
        layout()
        panel?.orderFrontRegardless()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            MainActor.assumeIsolated { Notch.shared.tick() }
        }
        // Developer aid: `GFIND_DEV=1 GFind -openNotch <tool>` opens the panel on launch, pinned.
        if ProcessInfo.processInfo.environment["GFIND_DEV"] == "1", let i = CommandLine.arguments.firstIndex(of: "-openNotch") {
            if i + 1 < CommandLine.arguments.count, let t = NotchTool(rawValue: CommandLine.arguments[i + 1]) { tool = t }
            pinned = true
            open()
        }
        ClipboardStore.shared.start()
        ScreenTimeStore.shared.start()
        RevenueStore.shared.start()
    }

    func stop() {
        poll?.invalidate(); poll = nil
        panel?.orderOut(nil)
    }

    @objc private func layoutChanged() { layout() }

    @objc private func spaceChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.enabled else { return }
            self.hiddenForFullscreen = self.hideInFullscreen && self.fullscreenAppOnScreen()
            if self.hiddenForFullscreen { self.panel?.orderOut(nil) } else { self.panel?.orderFrontRegardless() }
        }
    }

    var screen: NSScreen? {
        let choice = defaults.string(forKey: "notchDisplay") ?? "auto"
        if choice != "auto", let s = NSScreen.screens.first(where: { $0.localizedName == choice }) { return s }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    static var displayNames: [String] { NSScreen.screens.map(\.localizedName) }

    func layout() {
        guard let screen else { return }
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            notchSize = CGSize(width: screen.frame.width - l.width - r.width, height: screen.safeAreaInsets.top)
            hasRealNotch = true
        } else {
            // No notch: draw one the height of the menu bar.
            notchSize = CGSize(width: 190, height: max(24, screen.frame.maxY - screen.visibleFrame.maxY))
            hasRealNotch = false
        }
        setFrame(expanded ? expandedSize : collapsedSize)
    }

    private func setFrame(_ size: CGSize) {
        guard let screen, let panel else { return }
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    /// The part of the screen the visible black shape covers.
    private var hotRect: NSRect {
        guard let screen else { return .zero }
        let s = expanded ? expandedSize : collapsedSize
        let f = screen.frame
        return NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height - (expanded ? 8 : 0), width: s.width, height: s.height + 8)
    }

    // MARK: Hover

    private func tick() {
        guard !hiddenForFullscreen else { return }
        if !expanded, let p = panel, abs(p.frame.width - collapsedSize.width) > 0.5 { setFrame(collapsedSize) }
        let inside = hotRect.contains(NSEvent.mouseLocation)
        if inside {
            closeTask?.cancel(); closeTask = nil
            let dragging = NSEvent.pressedMouseButtons & 1 == 1
            if !expanded && openTask == nil && (hoverToOpen || dragging) {
                openTask = Task {
                    try? await Task.sleep(for: .seconds(dragging ? 0.05 : hoverDelay))
                    if !Task.isCancelled { if dragging { tool = .shelf }; open() }
                    openTask = nil
                }
            }
        } else {
            openTask?.cancel(); openTask = nil
            let editing = panel?.isKeyWindow == true && panel?.firstResponder is NSTextView
            if expanded && !pinned && !editing && closeTask == nil {
                closeTask = Task {
                    try? await Task.sleep(for: .seconds(0.35))
                    if !Task.isCancelled { close() }
                    closeTask = nil
                }
            }
        }
    }

    func open() {
        guard !expanded else { return }
        setFrame(expandedSize)
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { expanded = true }
    }

    func close() {
        guard expanded else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { expanded = false }
        panel?.resignKey()
        Task {
            try? await Task.sleep(for: .seconds(0.32))
            if !expanded { setFrame(collapsedSize) }
        }
    }

    func toggle() { expanded ? close() : open() }

    /// Briefly shows a message on the collapsed notch (a sale, a timer finishing).
    func show(banner text: String, seconds: Double = 5) {
        withAnimation(.spring) { banner = text }
        setFrame(expanded ? expandedSize : collapsedSize)
        flash()
        bannerTask?.cancel()
        bannerTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { withAnimation(.spring) { banner = nil } }
        }
    }

    func flash() {
        Task {
            for _ in 0..<3 {
                withAnimation(.easeInOut(duration: 0.15)) { flashing = true }
                try? await Task.sleep(for: .seconds(0.18))
                withAnimation(.easeInOut(duration: 0.15)) { flashing = false }
                try? await Task.sleep(for: .seconds(0.18))
            }
        }
    }

    private func fullscreenAppOnScreen() -> Bool {
        guard let screen,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let size = screen.frame.size
        let me = ProcessInfo.processInfo.processIdentifier
        return list.contains { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return abs((b["Width"] ?? 0) - size.width) < 1 && abs((b["Height"] ?? 0) - size.height) < 1
        }
    }
}

/// Notch outline: flat top, rounded bottom corners, with the small outward flare real notches have.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topFlare: CGFloat = 6

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let br = min(bottomRadius, r.height / 2, r.width / 4)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + topFlare, y: r.minY + topFlare), control: CGPoint(x: r.minX + topFlare, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + topFlare, y: r.maxY - br))
        p.addQuadCurve(to: CGPoint(x: r.minX + topFlare + br, y: r.maxY), control: CGPoint(x: r.minX + topFlare, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - topFlare - br, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - topFlare, y: r.maxY - br), control: CGPoint(x: r.maxX - topFlare, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - topFlare, y: r.minY + topFlare))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - topFlare, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchRoot: View {
    @EnvironmentObject var notch: Notch
    @ObservedObject var timers = TimerStore.shared
    @ObservedObject var message = MessageStore.shared
    @AppStorage("notchTheme") private var theme: NotchTheme = .playful

    var body: some View {
        let size = notch.expanded ? notch.expandedSize : notch.collapsedSize
        ZStack(alignment: .top) {
            NotchShape(bottomRadius: notch.expanded ? 28 : 10)
                .fill(Color.black)
                .overlay(NotchShape(bottomRadius: notch.expanded ? 28 : 10)
                    .stroke(theme == .neon ? theme.accent.opacity(notch.flashing ? 1 : 0.35) : .white.opacity(notch.flashing ? 0.9 : 0),
                            lineWidth: notch.flashing ? 2 : 1))
                .shadow(color: theme == .neon ? theme.accent.opacity(0.4) : .clear, radius: theme.glow)
                .frame(width: size.width, height: size.height)

            if notch.expanded {
                NotchExpanded()
                    .frame(width: notch.expandedSize.width - 30, height: notch.expandedSize.height - 12)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else {
                NotchCollapsed()
                    .frame(width: size.width - 16, height: size.height)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            ShelfStore.shared.add(providers)
            notch.tool = .shelf
            notch.open()
            return true
        }
    }
}

/// What sits on the bar when it's closed: a timer, a banner, the clock, a message.
struct NotchCollapsed: View {
    @EnvironmentObject var notch: Notch
    @ObservedObject var timers = TimerStore.shared
    @ObservedObject var revenue = RevenueStore.shared
    @ObservedObject var message = MessageStore.shared
    @AppStorage("liveActivity") private var live: LiveActivity = .clock
    @AppStorage("scratchpad") private var scratch = ""
    @AppStorage("notchTheme") private var theme: NotchTheme = .playful

    var body: some View {
        let gap = notch.notchSize.width
        Group {
            if let b = notch.banner {
                split(Image(systemName: "bell.fill"), Text(b), gap: gap)
            } else if let t = timers.liveText {
                split(Image(systemName: timers.liveSymbol), Text(t).monospacedDigit(), gap: gap)
            } else {
                switch live {
                case .none: Color.clear
                case .clock:
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        split(Text(ctx.date.formatted(.dateTime.weekday(.abbreviated))),
                              Text(ctx.date.formatted(date: .omitted, time: .shortened)), gap: gap)
                    }
                case .revenue: split(Image(systemName: "dollarsign.circle.fill"), Text(revenue.todayShort), gap: gap)
                case .scratchpad:
                    split(Image(systemName: "square.and.pencil"),
                          Text(scratch.split(separator: "\n").first.map(String.init) ?? "Empty").lineLimit(1), gap: gap)
                case .message:
                    if message.onNotch { DotMatrixMessage(width: notch.collapsedSize.width - 16) } else { Color.clear }
                }
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(theme.accent)
        .shadow(color: theme == .neon ? theme.accent : .clear, radius: theme.glow / 2)
    }

    private func split<L: View, R: View>(_ l: L, _ r: R, gap: CGFloat) -> some View {
        HStack(spacing: 0) {
            l.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
            Spacer().frame(width: notch.hasRealNotch ? gap : 8)
            r.frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 6)
        }
    }
}

struct NotchExpanded: View {
    @EnvironmentObject var notch: Notch
    @AppStorage("notchTheme") private var theme: NotchTheme = .playful
    @State private var enabledTools = NotchTool.allCases.filter(\.isEnabled)

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(notch.tool.title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button { notch.pinned.toggle() } label: {
                    Image(systemName: notch.pinned ? "pin.fill" : "pin")
                }
                .help(notch.pinned ? "Unpin (closes when you move away)" : "Keep open")
                Button { AppState.shared.showMain() } label: { Image(systemName: "macwindow") }.help("Open GFind")
                SettingsLink { Image(systemName: "gearshape") }.help("Settings")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 10)
            .frame(height: max(notch.notchSize.height - 6, 20))

            ToolContent(tool: notch.tool)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(enabledTools.enumerated()), id: \.element) { i, t in
                        Button { notch.tool = t } label: {
                            Image(systemName: t.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 30, height: 26)
                                .foregroundStyle(notch.tool == t ? (theme == .minimal ? .black : .black) : theme.color(i).opacity(0.85))
                                .background(RoundedRectangle(cornerRadius: 7).fill(notch.tool == t ? theme.color(i) : .white.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                        .help(t.title)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: 30)
            .padding(.bottom, 6)
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let now = NotchTool.allCases.filter(\.isEnabled)
            if now != enabledTools { enabledTools = now }
        }
    }
}

struct ToolContent: View {
    let tool: NotchTool
    var body: some View {
        switch tool {
        case .home: HomeTool()
        case .revenue: RevenueTool()
        case .scratchpad: ScratchpadTool()
        case .shelf: ShelfTool()
        case .calendar: CalendarTool()
        case .timers: TimersTool()
        case .stats: StatsTool()
        case .screenTime: ScreenTimeTool()
        case .weather: WeatherTool()
        case .clipboard: ClipboardTool()
        case .notes: NotesTool()
        case .files: FilesTool()
        case .links: LinksTool()
        case .emoji: EmojiTool()
        case .sounds: SoundsTool()
        case .message: MessageTool()
        case .claude: ClaudeTool()
        case .units: UnitsTool()
        }
    }
}

/// Small rounded tile used across the tools.
struct Tile<Content: View>: View {
    var tint: Color = .white
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.12)))
    }
}

struct NotchField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
            .onSubmit(onSubmit)
    }
}
