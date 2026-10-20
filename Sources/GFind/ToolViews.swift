import AppKit
import AVFoundation
import ImageIO
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: Library

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                    ForEach(Category.allCases) { c in CategoryCard(category: c) }
                }

                section("Clean Up", trailing: library.freeableBytes > 0 ? "Up to \(Format.gigabytes(library.freeableBytes)) to free" : nil) {
                    app.go(.cleanUp)
                } content: {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(library.cleanUp.filter { !$0.items.isEmpty }) { card in
                                CleanUpTile(card: card).frame(width: 220)
                                    .onTapGesture { app.go(.cleanUp); app.reviewCard = card.kind }
                            }
                            if library.cleanUp.allSatisfy({ $0.items.isEmpty }) {
                                Text(library.isScanning ? "Scanning…" : "Nothing to clean up. Nice.").foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !library.sources.isEmpty {
                    section("Downloaded From", trailing: "\(library.downloads.count.formatted()) files · \(library.sources.count) sources") {
                        app.go(.downloadedFrom(nil))
                    } content: {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(library.sources.prefix(12), id: \.name) { s in
                                    SourceTile(name: s.name, items: s.items).onTapGesture { app.go(.downloadedFrom(s.name)) }
                                }
                            }
                        }
                    }
                }

                ForEach([Category.images, .videos, .music, .documents], id: \.self) { c in
                    let recent = library.items(in: c).sorted { $0.date > $1.date }.prefix(14)
                    if !recent.isEmpty {
                        section("Recent \(c.title.lowercased())", trailing: nil) { app.go(.category(c)) } content: {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(Array(recent)) { item in
                                        FileCard(item: item, size: 120, selected: false)
                                            .frame(width: 132)
                                            .onTapGesture(count: 2) {
                                                if c == .music { Player.shared.play(item, in: Array(recent)) } else { app.open([item.url]) }
                                            }
                                            .contextMenu { FileMenu(items: [item], all: Array(recent)) }
                                            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .overlay { if library.items.isEmpty && library.isScanning { ProgressView("Finding your files…") } }
    }

    private func section<C: View>(_ title: String, trailing: String?, action: @escaping () -> Void, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.weight(.semibold))
                if let trailing { Text(trailing).foregroundStyle(.secondary) }
                Spacer()
                Button("See all", action: action).buttonStyle(.link)
            }
            content()
        }
    }
}

private struct CategoryCard: View {
    let category: Category
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: Library
    @State private var hover = false

    var body: some View {
        let items = library.items(in: category)
        Button { app.go(.category(category)) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: category.symbol).font(.system(size: 26, weight: .medium))
                    .foregroundStyle(category.iconColor(app.look))
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title).font(.headline)
                    Text("\(items.count.formatted()) · \(Format.size(items.totalSize))").font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(category.cardBackground(app.look)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(app.look == .minimal ? 0.1 : 0)))
            .scaleEffect(hover ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct CleanUpTile: View {
    let card: CleanUpCard
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: card.symbol).font(.title2)
                .foregroundStyle(app.look == .playful ? card.tint : .primary)
            Text(card.title).font(.headline).lineLimit(1)
            Text(card.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            Text("\(Format.size(card.size)) · \(card.items.count) items").font(.callout.weight(.medium)).monospacedDigit()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(app.look == .playful ? card.tint.opacity(0.13) : Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
    }
}

private struct SourceTile: View {
    let name: String
    let items: [FileItem]
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: DownloadSource.symbol(for: name)).font(.title3).frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.headline).lineLimit(1)
                Text("\(items.count) files · \(Format.size(items.totalSize))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
    }
}

struct DownloadedFromView: View {
    let source: String?
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: Library

    var body: some View {
        if let source {
            FileBrowser(items: library.items.filter { $0.source == source }, emptyMessage: "No downloads from \(source).")
        } else {
            let sources = library.sources
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(library.downloads.count.formatted()) files · \(sources.count) sources").foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(sources, id: \.name) { s in
                            SourceTile(name: s.name, items: s.items).frame(maxWidth: .infinity, alignment: .leading)
                                .onTapGesture { app.go(.downloadedFrom(s.name)) }
                        }
                    }
                    if sources.isEmpty {
                        ContentUnavailableView("No download sources yet", systemImage: "arrow.down.circle",
                                               description: Text("macOS records where each download came from. Files you download from now on will show up here."))
                    }
                }
                .padding(24)
            }
        }
    }
}

