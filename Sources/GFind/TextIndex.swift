import AppKit
import PDFKit
import Vision

/// Text found inside images (via Vision) and documents, cached on disk and searched locally.
@MainActor
final class TextIndex: ObservableObject {
    static let shared = TextIndex()

    struct Entry: Codable { var mtime: Double; var text: String }

    @Published private(set) var indexedCount = 0
    @Published private(set) var isIndexing = false
    private var entries: [String: Entry] = [:]
    private var normalized: [String: String] = [:]
    private var job: Task<Void, Never>?
    private let file = Paths.support.appendingPathComponent("text-index.json")

    private init() {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
            for (k, v) in saved { normalized[k] = Self.normalize(v.text) }
            indexedCount = saved.count
        }
    }

    func text(for item: FileItem) -> String? { entries[item.url.path]?.text }
    func normalizedText(for item: FileItem) -> String? { normalized[item.url.path] }

    nonisolated static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "\n", with: " ")
    }

    /// Text for one file, recognising it now if it isn't cached yet.
    func extract(_ item: FileItem) async -> String {
        if let e = entries[item.url.path], e.mtime == item.modified.timeIntervalSince1970 { return e.text }
        let url = item.url, isPDF = item.ext == "pdf"
        let text = await Task.detached(priority: .userInitiated) {
            isPDF ? Self.pdfText(url) : Self.recognize(url)
        }.value ?? ""
        store(item, text)
        return text
    }

    private func store(_ item: FileItem, _ text: String) {
        entries[item.url.path] = Entry(mtime: item.modified.timeIntervalSince1970, text: text)
        normalized[item.url.path] = Self.normalize(text)
        indexedCount = entries.count
    }

    /// Indexes screenshots, recent photos and documents in the background, newest first.
    func index(_ items: [FileItem]) {
        guard UserDefaults.standard.object(forKey: "ocrEnabled") as? Bool ?? true else { return }
        let cutoff = Date.now.addingTimeInterval(-180 * 86_400)
        let todo = items.filter { item in
            guard !item.isCloudOnly, item.size < 60_000_000 else { return false }
            if let e = entries[item.url.path], e.mtime == item.modified.timeIntervalSince1970 { return false }
            if item.category == .images { return item.isScreenshot || item.date > cutoff }
            return ["pdf", "txt", "md", "rtf", "csv"].contains(item.ext)
        }
        .sorted { $0.date > $1.date }
        .prefix(4000)
        guard !todo.isEmpty else { return }

        job?.cancel()
        isIndexing = true
        job = Task { [weak self] in
            var sinceSave = 0
            for item in todo {
                if Task.isCancelled { break }
                let url = item.url, ext = item.ext
                let text = await Task.detached(priority: .utility) { () -> String? in
                    switch ext {
                    case "pdf": return Self.pdfText(url)
                    case "txt", "md", "csv": return (try? String(contentsOf: url, encoding: .utf8)).map { String($0.prefix(20_000)) }
                    case "rtf": return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
                    default: return Self.recognize(url)
                    }
                }.value
                self?.store(item, text ?? "")
                sinceSave += 1
                if sinceSave >= 25 { self?.save(); sinceSave = 0 }
            }
            self?.save()
            self?.isIndexing = false
        }
    }

    func save() {
        let snapshot = entries, file = file
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }
    }

    func forget(_ urls: [URL]) {
        for u in urls { entries[u.path] = nil; normalized[u.path] = nil }
        indexedCount = entries.count
    }

    nonisolated static func recognize(_ url: URL) -> String? {
        guard let cg = cgImage(url, maxPixels: 2400) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.joined(separator: "\n")
    }

    nonisolated static func pdfText(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var out = ""
        for i in 0..<min(doc.pageCount, 30) {
            out += (doc.page(at: i)?.string ?? "") + "\n"
            if out.count > 30_000 { break }
        }
        return out
    }

    nonisolated static func cgImage(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
