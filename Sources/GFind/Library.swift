import AppKit
import CoreServices
import os
import SwiftUI

let log = Logger(subsystem: "com.hriday.gfind", category: "app")

/// Everything GFind knows about the user's files.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var items: [FileItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var lastScanDuration: TimeInterval?
    @Published private(set) var duplicates: [DuplicateGroup] = []
    @Published private(set) var duplicateStatus: String?
    @Published private(set) var duplicatesScanned = false
    @Published private(set) var cleanUp: [CleanUpCard] = []
    @Published var savedSearches: [String] = UserDefaults.standard.stringArray(forKey: "savedSearches") ?? [] {
        didSet { UserDefaults.standard.set(savedSearches, forKey: "savedSearches") }
    }
    @Published var pinnedFolders: [URL] = (UserDefaults.standard.stringArray(forKey: "pinnedFolders") ?? []).map { URL(fileURLWithPath: $0) } {
        didSet { UserDefaults.standard.set(pinnedFolders.map(\.path), forKey: "pinnedFolders") }
    }

    // Derived lists, rebuilt once per change instead of on every view update.
    private var byCategory: [Category: [FileItem]] = [:]
    private(set) var screenshots: [FileItem] = []
    private(set) var largeFiles: [FileItem] = []
    private(set) var downloads: [FileItem] = []
    private(set) var recentDownloads: [FileItem] = []
    private(set) var sources: [(name: String, items: [FileItem])] = []
    private var byURL: [URL: Int] = [:]

    private var rescanPending = false
    private var watcher: FolderWatcher?
    private let cacheFile = Paths.support.appendingPathComponent("index.json")

    // MARK: - Scanning

    /// Shows the last saved index straight away, then rescans and starts watching for changes.
    func start() {
        guard watcher == nil else { return }
        let file = cacheFile
        Task {
            if items.isEmpty, let cached = await Task.detached(priority: .userInitiated, operation: {
                (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([FileItem].self, from: $0) }
            }).value {
                apply(cached)
                log.info("Loaded \(cached.count) cached items")
            }
            refresh()
        }
        watcher = FolderWatcher(paths: Scanner.roots.map(\.path)) {
            Task { @MainActor in Library.shared.refresh() }
        }
    }

    func refresh() {
        guard !isScanning else { rescanPending = true; return }
        isScanning = true
        let began = Date()
        Task {
            var found = await Task.detached(priority: .userInitiated) { Scanner.scan() }.value
            if AutoClean.run(&found) { found = await Task.detached(priority: .userInitiated) { Scanner.scan() }.value }
            // Keep app sizes from the previous scan; measuring bundles is slow.
            let known = Dictionary(items.filter { $0.category == .apps }.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
            found = found.map { var i = $0; if i.category == .apps, i.size == 0, let s = known[i.url] { i.size = s }; return i }
            apply(found)
            isScanning = false
            lastScan = .now
            lastScanDuration = Date().timeIntervalSince(began)
            log.info("Scanned \(found.count) items in \(self.lastScanDuration ?? 0, format: .fixed(precision: 2))s")
            TextIndex.shared.index(found)
            await measureApps()
            saveCache()
            scanDuplicates()
            if rescanPending { rescanPending = false; refresh() }
        }
    }

    private func saveCache() {
        let snapshot = items, file = cacheFile
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }
    }

    private func apply(_ new: [FileItem]) {
        items = new
        byCategory = Dictionary(grouping: new.filter { $0.category != nil }) { $0.category! }
        screenshots = new.filter(\.isScreenshot)
        largeFiles = new.filter { $0.size >= 100_000_000 }
        downloads = new.filter { $0.source != nil || $0.isInDownloads }
        recentDownloads = new.filter(\.isInDownloads).sorted { $0.date > $1.date }.prefix(10).map { $0 }
        sources = Dictionary(grouping: new.filter { $0.source != nil }) { $0.source! }
            .map { (name: $0.key, items: $0.value) }
            .sorted { a, b in
                let an = DownloadSource.isNamed(a.name), bn = DownloadSource.isNamed(b.name)
                return an != bn ? an : a.items.count > b.items.count
            }
        byURL = Dictionary(new.enumerated().map { ($1.url, $0) }, uniquingKeysWith: { a, _ in a })
        rebuildCleanUp()
    }

    /// App bundles are folders, so their size is measured separately.
    private func measureApps() async {
        let apps = items.filter { $0.category == .apps && $0.size == 0 }.map(\.url)
        guard !apps.isEmpty else { return }
        let sizes = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: apps.map { ($0, Scanner.directorySize($0)) })
        }.value
        apply(items.map { var i = $0; if let s = sizes[i.url] { i.size = s }; return i })
    }

    func scanDuplicates() {
        guard duplicateStatus == nil else { return }
        duplicateStatus = "Looking for duplicates…"
        let snapshot = items
        Task {
            let groups = await Task.detached(priority: .utility) {
                DuplicateFinder.find(snapshot) { msg in Task { @MainActor in Library.shared.duplicateStatus = msg } }
            }.value
            duplicates = groups
            duplicatesScanned = true
            duplicateStatus = nil
            rebuildCleanUp()
        }
    }

    func setKeep(_ url: URL, in group: DuplicateGroup) {
        guard let i = duplicates.firstIndex(where: { $0.id == group.id }) else { return }
        duplicates[i].keep = url
        rebuildCleanUp()
    }

    private func rebuildCleanUp() {
        cleanUp = CleanUpCard.build(items: items, duplicates: duplicates)
    }

    // MARK: - Queries

    func items(in c: Category) -> [FileItem] { byCategory[c] ?? [] }
    var recents: [FileItem] {
        let cutoff = Date.now.addingTimeInterval(-30 * 86_400)
        return items.filter { $0.date > cutoff && $0.category != .apps }
    }

    var freeableBytes: Int64 {
        var seen = Set<URL>(), total: Int64 = 0
        for card in cleanUp { for i in card.items where seen.insert(i.url).inserted { total += i.size } }
        return total
    }

    func search(_ q: Query) -> [FileItem] {
        guard !q.isEmpty else { return [] }
        let text = TextIndex.shared
        return items.filter { q.matches($0, text: text) }
    }

    func item(at url: URL) -> FileItem? { byURL[url].map { items[$0] } }

    // MARK: - Actions

    /// Moves files to the Trash (never deletes outright). Returns how many were moved.
    @discardableResult
    func trash(_ urls: [URL]) -> Int {
        var moved: [URL] = [], failed: [String] = []
        for u in urls {
            do { try FileManager.default.trashItem(at: u, resultingItemURL: nil); moved.append(u) }
            catch { failed.append(u.lastPathComponent) }
        }
        let gone = Set(moved)
        let freed = items.filter { gone.contains($0.url) }.totalSize
        apply(items.filter { !gone.contains($0.url) })
        duplicates = duplicates.compactMap { g in
            var g = g
            g.items.removeAll { gone.contains($0.url) }
            if gone.contains(g.keep) { g.keep = g.items.first?.url ?? g.keep }
            return g.items.count > 1 ? g : nil
        }
        rebuildCleanUp()
        TextIndex.shared.forget(moved)
        if !failed.isEmpty {
            AppState.shared.toast("Couldn't move \(failed.count) item(s) to the Trash: \(failed.prefix(3).joined(separator: ", "))")
        } else if !moved.isEmpty {
            AppState.shared.toast("Moved \(moved.count) item\(moved.count == 1 ? "" : "s") (\(Format.size(freed))) to the Trash")
        }
        return moved.count
    }

    func pin(_ folder: URL) {
        if !pinnedFolders.contains(folder) { pinnedFolders.append(folder) }
    }

    func saveSearch(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty && !savedSearches.contains(t) { savedSearches.append(t) }
    }
}