struct DuplicatesView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: Library
    @State private var confirm = false

    var body: some View {
        let groups = library.duplicates
        let total = groups.reduce(0) { $0 + $1.reclaimable }
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(groups.isEmpty ? "No duplicates" : "Free up \(Format.size(total))").font(.title2.weight(.semibold))
                    Text(library.duplicateStatus ?? "\(groups.count) groups. GFind keeps one copy of each; click another to keep it instead.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if library.duplicateStatus != nil { ProgressView().controlSize(.small) }
                Button("Rescan") { library.scanDuplicates() }.disabled(library.duplicateStatus != nil)
                Button("Move Extras to Trash") { confirm = true }.buttonStyle(.borderedProminent).disabled(groups.isEmpty)
            }
            .padding(18)
            .background(app.look == .playful ? Color.purple.opacity(0.08) : Color.primary.opacity(0.03))
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(groups) { g in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(g.kind == .identical ? "Identical" : "Look-alike") · \(g.items.count) files · \(Format.size(g.reclaimable)) to free")
                                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(g.items) { item in
                                        let keep = item.url == g.keep
                                        VStack(spacing: 4) {
                                            FileCard(item: item, size: 130, selected: false)
                                            Text(keep ? "Keep" : "Trash").font(.caption.weight(.bold))
                                                .padding(.horizontal, 8).padding(.vertical, 2)
                                                .background(Capsule().fill(keep ? Color.green.opacity(0.2) : Color.red.opacity(0.15)))
                                                .foregroundStyle(keep ? .green : .red)
                                            Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: Paths.home.path, with: "~"))
                                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head).frame(width: 140)
                                        }
                                        .frame(width: 145)
                                        .onTapGesture { library.setKeep(item.url, in: g) }
                                        .contextMenu { FileMenu(items: [item], all: g.items) }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
            .overlay {
                if groups.isEmpty && library.duplicateStatus == nil {
                    ContentUnavailableView(library.duplicatesScanned ? "No duplicates found" : "Not scanned yet", systemImage: "square.on.square")
                }
            }
        }
        .confirmationDialog("Move \(groups.flatMap(\.extras).count) files (\(Format.size(total))) to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { library.trash(groups.flatMap(\.extras).map(\.url)) }
        } message: { Text("You can put them back from the Trash. iCloud-only files are skipped.") }
    }
}

struct CleanUpView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: Library

    var body: some View {
        if let kind = app.reviewCard, let card = library.cleanUp.first(where: { $0.kind == kind }) {
            CleanUpReview(card: card)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Free up \(Format.gigabytes(library.freeableBytes))").font(.largeTitle.weight(.bold))
                        Text("GFind finds the stuff you forgot about. You review it, you decide. Everything goes to the Trash, so you can always put it back.")
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                        ForEach(library.cleanUp) { card in
                            CleanUpTile(card: card).opacity(card.items.isEmpty ? 0.5 : 1)
                                .onTapGesture {
                                    if card.kind == .duplicates { app.go(.duplicates) } else if !card.items.isEmpty { app.reviewCard = card.kind }
                                }
                        }
                    }
                    if library.duplicateStatus != nil {
                        Label(library.duplicateStatus!, systemImage: "hourglass").foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
        }
    }
}

private struct CleanUpReview: View {
    let card: CleanUpCard
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: Library
    @State private var checked: Set<URL> = []
    @State private var confirm: [URL]?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { app.reviewCard = nil } label: { Label("Clean Up", systemImage: "chevron.left") }
                VStack(alignment: .leading) {
                    Text(card.title).font(.title2.weight(.semibold))
                    Text("\(card.items.count) items · \(Format.size(card.size))").foregroundStyle(.secondary)
                }
                .padding(.leading, 8)
                Spacer()
                Button("Trash Selected") { confirm = Array(checked) }.disabled(checked.isEmpty)
                Button("Trash All") { confirm = card.items.map(\.url) }.buttonStyle(.borderedProminent)
            }
            .padding(18)
            Divider()
            List(card.items) { item in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { checked.contains(item.url) },
                                             set: { if $0 { checked.insert(item.url) } else { checked.remove(item.url) } }))
                        .labelsHidden()
                    Thumbnail(item: item, size: 40).frame(width: 40, height: 40)
                    VStack(alignment: .leading) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Text(detail(item)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Format.size(item.size)).monospacedDigit().foregroundStyle(.secondary)
                    Button { app.showInFinder([item.url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                }
                .contextMenu { FileMenu(items: [item], all: card.items) }
            }
        }
        .confirmationDialog("Move \(confirm?.count ?? 0) items to the Trash?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let c = confirm { library.trash(c); checked.subtract(c) }
                confirm = nil
            }
        } message: { Text("Nothing is deleted outright. You can put files back from the Trash.") }
    }

    private func detail(_ i: FileItem) -> String {
        var parts = [i.url.deletingLastPathComponent().path.replacingOccurrences(of: Paths.home.path, with: "~")]
        if let o = i.lastOpened { parts.append("last opened \(Format.relative(o))") } else { parts.append("added \(Format.relative(i.date))") }
        return parts.joined(separator: " · ")
    }
}

