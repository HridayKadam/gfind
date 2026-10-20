import AppKit
import SwiftUI

/// Everything GFind knows about the user's files.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var items: [FileItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?
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

    private var byCategory: [Category: [FileItem]] = [:]

    // MARK: - Scanning

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            var found = await Task.detached(priority: .userInitiated) { Scanner.scan() }.value
            if AutoClean.run(&found) { found = await Task.detached(priority: .userInitiated) { Scanner.scan() }.value }
            apply(found)
            isScanning = false
            lastScan = .now
            TextIndex.shared.index(found)
            await measureApps()
            scanDuplicates()
        }
    }

    private func apply(_ new: [FileItem]) {
        items = new
        byCategory = Dictionary(grouping: new.filter { $0.category != nil }) { $0.category! }
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
    var screenshots: [FileItem] { items.filter(\.isScreenshot) }
    var largeFiles: [FileItem] { items.filter { $0.size >= 100_000_000 } }
    var recents: [FileItem] {
        let cutoff = Date.now.addingTimeInterval(-30 * 86_400)
        return items.filter { $0.date > cutoff && $0.category != .apps }
    }
    var downloads: [FileItem] { items.filter { $0.source != nil || $0.isInDownloads } }

    var recentDownloads: [FileItem] {
        items.filter(\.isInDownloads).sorted { $0.date > $1.date }.prefix(10).map { $0 }
    }

    var sources: [(name: String, items: [FileItem])] {
        Dictionary(grouping: items.filter { $0.source != nil }) { $0.source! }
            .map { (name: $0.key, items: $0.value) }
            .sorted { a, b in
                let an = DownloadSource.isNamed(a.name), bn = DownloadSource.isNamed(b.name)
                return an != bn ? an : a.items.count > b.items.count
            }
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

    func item(at url: URL) -> FileItem? { items.first { $0.url == url } }

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
