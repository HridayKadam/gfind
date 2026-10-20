import SwiftUI
import CryptoKit
import Foundation
import Vision

struct DuplicateGroup: Identifiable, Hashable {
    enum Kind { case identical, lookalike }
    let id = UUID()
    let kind: Kind
    var items: [FileItem]
    var keep: URL

    var reclaimable: Int64 { items.filter { $0.url != keep }.totalSize }
    var extras: [FileItem] { items.filter { $0.url != keep } }
}

/// Finds identical files by SHA-256 and look-alike photos by Vision feature prints.
enum DuplicateFinder {
    static func find(_ all: [FileItem], progress: @escaping (String) -> Void) -> [DuplicateGroup] {
        let candidates = all.filter { !$0.isCloudOnly && $0.size >= 4_096 && $0.category != .apps }

        // 1. Same size → same first 64 KB → same full SHA-256.
        var groups: [DuplicateGroup] = []
        let bySize = Dictionary(grouping: candidates, by: \.size).values.filter { $0.count > 1 }
        var done = 0
        for sameSize in bySize {
            done += 1
            if done % 50 == 0 { progress("Comparing files… \(done)/\(bySize.count)") }
            let byHead = Dictionary(grouping: sameSize) { hash($0.url, limit: 65_536) ?? UUID().uuidString }.values.filter { $0.count > 1 }
            for sameHead in byHead {
                let byFull = sameSize.first!.size <= 65_536
                    ? [sameHead]
                    : Array(Dictionary(grouping: sameHead) { hash($0.url, limit: nil) ?? UUID().uuidString }.values)
                for g in byFull where g.count > 1 {
                    let keep = g.min { ($0.created, $0.url.path.count) < ($1.created, $1.url.path.count) }!
                    groups.append(DuplicateGroup(kind: .identical, items: g, keep: keep.url))
                }
            }
        }

        // 2. Look-alike photos: bursts, edits, HEIC/JPEG pairs.
        let exact = Set(groups.flatMap { $0.items.map(\.url) })
        let photos = candidates.filter { $0.category == .images && !exact.contains($0.url) && !$0.isScreenshot && $0.ext != "svg" }
            .sorted { $0.date > $1.date }.prefix(1500)
        var prints: [(FileItem, VNFeaturePrintObservation)] = []
        for (n, item) in photos.enumerated() {
            if n % 40 == 0 { progress("Looking at photos… \(n)/\(photos.count)") }
            if let p = featurePrint(item.url) { prints.append((item, p)) }
        }
        let threshold: Float = (prints.first?.1.requestRevision ?? 2) >= 2 ? 0.3 : 10
        var parent = Array(prints.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for a in prints.indices {
            for b in (a + 1)..<prints.count {
                var d: Float = 0
                if (try? prints[a].1.computeDistance(&d, to: prints[b].1)) != nil, d < threshold {
                    parent[root(a)] = root(b)
                }
            }
        }
        for members in Dictionary(grouping: prints.indices, by: root).values where members.count > 1 {
            let items = members.map { prints[$0].0 }
            let keep = items.max { $0.size < $1.size }!
            groups.append(DuplicateGroup(kind: .lookalike, items: items, keep: keep.url))
        }

        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    static func hash(_ url: URL, limit: Int?) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        var read = 0
        while true {
            let chunk = (try? h.read(upToCount: 1 << 20)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            sha.update(data: chunk)
            read += chunk.count
            if let limit, read >= limit { break }
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func featurePrint(_ url: URL) -> VNFeaturePrintObservation? {
        guard let cg = TextIndex.cgImage(url, maxPixels: 512) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        return request.results?.first
    }
}

/// The Clean Up cards shown on Home and in Clean Up.
struct CleanUpCard: Identifiable {
    enum Kind: String, CaseIterable {
        case duplicates, forgottenDownloads, oldInstallers, oldScreenshots, bigOldVideos, unusedApps
    }
    let kind: Kind
    let items: [FileItem]
    var id: Kind { kind }
    var size: Int64 { items.totalSize }

    var title: String {
        switch kind {
        case .duplicates: "Duplicates & look-alikes"
        case .forgottenDownloads: "Forgotten downloads"
        case .oldInstallers: "Old installers (.dmg, .pkg)"
        case .oldScreenshots: "Old screenshots"
        case .bigOldVideos: "Big old videos"
        case .unusedApps: "Unused apps"
        }
    }

    var detail: String {
        switch kind {
        case .duplicates: "Extra copies of the same file, and near-identical photos."
        case .forgottenDownloads: "Downloads you haven't opened in over two months."
        case .oldInstallers: "Disk images and installer packages older than a week."
        case .oldScreenshots: "Screenshots older than a month."
        case .bigOldVideos: "Videos over 200 MB you haven't touched in six months."
        case .unusedApps: "Apps you haven't opened in three months."
        }
    }

    var symbol: String {
        switch kind {
        case .duplicates: "square.on.square"
        case .forgottenDownloads: "arrow.down.circle"
        case .oldInstallers: "shippingbox"
        case .oldScreenshots: "camera.viewfinder"
        case .bigOldVideos: "film.stack"
        case .unusedApps: "app.dashed"
        }
    }

    var tint: Color {
        switch kind {
        case .duplicates: .purple
        case .forgottenDownloads: .blue
        case .oldInstallers: .orange
        case .oldScreenshots: .pink
        case .bigOldVideos: .indigo
        case .unusedApps: .green
        }
    }

    static func build(items: [FileItem], duplicates: [DuplicateGroup], now: Date = .now) -> [CleanUpCard] {
        let day: TimeInterval = 86_400
        let installers = items.filter { $0.isInstaller && $0.date < now - 7 * day }
        let installerSet = Set(installers.map(\.url))
        let forgotten = items.filter {
            $0.isInDownloads && !installerSet.contains($0.url) && $0.category != .apps
                && $0.date < now - 60 * day && ($0.lastOpened ?? $0.date) < now - 60 * day
        }
        let shots = items.filter { $0.isScreenshot && $0.category == .images && $0.date < now - 30 * day }
        let videos = items.filter { $0.category == .videos && $0.size > 200_000_000 && $0.modified < now - 180 * day }
        let apps = items.filter {
            $0.category == .apps && !($0.bundleID ?? "").hasPrefix("com.apple.") && $0.bundleID != Bundle.main.bundleIdentifier
                && ($0.lastOpened ?? $0.date) < now - 90 * day
        }
        return [
            CleanUpCard(kind: .duplicates, items: duplicates.flatMap(\.extras)),
            CleanUpCard(kind: .forgottenDownloads, items: forgotten),
            CleanUpCard(kind: .oldInstallers, items: installers),
            CleanUpCard(kind: .oldScreenshots, items: shots),
            CleanUpCard(kind: .bigOldVideos, items: videos),
            CleanUpCard(kind: .unusedApps, items: apps),
        ].map { CleanUpCard(kind: $0.kind, items: $0.items.filter { !$0.isCloudOnly }.sorted { $0.size > $1.size }) }
    }
}