struct InspectorView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: Library
    @EnvironmentObject var text: TextIndex
    @State private var details: [(String, String)] = []

    private var item: FileItem? {
        guard let u = app.selection.first else { return nil }
        return library.item(at: u) ?? Scanner.makeItem(u, nil, includeUncategorized: true)
    }

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 14) {
                    Thumbnail(item: item, size: 260).frame(maxWidth: .infinity).frame(height: 220)
                        .onTapGesture(count: 2) { app.previewURL = item.url }
                    Text(item.name).font(.headline).textSelection(.enabled)
                    if app.selection.count > 1 { Text("+ \(app.selection.count - 1) more selected").foregroundStyle(.secondary) }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        info("Kind", item.typeName)
                        if !item.isFolder { info("Size", Format.size(item.size)) }
                        ForEach(details, id: \.0) { info($0.0, $0.1) }
                        info("Created", Format.date(item.created))
                        info("Modified", Format.date(item.modified))
                        if let a = item.added { info("Added", Format.date(a)) }
                        if let o = item.lastOpened { info("Last opened", Format.date(o)) }
                        if let s = item.source { info("From", s) }
                        info("Where", item.url.deletingLastPathComponent().path.replacingOccurrences(of: Paths.home.path, with: "~"))
                    }
                    .font(.callout)
                    if let link = item.whereFroms.first {
                        Text(link).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    }
                    HStack {
                        Button("Open") { app.open([item.url]) }
                        Button("Show in Finder") { app.showInFinder([item.url]) }
                        if item.category == .images || item.ext == "pdf" { Button("Copy Text") { app.copyText([item]) } }
                    }
                    if let t = text.text(for: item), !t.isEmpty {
                        GroupBox("Text found") {
                            Text(t.prefix(1_500)).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
                .task(id: item.url) { details = await Self.mediaDetails(item) }
            } else {
                ContentUnavailableView("No selection", systemImage: "info.circle", description: Text("Select a file to see its details."))
                    .padding(.top, 60)
            }
        }
    }

    private func info(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(v).textSelection(.enabled).lineLimit(2)
        }
    }

    static func mediaDetails(_ item: FileItem) async -> [(String, String)] {
        guard !item.isCloudOnly else { return [] }
        var out: [(String, String)] = []
        if item.category == .images, let src = CGImageSourceCreateWithURL(item.url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                out.append(("Dimensions", "\(w) × \(h)"))
            }
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
                    .compactMap { $0 }.joined(separator: " ")
                if !camera.isEmpty { out.append(("Camera", camera)) }
            }
        }
        if item.category == .videos || item.category == .music {
            let asset = AVURLAsset(url: item.url)
            if let d = try? await asset.load(.duration), d.seconds.isFinite {
                let s = Int(d.seconds)
                out.append(("Duration", s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)))
            }
            if item.category == .videos, let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                out.append(("Dimensions", "\(Int(abs(size.width))) × \(Int(abs(size.height)))"))
            }
        }
        return out
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: Library
    @EnvironmentObject var text: TextIndex
    @AppStorage("quickSearchShortcut") private var shortcut: QuickSearchShortcut = .shiftCmdSpace
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("ocrEnabled") private var ocrEnabled = true
    @AppStorage("autoTrashInstallers") private var autoTrashInstallers = false
    @AppStorage("autoFileScreenshots") private var autoFileScreenshots = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Look", selection: $app.look) { ForEach(Look.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
                Toggle("Show latest downloads in the menu bar", isOn: $showMenuBar)
            }
            Section("Quick Search") {
                Picker("Shortcut", selection: $shortcut) { ForEach(QuickSearchShortcut.allCases) { Text($0.label).tag($0) } }
                    .onChange(of: shortcut) { HotKey.shared.register(shortcut) }
            }
            Section("Text in images") {
                Toggle("Read text in screenshots, recent photos and PDFs", isOn: $ocrEnabled)
                Text("\(text.indexedCount.formatted()) files read, on this Mac, with Apple's Vision framework. Nothing is uploaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Automatic clean up") {
                Toggle("Move installers (.dmg, .pkg) older than 30 days in Downloads to the Trash", isOn: $autoTrashInstallers)
                Toggle("File Desktop screenshots into Pictures/Screenshots, one folder per month", isOn: $autoFileScreenshots)
                Text("Runs after each scan. Files only ever go to the Trash.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Library") {
                LabeledContent("Folders", value: "Desktop, Documents, Downloads, Pictures, Movies, Music, Applications")
                LabeledContent("Files", value: library.items.count.formatted())
                Button("Rescan Now") { library.refresh() }.disabled(library.isScanning)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
    }
}
