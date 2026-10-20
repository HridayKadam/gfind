import AppKit
import SwiftUI

/// A Spotlight-style search panel that drops in over any app.
@MainActor
final class QuickSearch: NSObject, NSWindowDelegate {
    static let shared = QuickSearch()
    private var panel: Panel?
    let model = Model()

    final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { QuickSearch.shared.hide() }
    }

    final class Model: ObservableObject {
        @Published var text = ""
        @Published var selected = 0
        @Published var focus = 0
    }

    func toggle() { panel?.isVisible == true ? hide() : show() }

    func show() {
        if panel == nil {
            let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                          styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.backgroundColor = .clear
            [.closeButton, .miniaturizeButton, .zoomButton].forEach { p.standardWindowButton($0)?.isHidden = true }
            p.delegate = self
            let host = NSHostingView(rootView: QuickSearchView(model: model)
                .environmentObject(Library.shared).environmentObject(AppState.shared).environmentObject(TextIndex.shared))
            host.sizingOptions = []
            p.contentView = host
            panel = p
        }
        guard let panel else { return }
        model.text = ""
        model.selected = 0
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - f.height * 0.22 - panel.frame.height))
        }
        panel.makeKeyAndOrderFront(nil)
        model.focus += 1
    }

    func hide() { panel?.orderOut(nil) }

    func windowDidResignKey(_ notification: Notification) { hide() }
}

struct QuickSearchView: View {
    @ObservedObject var model: QuickSearch.Model
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppState
    @EnvironmentObject var text: TextIndex
    @FocusState private var focused: Bool

    private var query: Query { QueryParser.parse(model.text) }
    private var results: [FileItem] {
        let q = query
        if model.text.trimmingCharacters(in: .whitespaces).isEmpty {
            return library.items.filter { $0.category != .apps }.sorted { $0.date > $1.date }.prefix(8).map { $0 }
        }
        if q.isEmpty { return [] }
        return Array(library.search(q).sorted { $0.date > $1.date }.prefix(40))
    }

    var body: some View {
        let list = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                TextField("Search, or try “screenshots from last week”", text: $model.text)
                    .textFieldStyle(.plain).font(.system(size: 22))
                    .focused($focused)
                    .onSubmit { activate(list) }
                    .onKeyPress(.downArrow) { model.selected = min(model.selected + 1, max(list.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { model.selected = max(model.selected - 1, 0); return .handled }
                    .onChange(of: model.text) { model.selected = 0 }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            if !query.chips.isEmpty {
                ChipRow(chips: query.chips, onRemove: nil).padding(.horizontal, 18).padding(.bottom, 8)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if model.text.isEmpty {
                            Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 12).padding(.top, 8)
                        }
                        ForEach(Array(list.enumerated()), id: \.element.id) { idx, item in
                            QuickRow(item: item, selected: idx == model.selected)
                                .id(idx)
                                .onTapGesture { model.selected = idx; activate(list) }
                                .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                        }
                        if list.isEmpty && !model.text.isEmpty {
                            Text("Nothing matches yet.").foregroundStyle(.secondary).padding(20)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selected) { proxy.scrollTo(model.selected) }
            }
            Divider()
            HStack(spacing: 14) {
                hint("↩", "Open"); hint("⌘↩", "Show in GFind"); hint("⌥↩", "Show in Finder"); Spacer(); hint("esc", "Close")
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 680, height: 440)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onChange(of: model.focus) { focused = true }
        .onAppear { focused = true }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) { KeyCap(key); Text(label) }
    }

    private func activate(_ list: [FileItem]) {
        guard list.indices.contains(model.selected) else { return }
        let item = list[model.selected]
        let flags = NSEvent.modifierFlags
        QuickSearch.shared.hide()
        if flags.contains(.command) { app.reveal(item) }
        else if flags.contains(.option) { app.showInFinder([item.url]) }
        else { app.open([item.url]) }
    }
}

private struct QuickRow: View {
    let item: FileItem
    let selected: Bool
    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(item: item, size: 36).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text("\(item.typeName) · \(Format.size(item.size)) · \(Format.relative(item.date))")
                    .font(.caption).foregroundStyle(selected ? .white.opacity(0.85) : .secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .foregroundStyle(selected ? .white : .primary)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }
}

/// The menu bar window: newest downloads, ready to drag.
struct MenuBarView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Latest downloads").font(.headline).padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            if library.recentDownloads.isEmpty {
                Text(library.isScanning ? "Scanning…" : "Nothing in Downloads yet.")
                    .foregroundStyle(.secondary).padding(14)
            }
            ForEach(library.recentDownloads) { item in MenuRow(item: item) }
            Divider().padding(.vertical, 6)
            Group {
                MenuButton(title: "Quick Search", shortcut: shortcutLabel) { QuickSearch.shared.show() }
                MenuButton(title: "Open GFind", shortcut: nil) { app.openMainWindow = { openWindow(id: "main") }; app.showMain() }
                MenuButton(title: "Settings…", shortcut: "⌘,") { NSApp.activate(ignoringOtherApps: true); openSettings() }
                MenuButton(title: "Quit GFind", shortcut: "⌘Q") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 6)
        }
        .padding(.bottom, 8)
        .frame(width: 340)
        .onAppear { app.openMainWindow = { openWindow(id: "main") } }
    }

    private var shortcutLabel: String {
        QuickSearchShortcut(rawValue: UserDefaults.standard.string(forKey: "quickSearchShortcut") ?? "")?.label ?? "⇧⌘Space"
    }
}

private struct MenuRow: View {
    let item: FileItem
    @EnvironmentObject var app: AppState
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(item: item, size: 34).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text("\(Format.size(item.size)) · \(Format.relative(item.date))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if hover {
                Button { app.reveal(item) } label: { Image(systemName: "rectangle.grid.2x2") }.help("Show in GFind")
                Button { app.showInFinder([item.url]) } label: { Image(systemName: "folder") }.help("Show in Finder")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.08) : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { app.open([item.url]) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
    }
}

private struct MenuButton: View {
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack { Text(title); Spacer(); if let shortcut { Text(shortcut).foregroundStyle(.secondary) } }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.accentColor.opacity(0.85) : .clear))
                .foregroundStyle(hover ? .white : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
