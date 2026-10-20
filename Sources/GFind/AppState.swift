import AppKit
import AVFoundation
import Carbon
import QuickLookThumbnailing
import SwiftUI

/// UI state shared by the window, menus, menu bar and Quick Search.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var destination: Destination? = .home
    @Published var searchText = "" { didSet { if searchText != oldValue { removedChips = [] } } }
    @Published var removedChips: Set<String> = []
    @Published var selection: Set<URL> = []
    @Published var showInspector = false
    @Published var previewURL: URL?
    @Published var toastMessage: String?
    @Published var focusSearch = 0
    @Published var reviewCard: CleanUpCard.Kind?
    @AppStorage("viewMode") var viewMode: ViewMode = .grid
    @AppStorage("cardSize") var cardSize: Double = 150
    @AppStorage("sortKey") var sortKey: SortKey = .date
    @AppStorage("sortAscending") var sortAscending = false
    @AppStorage("look") var look: Look = .playful

    var openMainWindow: (() -> Void)?
    private var toastTask: Task<Void, Never>?

    var query: Query { QueryParser.parse(searchText).removing(removedChips) }
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    func go(_ d: Destination) {
        searchText = ""
        reviewCard = nil
        destination = d
        selection = []
    }

    func toast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { toastMessage = nil }
        }
    }

    func toggleLook() { look = look == .playful ? .minimal : .playful }
    func zoom(_ delta: Double) { cardSize = min(320, max(90, cardSize + delta)) }

    /// Brings the main window forward and reveals a file in it.
    func reveal(_ item: FileItem) {
        showMain()
        searchText = ""
        destination = .folder(item.url.deletingLastPathComponent())
        selection = [item.url]
    }

    func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    // MARK: File actions

    func open(_ urls: [URL]) { urls.forEach { NSWorkspace.shared.open($0) } }
    func showInFinder(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    func copy(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// Copies the text inside one or more images or PDFs.
    func copyText(_ items: [FileItem]) {
        let readable = items.filter { $0.category == .images || $0.ext == "pdf" }
        guard !readable.isEmpty else { toast("Select an image or PDF to copy its text"); return }
        Task {
            var parts: [String] = []
            for i in readable { let t = await TextIndex.shared.extract(i); if !t.isEmpty { parts.append(t) } }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(parts.joined(separator: "\n\n"), forType: .string)
            toast(parts.isEmpty ? "No text found" : "Copied text from \(parts.count) file\(parts.count == 1 ? "" : "s")")
        }
    }
}

/// Async, cached QuickLook thumbnails. iCloud-only files get their icon so nothing is downloaded.
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 2_000 }

    func image(for item: FileItem, size: CGFloat) async -> NSImage {
        let key = "\(item.url.path)#\(Int(size))#\(item.modified.timeIntervalSince1970)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var image = NSWorkspace.shared.icon(forFile: item.url.path)
        if !item.isCloudOnly && !item.isFolder {
            let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                image = rep.nsImage
            }
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Plays songs right in the toolbar.
@MainActor
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = Player()
    @Published private(set) var current: FileItem?
    @Published private(set) var isPlaying = false
    private var queue: [FileItem] = []
    private var player: AVAudioPlayer?

    func play(_ item: FileItem, in list: [FileItem]) {
        queue = list.filter { $0.category == .music }
        guard let p = try? AVAudioPlayer(contentsOf: item.url) else {
            AppState.shared.toast("Can't play \(item.name)"); return
        }
        player?.stop()
        player = p
        p.delegate = self
        p.play()
        current = item
        isPlaying = true
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { player.pause() } else { player.play() }
        isPlaying = player.isPlaying
    }

    func skip(_ step: Int) {
        guard let current, let i = queue.firstIndex(of: current), !queue.isEmpty else { return }
        play(queue[(i + step + queue.count) % queue.count], in: queue)
    }

    func stop() { player?.stop(); player = nil; current = nil; isPlaying = false }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.skip(1) }
    }
}

/// System-wide hotkey for Quick Search (Carbon hotkeys need no Accessibility permission).
enum QuickSearchShortcut: String, CaseIterable, Identifiable {
    case shiftCmdSpace, optSpace, ctrlOptSpace, optCmdF
    var id: String { rawValue }
    var label: String {
        switch self {
        case .shiftCmdSpace: "⇧⌘Space"
        case .optSpace: "⌥Space"
        case .ctrlOptSpace: "⌃⌥Space"
        case .optCmdF: "⌥⌘F"
        }
    }
    var keyCode: UInt32 { self == .optCmdF ? UInt32(kVK_ANSI_F) : UInt32(kVK_Space) }
    var modifiers: UInt32 {
        switch self {
        case .shiftCmdSpace: UInt32(cmdKey | shiftKey)
        case .optSpace: UInt32(optionKey)
        case .ctrlOptSpace: UInt32(controlKey | optionKey)
        case .optCmdF: UInt32(cmdKey | optionKey)
        }
    }
}

final class HotKey {
    static let shared = HotKey()
    private var ref: EventHotKeyRef?
    private var installed = false
    var action: (() -> Void)?

    func register(_ shortcut: QuickSearchShortcut) {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.shared.action?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        let id = EventHotKeyID(signature: OSType(0x4746_4E44), id: 1)
        RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}
