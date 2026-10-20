import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: Library
    @EnvironmentObject var text: TextIndex
    @Environment(\.openWindow) private var openWindow
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .navigationTitle(app.isSearching ? "Search" : (app.destination ?? .home).title)
                .navigationSubtitle(subtitle)
        }
        .inspector(isPresented: $app.showInspector) {
            InspectorView().inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar { toolbar }
        .overlay(alignment: .bottom) { toast }
        .onChange(of: app.focusSearch) { searchFocused = true }
        .onAppear { app.openMainWindow = { openWindow(id: "main") } }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var subtitle: String {
        if library.isScanning { return "Scanning your files…" }
        if text.isIndexing { return "Reading text in images… \(text.indexedCount.formatted())" }
        return "\(library.items.count.formatted()) files"
    }

    @ViewBuilder private var detail: some View {
        if app.isSearching {
            SearchResultsView()
        } else {
            switch app.destination ?? .home {
            case .home: HomeView()
            case .recents: FileBrowser(items: library.recents, emptyMessage: "Nothing new in the last 30 days.")
            case .category(let c): FileBrowser(items: library.items(in: c), emptyMessage: "No \(c.title.lowercased()) found.")
            case .screenshots: FileBrowser(items: library.screenshots, emptyMessage: "No screenshots found.")
            case .largeFiles: FileBrowser(items: library.largeFiles, emptyMessage: "No files over 100 MB.")
            case .downloadedFrom(let s): DownloadedFromView(source: s)
            case .duplicates: DuplicatesView()
            case .cleanUp: CleanUpView()
            case .saved(let q): FileBrowser(items: library.search(QueryParser.parse(q)), emptyMessage: "Nothing matches “\(q)” right now.")
            case .folder(let u): FolderView(url: u)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if let song = Player.shared.current { NowPlaying(song: song) }
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search, or try “pdfs from last week”", text: $app.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { app.searchText = ""; searchFocused = false }
                if app.isSearching {
                    Button { app.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                } else {
                    KeyCap("⌘F")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(width: 380)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $app.viewMode) {
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
                Image(systemName: "list.bullet").tag(ViewMode.list)
            }
            .pickerStyle(.segmented).help("Grid ⌘1 · List ⌘2")
            Menu {
                Picker("Sort by", selection: $app.sortKey) { ForEach(SortKey.allCases) { Text($0.title).tag($0) } }
                Toggle("Reverse order", isOn: $app.sortAscending)
            } label: { Image(systemName: "arrow.up.arrow.down") }
                .help("Sort")
            Button { app.toggleLook() } label: {
                Image(systemName: app.look == .playful ? "paintpalette" : "circle.lefthalf.filled")
            }
            .help("Switch look (⌃⌘T): \(app.look == .playful ? "Playful" : "Minimal")")
            Button { app.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Inspector ⌘I")
        }
    }

    @ViewBuilder private var toast: some View {
        if let msg = app.toastMessage {
            Text(msg).padding(.horizontal, 14).padding(.vertical, 9)
                .background(.thickMaterial, in: Capsule())
                .shadow(radius: 6, y: 2)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct NowPlaying: View {
    let song: FileItem
    @ObservedObject var player = Player.shared
    var body: some View {
        HStack(spacing: 6) {
            Button { player.skip(-1) } label: { Image(systemName: "backward.fill") }
            Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
            Button { player.skip(1) } label: { Image(systemName: "forward.fill") }
            Text(song.url.deletingPathExtension().lastPathComponent).lineLimit(1).frame(maxWidth: 160)
            Button { player.stop() } label: { Image(systemName: "xmark") }
        }
        .buttonStyle(.borderless)
    }
}

struct Sidebar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: Library

    var body: some View {
        List(selection: Binding(get: { app.isSearching ? nil : app.destination }, set: { if let d = $0 { app.go(d) } })) {
            Section("Library") {
                row("Home", "house", .home)
                row("Recents", "clock", .recents)
                ForEach(Category.allCases) { c in
                    Label { Text(c.title) } icon: { Image(systemName: c.symbol).foregroundStyle(c.iconColor(app.look)) }
                        .badge(library.items(in: c).count)
                        .tag(Destination.category(c))
                }
            }
            Section("Smart Folders") {
                row("Screenshots", "camera.viewfinder", .screenshots)
                row("Large Files", "externaldrive", .largeFiles)
            }
            Section("Tools") {
                row("Downloaded From", "arrow.down.circle", .downloadedFrom(nil))
                row("Duplicates", "square.on.square", .duplicates)
                row("Clean Up", "sparkles", .cleanUp)
            }
            if !library.savedSearches.isEmpty {
                Section("Saved Searches") {
                    ForEach(library.savedSearches, id: \.self) { q in
                        row(q, "magnifyingglass", .saved(q))
                            .contextMenu { Button("Remove") { library.savedSearches.removeAll { $0 == q } } }
                    }
                }
            }
            Section("Pinned") {
                ForEach(library.pinnedFolders, id: \.self) { u in
                    row(FileManager.default.displayName(atPath: u.path), "folder", .folder(u))
                        .contextMenu { Button("Unpin") { library.pinnedFolders.removeAll { $0 == u } } }
                }
                Button { addFolder() } label: { Label("Add Folder…", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, _ symbol: String, _ d: Destination) -> some View {
        Label(title, systemImage: symbol).tag(d)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach(library.pin) }
    }
}

struct SearchResultsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: Library
    @EnvironmentObject var text: TextIndex

    var body: some View {
        let parsed = QueryParser.parse(app.searchText)
        let q = parsed.removing(app.removedChips)
        let results = library.search(q)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Understood as").foregroundStyle(.secondary)
                ChipRow(chips: q.chips) { app.removedChips.insert($0.id) }
                Spacer()
                Text("\(results.count.formatted()) results").foregroundStyle(.secondary).monospacedDigit()
                Button { library.saveSearch(app.searchText); app.toast("Saved to the sidebar") } label: {
                    Label("Save Search", systemImage: "plus.magnifyingglass")
                }
                .disabled(library.savedSearches.contains(app.searchText))
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            FileBrowser(items: results, emptyMessage: q.isEmpty ? "Type what you remember." : "No files match. Try removing a filter.")
        }
    }
}

struct FolderView: View {
    let url: URL
    @EnvironmentObject var app: AppState
    @State private var items: [FileItem] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(crumbs, id: \.self) { c in
                    Button(FileManager.default.displayName(atPath: c.path)) { app.go(.folder(c)) }.buttonStyle(.plain)
                        .foregroundStyle(c == url ? .primary : .secondary)
                    if c != url { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
                Spacer()
                Button("Show in Finder") { app.showInFinder([url]) }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            Divider()
            FileBrowser(items: items, emptyMessage: "This folder is empty.")
        }
        .task(id: url) {
            let u = url
            items = await Task.detached { Scanner.contents(of: u) }.value
        }
    }

    private var crumbs: [URL] {
        var out: [URL] = [], u = url
        while u.path != "/" && out.count < 6 { out.insert(u, at: 0); if u == Paths.home { break }; u.deleteLastPathComponent() }
        return out
    }
}
