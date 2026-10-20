import AppKit
import QuickLook
import SwiftUI

struct Thumbnail: View {
    let item: FileItem
    var size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05))
            }
        }
        .task(id: "\(item.url.path)\(Int(size))") {
            image = await Thumbnails.shared.image(for: item, size: size)
        }
    }
}

struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key).font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.4)))
    }
}

struct ChipRow: View {
    let chips: [Query.Chip]
    let onRemove: ((Query.Chip) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    HStack(spacing: 4) {
                        Image(systemName: chip.symbol)
                        Text(chip.label)
                        if let onRemove {
                            Button { onRemove(chip) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                                .buttonStyle(.plain).help("Remove filter")
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}

/// Shows any list of files as a grid or a table, with selection, Quick Look and the usual actions.
struct FileBrowser: View {
    let items: [FileItem]
    var emptyMessage = "Nothing here yet."
    var cap = 6_000

    @EnvironmentObject var app: AppState
    @FocusState private var focused: Bool
    @State fileprivate var columns = 1

    private var shown: [FileItem] { Array(items.sorted(by: app.sortKey, ascending: app.sortAscending).prefix(cap)) }

    var body: some View {
        let list = shown
        Group {
            if items.isEmpty {
                ContentUnavailableView(emptyMessage, systemImage: "tray")
            } else if app.viewMode == .grid {
                grid(list)
            } else {
                table(list)
            }
        }
        .quickLookPreview($app.previewURL, in: list.filter { !$0.isFolder }.map(\.url))
        .safeAreaInset(edge: .bottom) {
            if items.count > cap {
                Text("Showing \(cap.formatted()) of \(items.count.formatted()). Search to narrow it down.")
                    .font(.caption).foregroundStyle(.secondary).padding(6).frame(maxWidth: .infinity).background(.bar)
            }
        }
    }

    private func grid(_ list: [FileItem]) -> some View {
        GeometryReader { geo in
            gridScroll(list)
                .onAppear { columns = columnCount(geo.size.width) }
                .onChange(of: geo.size.width) { columns = columnCount(geo.size.width) }
                .onChange(of: app.cardSize) { columns = columnCount(geo.size.width) }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.selection = [] }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .modifier(GridKeys(list: list, browser: self))
    }

    private func columnCount(_ width: CGFloat) -> Int {
        max(1, Int((width - 36 + 14) / (app.cardSize + 14)))
    }

    private func gridScroll(_ list: [FileItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: app.cardSize, maximum: app.cardSize * 1.4), spacing: 14)], spacing: 16) {
                    ForEach(list) { item in card(item, list) }
                }
                .padding(18)
            }
            .onChange(of: app.selection) {
                if app.selection.count == 1, let u = app.selection.first { withAnimation { proxy.scrollTo(u) } }
            }
        }
    }

    private func card(_ item: FileItem, _ list: [FileItem]) -> some View {
        FileCard(item: item, size: app.cardSize, selected: app.selection.contains(item.url))
            .id(item.url)
            .onTapGesture(count: 2) { primary(item, in: list) }
            .simultaneousGesture(TapGesture().onEnded { select(item, in: list) })
            .contextMenu { FileMenu(items: targets(for: item, in: list), all: list) }
            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
    }

    fileprivate struct GridKeys: ViewModifier {
        let list: [FileItem]
        let browser: FileBrowser
        func body(content: Content) -> some View {
            content
                .onKeyPress(.space) { browser.togglePreview(list); return .handled }
                .onKeyPress(.return) { if let i = browser.selected(list) { browser.primary(i, in: list) }; return .handled }
                .onKeyPress(.leftArrow) { browser.move(-1, list); return .handled }
                .onKeyPress(.rightArrow) { browser.move(1, list); return .handled }
                .onKeyPress(.upArrow) { browser.move(-browser.columns, list); return .handled }
                .onKeyPress(.downArrow) { browser.move(browser.columns, list); return .handled }
        }
    }

    private func table(_ list: [FileItem]) -> some View {
        Table(list, selection: $app.selection) {
            TableColumn("Name") { item in
                HStack(spacing: 8) {
                    Thumbnail(item: item, size: 22).frame(width: 22, height: 22)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if item.isCloudOnly { Image(systemName: "icloud").foregroundStyle(.secondary) }
                }
                .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
            }
            .width(min: 220, ideal: 360)
            TableColumn("Kind") { Text($0.typeName).foregroundStyle(.secondary).lineLimit(1) }.width(min: 80, ideal: 140)
            TableColumn("Size") { Text($0.isFolder ? "--" : Format.size($0.size)).foregroundStyle(.secondary).monospacedDigit() }.width(80)
            TableColumn("Date") { Text(Format.date($0.date)).foregroundStyle(.secondary) }.width(min: 120, ideal: 160)
            TableColumn("From") { Text($0.source ?? "").foregroundStyle(.secondary) }.width(min: 60, ideal: 110)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            FileMenu(items: list.filter { urls.contains($0.url) }, all: list)
        } primaryAction: { urls in
            if let u = urls.first, let i = list.first(where: { $0.url == u }) { primary(i, in: list) }
        }
        .onKeyPress(.space) { togglePreview(list); return .handled }
    }

    // MARK: Interaction

    private func select(_ item: FileItem, in list: [FileItem]) {
        focused = true
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if app.selection.contains(item.url) { app.selection.remove(item.url) } else { app.selection.insert(item.url) }
        } else if mods.contains(.shift), let anchor = selected(list), let a = list.firstIndex(of: anchor), let b = list.firstIndex(of: item) {
            app.selection = Set(list[min(a, b)...max(a, b)].map(\.url))
        } else {
            app.selection = [item.url]
        }
        if app.previewURL != nil { app.previewURL = item.url }
    }

    fileprivate func selected(_ list: [FileItem]) -> FileItem? { list.first { app.selection.contains($0.url) } }

    fileprivate func move(_ step: Int, _ list: [FileItem]) {
        guard !list.isEmpty else { return }
        let current = selected(list).flatMap { list.firstIndex(of: $0) } ?? (step > 0 ? -1 : list.count)
        let next = min(max(current + step, 0), list.count - 1)
        app.selection = [list[next].url]
        if app.previewURL != nil { app.previewURL = list[next].url }
    }

    fileprivate func togglePreview(_ list: [FileItem]) {
        if app.previewURL != nil { app.previewURL = nil }
        else if let i = selected(list), !i.isFolder { app.previewURL = i.url }
    }

    private func targets(for item: FileItem, in list: [FileItem]) -> [FileItem] {
        app.selection.contains(item.url) ? list.filter { app.selection.contains($0.url) } : [item]
    }

    fileprivate func primary(_ item: FileItem, in list: [FileItem]) {
        if item.isFolder { app.go(.folder(item.url)) }
        else if item.category == .music { Player.shared.play(item, in: list) }
        else if item.category == .apps || item.category == .archives { app.open([item.url]) }
        else { app.selection = [item.url]; app.previewURL = item.url }
    }
}

