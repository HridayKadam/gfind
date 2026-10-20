import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Category: String, CaseIterable, Identifiable, Codable {
    case images, videos, music, documents, archives, apps

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .images: "photo.on.rectangle"
        case .videos: "film"
        case .music: "music.note"
        case .documents: "doc.text"
        case .archives: "archivebox"
        case .apps: "square.grid.2x2"
        }
    }

    var tint: Color {
        switch self {
        case .images: Color(red: 0.98, green: 0.45, blue: 0.55)
        case .videos: Color(red: 0.55, green: 0.45, blue: 0.98)
        case .music: Color(red: 0.98, green: 0.62, blue: 0.25)
        case .documents: Color(red: 0.25, green: 0.62, blue: 0.98)
        case .archives: Color(red: 0.85, green: 0.72, blue: 0.25)
        case .apps: Color(red: 0.30, green: 0.78, blue: 0.55)
        }
    }

    static let documentExtensions: Set<String> = [
        "pdf", "txt", "md", "rtf", "rtfd", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx",
        "csv", "ppt", "pptx", "odt", "ods", "odp", "epub", "tex",
    ]
    static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "pkg", "xip", "iso",
    ]

    static func of(type: UTType?, ext: String) -> Category? {
        if ext == "app" { return .apps }
        if documentExtensions.contains(ext) { return .documents }
        if archiveExtensions.contains(ext) { return .archives }
        guard let type else { return nil }
        if type.conforms(to: .applicationBundle) { return .apps }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .videos }
        if type.conforms(to: .audio) { return .music }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archives }
        return nil
    }
}

struct FileItem: Identifiable, Hashable, Codable {
    let url: URL
    var id: URL { url }
    let name: String
    let ext: String
    var size: Int64
    let created: Date
    let modified: Date
    let added: Date?
    let lastOpened: Date?
    let category: Category?
    let typeName: String
    let isScreenshot: Bool
    let whereFroms: [String]
    let source: String?
    let isCloudOnly: Bool
    let isFolder: Bool
    let bundleID: String?
    /// Lower-cased, hyphen-free name, precomputed so search doesn't redo it per keystroke.
    var searchName = ""

    /// The date people think of as "when I got this file".
    var date: Date { added ?? created }
    var isInDownloads: Bool { url.path.hasPrefix(Paths.downloadsPrefix) }
    var isInstaller: Bool { ext == "dmg" || ext == "pkg" }

    static func == (a: FileItem, b: FileItem) -> Bool { a.url == b.url && a.size == b.size && a.modified == b.modified }
    func hash(into h: inout Hasher) { h.combine(url) }
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let desktop = home.appendingPathComponent("Desktop")
    static let documents = home.appendingPathComponent("Documents")
    static let downloads = home.appendingPathComponent("Downloads")
    static let downloadsPrefix = downloads.path + "/"
    static let pictures = home.appendingPathComponent("Pictures")
    static let movies = home.appendingPathComponent("Movies")
    static let music = home.appendingPathComponent("Music")
    static let applications = URL(fileURLWithPath: "/Applications")
    static let userApplications = home.appendingPathComponent("Applications")

    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GFind", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum Format {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }

    static func date(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }

    static func relative(_ d: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: d, relativeTo: .now)
    }
}

enum Look: String, CaseIterable, Identifiable {
    case playful, minimal
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

extension Category {
    func cardBackground(_ look: Look) -> Color {
        look == .playful ? tint.opacity(0.16) : Color.primary.opacity(0.05)
    }

    func iconColor(_ look: Look) -> Color {
        look == .playful ? tint : .primary.opacity(0.7)
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case date, name, size, kind
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ViewMode: String { case grid, list }

enum Destination: Hashable {
    case home
    case recents
    case category(Category)
    case screenshots
    case largeFiles
    case downloadedFrom(String?)
    case duplicates
    case cleanUp
    case saved(String)
    case folder(URL)

    var title: String {
        switch self {
        case .home: "Home"
        case .recents: "Recents"
        case .category(let c): c.title
        case .screenshots: "Screenshots"
        case .largeFiles: "Large Files"
        case .downloadedFrom(let s): s ?? "Downloaded From"
        case .duplicates: "Duplicates"
        case .cleanUp: "Clean Up"
        case .saved(let q): q
        case .folder(let u): FileManager.default.displayName(atPath: u.path)
        }
    }
}

extension Array where Element == FileItem {
    func sorted(by key: SortKey, ascending: Bool) -> [FileItem] {
        let s: [FileItem]
        switch key {
        case .date: s = sorted { $0.date > $1.date }
        case .name: s = sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: s = sorted { $0.size > $1.size }
        case .kind: s = sorted { ($0.typeName, $0.name) < ($1.typeName, $1.name) }
        }
        let defaultAscending = key == .name || key == .kind
        return ascending == defaultAscending ? s : s.reversed()
    }

    var totalSize: Int64 { reduce(0) { $0 + $1.size } }
}