/// Optional rules that tidy up after each scan. Off until turned on in Settings.
enum AutoClean {
    /// Returns true if anything moved, so the caller can rescan.
    static func run(_ items: inout [FileItem]) -> Bool {
        let d = UserDefaults.standard
        var changed = false
        let fm = FileManager.default
        if d.bool(forKey: "autoTrashInstallers") {
            for i in items where i.isInstaller && i.isInDownloads && i.date < .now.addingTimeInterval(-30 * 86_400) {
                if (try? fm.trashItem(at: i.url, resultingItemURL: nil)) != nil { changed = true }
            }
        }
        if d.bool(forKey: "autoFileScreenshots") {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM"
            for i in items where i.isScreenshot && i.url.deletingLastPathComponent() == Paths.desktop
                && i.date < .now.addingTimeInterval(-86_400) {
                let folder = Paths.pictures.appendingPathComponent("Screenshots/\(f.string(from: i.date))")
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                if (try? fm.moveItem(at: i.url, to: folder.appendingPathComponent(i.name))) != nil { changed = true }
            }
        }
        return changed
    }
}

/// Watches folders with FSEvents and calls back (debounced) when anything inside changes.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?

    init(paths: [String], onChange: @escaping () -> Void) {
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) } as CFArray
        stream = FSEventStreamCreate(nil, callback, &ctx, existing, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
