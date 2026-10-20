import AppKit
import CoreServices
import UniformTypeIdentifiers

/// Walks the user's folders and turns files into `FileItem`s. Runs off the main thread.
enum Scanner {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey,
        .contentModificationDateKey, .addedToDirectoryDateKey, .contentAccessDateKey, .contentTypeKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .localizedTypeDescriptionKey,
    ]
    static let keySet = Set(keys)

    /// Folders that are never "your stuff".
    static let skippedFolders: Set<String> = [
        "node_modules", "DerivedData", "Pods", "venv", ".venv", "__pycache__", "Library",
        "Photos Library.photoslibrary", "Music Library.musiclibrary",
    ]

    static var roots: [URL] {
        [Paths.desktop, Paths.documents, Paths.downloads, Paths.pictures, Paths.movies, Paths.music,
         Paths.applications, Paths.userApplications]
    }

    static func scan(limit: Int = 300_000) -> [FileItem] {
        var out: [FileItem] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for root in roots where fm.fileExists(atPath: root.path) {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in en {
                if out.count >= limit { return out }
                guard let v = try? url.resourceValues(forKeys: keySet), v.isSymbolicLink != true else { continue }
                if v.isDirectory == true && v.isPackage != true {
                    // Code checkouts and build folders are not documents.
                    if skippedFolders.contains(url.lastPathComponent)
                        || fm.fileExists(atPath: url.appendingPathComponent(".git").path) {
                        en.skipDescendants()
                    }
                    continue
                }
                guard seen.insert(url.path).inserted, let item = makeItem(url, v) else { continue }
                out.append(item)
            }
        }
        return out
    }

    static func makeItem(_ url: URL, _ v: URLResourceValues? = nil, includeUncategorized: Bool = false) -> FileItem? {
        guard let v = v ?? (try? url.resourceValues(forKeys: keySet)) else { return nil }
        let ext = url.pathExtension.lowercased()
        let isFolder = v.isDirectory == true && v.isPackage != true
        let category = isFolder ? nil : Category.of(type: v.contentType, ext: ext)
        if category == nil && !includeUncategorized { return nil }

        let name = url.lastPathComponent
        let isApp = category == .apps
        let cloudOnly = v.isUbiquitousItem == true && v.ubiquitousItemDownloadingStatus != .current
        let froms = isApp || isFolder ? [] : whereFroms(url)
        let screenshot = !isFolder && (name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot")
            || name.hasPrefix("CleanShot") || hasXattr(url, "com.apple.metadata:kMDItemIsScreenCapture"))

        var lastOpened = v.contentAccessDate
        if isApp || url.path.hasPrefix(Paths.downloads.path) { lastOpened = spotlightLastUsed(url) }

        var item = FileItem(
            url: url, name: name, ext: ext, size: Int64(v.fileSize ?? 0),
            created: v.creationDate ?? .distantPast, modified: v.contentModificationDate ?? .distantPast,
            added: v.addedToDirectoryDate, lastOpened: lastOpened, category: category,
            typeName: isFolder ? "Folder" : (v.localizedTypeDescription ?? ext.uppercased()),
            isScreenshot: screenshot && category == .images || name.hasPrefix("Screen Recording"),
            whereFroms: froms, source: DownloadSource.name(for: froms), isCloudOnly: cloudOnly,
            isFolder: isFolder, bundleID: isApp ? Bundle(url: url)?.bundleIdentifier : nil)
        item.searchName = TextIndex.normalize(name)
        return item
    }

    /// Lists one folder, including subfolders and files GFind doesn't categorise.
    static func contents(of folder: URL) -> [FileItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { makeItem($0, nil, includeUncategorized: true) }
    }

    // MARK: - Metadata helpers

    static func whereFroms(_ url: URL) -> [String] {
        let attr = "com.apple.metadata:kMDItemWhereFroms"
        let len = getxattr(url.path, attr, nil, 0, 0, 0)
        guard len > 0 else { return [] }
        var data = Data(count: len)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, attr, $0.baseAddress, len, 0, 0) }
        guard read > 0 else { return [] }
        let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        return (list ?? []).filter { !$0.isEmpty }
    }

    static func hasXattr(_ url: URL, _ name: String) -> Bool {
        getxattr(url.path, name, nil, 0, 0, 0) >= 0
    }

    static func spotlightLastUsed(_ url: URL) -> Date? {
        guard let md = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(md, kMDItemLastUsedDate) as? Date
    }

    /// Size of a bundle on disk (apps are folders).
    static func directorySize(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                                      options: []) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

/// Maps a download's "Where from" URLs to a friendly source name.
enum DownloadSource {
    static let rules: [(name: String, symbol: String, needles: [String])] = [
        ("Gmail", "envelope", ["mail.google.com", "mail-attachment.googleusercontent.com"]),
        ("Google Drive", "externaldrive", ["drive.google.com", "drive.usercontent.google.com", "docs.google.com"]),
        ("ChatGPT", "bubble.left.and.text.bubble.right", ["chatgpt.com", "oaiusercontent.com", "openai.com"]),
        ("Claude", "sparkle", ["claude.ai", "anthropic.com"]),
        ("Canva", "paintpalette", ["canva.com"]),
        ("X", "at", ["//x.com", "twitter.com", "twimg.com"]),
        ("Slack", "number", ["slack.com", "slack-edge.com", "slack-files.com"]),
        ("WhatsApp", "phone.bubble", ["whatsapp.com", "whatsapp.net"]),
        ("Telegram", "paperplane", ["telegram.org", "//t.me"]),
        ("Discord", "gamecontroller", ["discord.com", "discordapp."]),
        ("GitHub", "chevron.left.forwardslash.chevron.right", ["github.com", "githubusercontent.com"]),
        ("Notion", "note.text", ["notion.so", "notion.site"]),
        ("Figma", "pencil.and.outline", ["figma.com"]),
        ("Dropbox", "shippingbox", ["dropbox.com", "dropboxusercontent.com"]),
        ("Extensions", "puzzlepiece.extension", ["chrome-extension://", "moz-extension://", "safari-web-extension://"]),
    ]

    static func name(for froms: [String]) -> String? {
        guard !froms.isEmpty else { return nil }
        let joined = froms.joined(separator: " ").lowercased()
        for rule in rules where rule.needles.contains(where: joined.contains) { return rule.name }
        for f in froms {
            if let host = URL(string: f)?.host?.lowercased() {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
        }
        return nil
    }

    static func symbol(for name: String) -> String {
        rules.first { $0.name == name }?.symbol ?? "globe"
    }

    static func isNamed(_ name: String) -> Bool { rules.contains { $0.name == name } }
}
