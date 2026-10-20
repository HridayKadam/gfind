import Foundation

/// A plain-English search turned into filters the user can see and remove.
struct Query: Equatable {
    struct Chip: Identifiable, Hashable {
        let id: String
        let label: String
        let symbol: String
    }

    var categories: Set<Category> = []
    var extensions: Set<String> = []
    var screenshots = false
    var iphone = false
    var after: Date?
    var before: Date?
    var dateLabel: String?
    var minSize: Int64?
    var maxSize: Int64?
    var source: String?
    var terms: [String] = []

    var isEmpty: Bool { chips.isEmpty }

    var chips: [Chip] {
        var out: [Chip] = []
        for c in Category.allCases where categories.contains(c) { out.append(.init(id: "cat.\(c.rawValue)", label: c.title, symbol: c.symbol)) }
        for e in extensions.sorted() { out.append(.init(id: "ext.\(e)", label: e.uppercased(), symbol: "doc")) }
        if screenshots { out.append(.init(id: "shots", label: "Screenshots", symbol: "camera.viewfinder")) }
        if iphone { out.append(.init(id: "iphone", label: "From iPhone", symbol: "iphone")) }
        if let dateLabel { out.append(.init(id: "date", label: dateLabel, symbol: "calendar")) }
        if let minSize { out.append(.init(id: "min", label: "Over \(Format.size(minSize))", symbol: "arrow.up.square")) }
        if let maxSize { out.append(.init(id: "max", label: "Under \(Format.size(maxSize))", symbol: "arrow.down.square")) }
        if let source { out.append(.init(id: "src", label: "From \(source)", symbol: DownloadSource.symbol(for: source))) }
        if !terms.isEmpty { out.append(.init(id: "terms", label: "“\(terms.joined(separator: " "))”", symbol: "text.magnifyingglass")) }
        return out
    }

    func removing(_ ids: Set<String>) -> Query {
        var q = self
        for id in ids {
            switch id {
            case "shots": q.screenshots = false
            case "iphone": q.iphone = false
            case "date": q.after = nil; q.before = nil; q.dateLabel = nil
            case "min": q.minSize = nil
            case "max": q.maxSize = nil
            case "src": q.source = nil
            case "terms": q.terms = []
            default:
                if id.hasPrefix("cat."), let c = Category(rawValue: String(id.dropFirst(4))) { q.categories.remove(c) }
                if id.hasPrefix("ext.") { q.extensions.remove(String(id.dropFirst(4))) }
            }
        }
        return q
    }

    @MainActor
    func matches(_ item: FileItem, text: TextIndex) -> Bool {
        if !categories.isEmpty || !extensions.isEmpty || screenshots {
            let byCategory = item.category.map(categories.contains) ?? false
            let byExt = extensions.contains(item.ext)
            let byShot = screenshots && item.isScreenshot
            if !(byCategory || byExt || byShot) { return false }
        }
        if iphone && !(item.name.hasPrefix("IMG_") || item.ext == "heic" || item.ext == "mov" && item.name.hasPrefix("IMG")) { return false }
        if let after, item.date < after { return false }
        if let before, item.date >= before { return false }
        if let minSize, item.size < minSize { return false }
        if let maxSize, item.size > maxSize { return false }
        if let source, item.source?.caseInsensitiveCompare(source) != .orderedSame { return false }
        if !terms.isEmpty {
            let name = item.searchName
            let body = text.normalizedText(for: item) ?? ""
            let froms = item.whereFroms.joined(separator: " ").lowercased()
            for t in terms where !(name.contains(t) || body.contains(t) || froms.contains(t)) { return false }
        }
        return true
    }
}

