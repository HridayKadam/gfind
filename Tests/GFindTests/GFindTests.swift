import AppKit
import XCTest
@testable import GFind

final class QueryParserTests: XCTestCase {
    private func labels(_ q: String) -> [String] { QueryParser.parse(q).chips.map(\.label) }

    func testExamplesFromTheSite() {
        XCTAssertEqual(labels("pdfs from last week over 5 mb"), ["PDF", "Last week", "Over 5 MB"])
        XCTAssertEqual(labels("videos from my iphone in august"), ["Videos", "From iPhone", "August"])
        XCTAssertEqual(labels("screenshots with wifi password"), ["Screenshots", "“wifi password”"])
        XCTAssertEqual(labels("pdfs from gmail"), ["PDF", "From Gmail"])
    }

    func testSizesAndAges() {
        let q = QueryParser.parse("zips bigger than 1gb older than 6 months")
        XCTAssertEqual(q.extensions, ["zip"])
        XCTAssertEqual(q.minSize, 1_000_000_000)
        XCTAssertNotNil(q.before)
        XCTAssertNil(q.after)
        XCTAssertEqual(QueryParser.parse("png under 500kb").maxSize, 500_000)
        XCTAssertEqual(QueryParser.parse("big videos").minSize, 100_000_000)
    }

    func testMonthIsMostRecentPastOne() {
        let now = DateComponents(calendar: .current, year: 2026, month: 3, day: 10).date!
        let q = QueryParser.parse("photos in august", now: now)
        XCTAssertEqual(Calendar.current.component(.year, from: q.after!), 2025)
        XCTAssertEqual(Calendar.current.component(.month, from: q.after!), 8)
    }

    func testRemovingChips() {
        let q = QueryParser.parse("pdfs from gmail last week").removing(["src", "date"])
        XCTAssertNil(q.source)
        XCTAssertNil(q.after)
        XCTAssertEqual(q.extensions, ["pdf"])
    }

    func testPlainWordsBecomeTerms() {
        XCTAssertEqual(QueryParser.parse("invoice from slack").terms, ["invoice"])
        XCTAssertEqual(QueryParser.parse("Wi-Fi").terms, ["wifi"])
    }
}

final class SourceTests: XCTestCase {
    func testNamedSources() {
        XCTAssertEqual(DownloadSource.name(for: ["https://mail-attachment.googleusercontent.com/x", "https://mail.google.com/"]), "Gmail")
        XCTAssertEqual(DownloadSource.name(for: ["https://files.oaiusercontent.com/file-1"]), "ChatGPT")
        XCTAssertEqual(DownloadSource.name(for: ["https://pbs.twimg.com/media/a.jpg"]), "X")
        XCTAssertEqual(DownloadSource.name(for: ["chrome-extension://abc/page.html"]), "Extensions")
    }

    func testFallsBackToHost() {
        XCTAssertEqual(DownloadSource.name(for: ["https://www.example.com/file.zip"]), "example.com")
        XCTAssertNil(DownloadSource.name(for: []))
    }
}

final class CategoryTests: XCTestCase {
    func testCategories() {
        XCTAssertEqual(GFind.Category.of(type: .png, ext: "png"), .images)
        XCTAssertEqual(GFind.Category.of(type: .mpeg4Movie, ext: "mp4"), .videos)
        XCTAssertEqual(GFind.Category.of(type: .mp3, ext: "mp3"), .music)
        XCTAssertEqual(GFind.Category.of(type: nil, ext: "docx"), .documents)
        XCTAssertEqual(GFind.Category.of(type: nil, ext: "dmg"), .archives)
        XCTAssertNil(GFind.Category.of(type: .swiftSource, ext: "swift"))
    }
}

final class FileTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gfind-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ bytes: Data) throws -> FileItem {
        let u = dir.appendingPathComponent(name)
        try bytes.write(to: u)
        return try XCTUnwrap(Scanner.makeItem(u, nil, includeUncategorized: true))
    }

    func testIdenticalFilesAreGroupedAndOneIsKept() throws {
        let blob = Data((0..<200_000).map { UInt8($0 % 251) })
        var other = blob; other[150_000] ^= 0xFF   // same size and same first 64 KB, different content
        let a = try write("a.pdf", blob), b = try write("b.pdf", blob), c = try write("c.pdf", other)
        let groups = DuplicateFinder.find([a, b, c]) { _ in }.filter { $0.kind == .identical }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].items.map(\.name)), ["a.pdf", "b.pdf"])
        XCTAssertEqual(groups[0].extras.count, 1)
        XCTAssertEqual(groups[0].reclaimable, 200_000)
    }

    func testImageConversionShrinks() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let src = dir.appendingPathComponent("pic.png")
        try png.write(to: src)
        let out = try ImageConverter.convert(src, to: .jpeg, quality: 0.5, maxPixels: 600)
        XCTAssertEqual(out.pathExtension, "jpg")
        let img = try XCTUnwrap(NSImage(contentsOf: out)?.representations.first)
        XCTAssertEqual(max(img.pixelsWide, img.pixelsHigh), 600)
        // Converting again must not overwrite the first result.
        let second = try ImageConverter.convert(src, to: .jpeg, quality: 0.5, maxPixels: 600)
        XCTAssertNotEqual(out, second)
    }
}

final class CleanUpTests: XCTestCase {
    private func item(_ name: String, size: Int64, daysOld: Double, category: GFind.Category?, screenshot: Bool = false,
                      inDownloads: Bool = false) -> FileItem {
        let date = Date.now.addingTimeInterval(-daysOld * 86_400)
        let base = inDownloads ? Paths.downloads : URL(fileURLWithPath: "/tmp")
        return FileItem(url: base.appendingPathComponent(name), name: name, ext: (name as NSString).pathExtension, size: size,
                        created: date, modified: date, added: date, lastOpened: nil, category: category, typeName: "",
                        isScreenshot: screenshot, whereFroms: [], source: nil, isCloudOnly: false, isFolder: false, bundleID: nil)
    }

    func testCards() {
        let items = [
            item("old.dmg", size: 100, daysOld: 30, category: .archives, inDownloads: true),
            item("new.dmg", size: 100, daysOld: 1, category: .archives, inDownloads: true),
            item("Screenshot 1.png", size: 10, daysOld: 40, category: .images, screenshot: true),
            item("Screenshot 2.png", size: 10, daysOld: 2, category: .images, screenshot: true),
            item("film.mov", size: 300_000_000, daysOld: 400, category: .videos),
            item("report.pdf", size: 5, daysOld: 90, category: .documents, inDownloads: true),
        ]
        let cards = Dictionary(uniqueKeysWithValues: CleanUpCard.build(items: items, duplicates: []).map { ($0.kind, $0.items.map(\.name)) })
        XCTAssertEqual(cards[.oldInstallers], ["old.dmg"])
        XCTAssertEqual(cards[.oldScreenshots], ["Screenshot 1.png"])
        XCTAssertEqual(cards[.bigOldVideos], ["film.mov"])
        XCTAssertEqual(cards[.forgottenDownloads], ["report.pdf"])
    }
}

final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(Updater.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertTrue(Updater.isNewer("1.10", than: "1.9.9"))
        XCTAssertFalse(Updater.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("0.9", than: "1.0"))
    }
}