struct FileCard: View {
    let item: FileItem
    let size: CGFloat
    let selected: Bool
    @State private var hover = false
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Thumbnail(item: item, size: size)
                    .frame(width: size, height: size * 0.82)
                    .shadow(color: .black.opacity(item.category == .images || item.category == .videos ? 0.15 : 0), radius: 3, y: 1)
                if item.category == .videos { badge("play.fill") }
                if item.isCloudOnly { badge("icloud") }
                if hover && item.category == .images {
                    Button { app.copyText([item]) } label: {
                        Label("Copy Text", systemImage: "text.viewfinder").font(.caption.weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain).padding(6)
                }
            }
            VStack(spacing: 1) {
                Text(item.name).font(.callout).lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor : .clear))
                    .foregroundStyle(selected ? .white : .primary)
                Text(item.isFolder ? "Folder" : Format.size(item.size)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.12) : hover ? Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(item.url.path)
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.caption2).padding(5).background(.thinMaterial, in: Circle()).padding(6)
    }
}

/// The right-click menu for one or more files.
struct FileMenu: View {
    let items: [FileItem]
    let all: [FileItem]
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: Library

    var body: some View {
        let urls = items.map(\.url)
        if let first = items.first, !first.isFolder {
            Button("Quick Look") { app.selection = [first.url]; app.previewURL = first.url }
        }
        Button("Open") { app.open(urls) }
        if items.count == 1, items[0].category == .music { Button("Play") { Player.shared.play(items[0], in: all) } }
        Button("Show in Finder") { app.showInFinder(urls) }
        Divider()
        if items.contains(where: { $0.category == .images || $0.ext == "pdf" }) {
            Button("Copy Text") { app.copyText(items) }
        }
        Button("Copy") { app.copy(urls) }
        Button("Copy Path") { app.copyPaths(urls) }
        Button("Pin to Sidebar") {
            for i in items { library.pin(i.isFolder ? i.url : i.url.deletingLastPathComponent()) }
        }
        Button("Get Info") { app.selection = Set(urls); app.showInspector = true }
        Divider()
        Button("Move to Trash", role: .destructive) { library.trash(urls); app.selection.subtract(urls) }
    }
}