enum QueryParser {
    static let kindWords: [String: Category] = [
        "image": .images, "images": .images, "photo": .images, "photos": .images, "picture": .images,
        "pictures": .images, "pics": .images, "pic": .images,
        "video": .videos, "videos": .videos, "movie": .videos, "movies": .videos, "clip": .videos, "clips": .videos,
        "recording": .videos, "recordings": .videos,
        "music": .music, "song": .music, "songs": .music, "audio": .music, "track": .music, "tracks": .music,
        "doc": .documents, "docs": .documents, "document": .documents, "documents": .documents,
        "archive": .archives, "archives": .archives, "app": .apps, "apps": .apps, "application": .apps, "applications": .apps,
    ]
    static let extWords: [String: [String]] = [
        "installer": ["dmg", "pkg"], "installers": ["dmg", "pkg"],
        "spreadsheet": ["xls", "xlsx", "csv", "numbers"], "spreadsheets": ["xls", "xlsx", "csv", "numbers"], "excel": ["xls", "xlsx"],
        "presentation": ["ppt", "pptx", "key"], "presentations": ["ppt", "pptx", "key"], "slides": ["ppt", "pptx", "key"],
        "keynote": ["key"], "word": ["doc", "docx"], "ebook": ["epub"], "ebooks": ["epub"],
        "gif": ["gif"], "gifs": ["gif"],
    ]
    static let knownExtensions: Set<String> = Category.documentExtensions.union(Category.archiveExtensions).union([
        "png", "jpg", "jpeg", "heic", "gif", "webp", "svg", "tiff", "psd", "mp4", "mov", "mkv", "avi", "webm",
        "mp3", "m4a", "wav", "flac", "aac", "aiff",
    ])
    static let stopWords: Set<String> = [
        "from", "with", "the", "my", "in", "of", "and", "that", "a", "an", "all", "file", "files", "show", "me",
        "find", "containing", "contains", "about", "on", "for", "to", "which", "where", "i", "got", "downloaded", "saved",
    ]
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                         "october", "november", "december"]

    static func parse(_ input: String, now: Date = .now) -> Query {
        var q = Query()
        let cal = Calendar.current
        var words = input.lowercased()
            .replacingOccurrences(of: "“", with: "").replacingOccurrences(of: "”", with: "")
            .components(separatedBy: CharacterSet.whitespaces.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: ".-"))))
            .filter { !$0.isEmpty }
        var i = 0
        var consumed = Set<Int>()

        func word(_ k: Int) -> String? { k < words.count ? words[k] : nil }
        func take(_ ks: Int...) { ks.forEach { consumed.insert($0) } }
        func startOf(_ comp: Calendar.Component, _ d: Date) -> Date { cal.dateInterval(of: comp, for: d)?.start ?? d }

        func setRange(_ comp: Calendar.Component, offset: Int, label: String) {
            let base = cal.date(byAdding: comp, value: offset, to: now) ?? now
            guard let iv = cal.dateInterval(of: comp, for: base) else { return }
            q.after = iv.start; q.before = offset == 0 ? nil : iv.end; q.dateLabel = label
        }

        func number(_ s: String) -> Double? {
            let digits = s.prefix { $0.isNumber || $0 == "." }
            return Double(digits)
        }

        func unit(_ s: String) -> Int64? {
            switch s {
            case "kb", "k": 1_000
            case "mb", "m", "megs", "meg": 1_000_000
            case "gb", "g", "gigs", "gig": 1_000_000_000
            case "tb": 1_000_000_000_000
            default: nil
            }
        }

        /// Reads "5 mb" or "5mb" starting at k. Returns bytes and how many words it used.
        func sizeAt(_ k: Int) -> (Int64, Int)? {
            guard let w = word(k), let n = number(w) else { return nil }
            let suffix = String(w.drop { $0.isNumber || $0 == "." })
            if let u = unit(suffix) { return (Int64(n * Double(u)), 1) }
            if suffix.isEmpty, let next = word(k + 1), let u = unit(next) { return (Int64(n * Double(u)), 2) }
            return nil
        }

        func durationAt(_ k: Int) -> (Calendar.Component, Int, Int)? {
            var n = 1, used = 0
            if let w = word(k), let v = Int(w) { n = v; used = 1 }
            else if word(k) == "a" || word(k) == "one" { used = 1 }
            guard let u = word(k + used) else { return nil }
            let comp: Calendar.Component
            switch u {
            case "day", "days": comp = .day
            case "week", "weeks": comp = .weekOfYear
            case "month", "months": comp = .month
            case "year", "years": comp = .year
            default: return nil
            }
            return (comp, n, used + 1)
        }

        while i < words.count {
            let w = words[i]
            defer { i += 1 }
            if consumed.contains(i) { continue }

            // Kinds
            if w == "screenshot" || w == "screenshots" { q.screenshots = true; take(i); continue }
            if w == "pdf" || w == "pdfs" { q.extensions.insert("pdf"); take(i); continue }
            if let c = kindWords[w] { q.categories.insert(c); take(i); continue }
            if let e = extWords[w] { q.extensions.formUnion(e); take(i); continue }
            let bare = w.hasPrefix(".") ? String(w.dropFirst()) : w
            let singular = bare.hasSuffix("s") ? String(bare.dropLast()) : bare
            if knownExtensions.contains(bare) || knownExtensions.contains(singular) {
                q.extensions.insert(knownExtensions.contains(bare) ? bare : singular); take(i); continue
            }

            // Dates
            switch w {
            case "today": setRange(.day, offset: 0, label: "Today"); take(i); continue
            case "yesterday": setRange(.day, offset: -1, label: "Yesterday"); take(i); continue
            case "recent", "recently", "new", "newest", "latest":
                q.after = cal.date(byAdding: .day, value: -7, to: now); q.dateLabel = "Last 7 days"; take(i); continue
            default: break
            }
            if (w == "this" || w == "last" || w == "past") {
                if let next = word(i + 1), ["week", "month", "year"].contains(next) {
                    let comp: Calendar.Component = next == "week" ? .weekOfYear : next == "month" ? .month : .year
                    setRange(comp, offset: w == "this" ? 0 : -1, label: "\(w.capitalized) \(next)")
                    take(i, i + 1); continue
                }
                if let (comp, n, used) = durationAt(i + 1), n > 0 {
                    q.after = cal.date(byAdding: comp, value: -n, to: now); q.before = nil
                    q.dateLabel = "Last \(n) \(words[i + used])"
                    for k in i...(i + used) { take(k) }
                    continue
                }
            }
            if let m = months.firstIndex(where: { $0 == w || ($0.prefix(3) == w && w.count == 3 && w != "may") }) ?? (w == "may" ? 4 : nil) {
                var comps = cal.dateComponents([.year], from: now)
                comps.month = m + 1; comps.day = 1
                if var start = cal.date(from: comps) {
                    if start > now { start = cal.date(byAdding: .year, value: -1, to: start) ?? start }
                    q.after = start; q.before = cal.date(byAdding: .month, value: 1, to: start)
                    q.dateLabel = months[m].capitalized
                    take(i); continue
                }
            }
            if w == "older" || w == "newer" {
                var k = i + 1
                if word(k) == "than" { k += 1 }
                if let (comp, n, used) = durationAt(k) {
                    let d = cal.date(byAdding: comp, value: -n, to: now)
                    let unitWord = words[k + used - 1]
                    if w == "older" { q.before = d; q.after = nil; q.dateLabel = "Older than \(n) \(unitWord)" }
                    else { q.after = d; q.before = nil; q.dateLabel = "Last \(n) \(unitWord)" }
                    for j in i..<(k + used) { take(j) }
                    continue
                }
            }

            // Sizes
            let bigger = ["over", "above", "bigger", "larger", "more", "greater", ">", "min"]
            let smaller = ["under", "below", "smaller", "less", "<", "max"]
            if bigger.contains(w) || smaller.contains(w) {
                var k = i + 1
                if word(k) == "than" { k += 1 }
                if let (bytes, used) = sizeAt(k) {
                    if bigger.contains(w) { q.minSize = bytes } else { q.maxSize = bytes }
                    for j in i..<(k + used) { take(j) }
                    continue
                }
            }
            if w == "big" || w == "large" || w == "huge" { q.minSize = q.minSize ?? 100_000_000; take(i); continue }

            // Sources
            if w == "iphone" || w == "phone" { q.iphone = true; take(i); continue }
            if i > 0, words[i - 1] == "from" || words[i - 1] == "via" {
                if let rule = DownloadSource.rules.first(where: { $0.name.lowercased() == w || $0.name.lowercased().replacingOccurrences(of: " ", with: "") == w }) {
                    q.source = rule.name; take(i); continue
                }
                if w == "google", word(i + 1) == "drive" { q.source = "Google Drive"; take(i, i + 1); continue }
                if w == "twitter" { q.source = "X"; take(i); continue }
            }
        }

        words = words.enumerated().filter { !consumed.contains($0.offset) }.map(\.element)
        q.terms = words.filter { !stopWords.contains($0) && !$0.allSatisfy(\.isPunctuation) }
            .map { TextIndex.normalize($0) }
        return q
    }
}
