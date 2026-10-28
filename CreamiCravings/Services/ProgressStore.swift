import Foundation

/// A normalized point (0...1 across the photo width and height, origin top-left).
struct NormPoint: Codable, Hashable {
    var x: Double
    var y: Double
}

/// Hairline tracker marks on one photo: three hairline points (left temple peak, center, right temple peak) and two brow points.
struct HairlineMarks: Codable, Hashable {
    var hairline: [NormPoint]      // 3 points
    var brows: [NormPoint]         // 2 points (left brow, right brow)
}

/// One progress photo's details. Stored next to the JPEG as JSON; never uploaded.
struct ProgressEntry: Codable, Hashable, Identifiable {
    var id = UUID()
    var series: PhotoSeries
    var date: Date
    var note = ""
    var ratings: [String: Int] = [:]      // skin: breakouts / redness / oiliness (0...5); hair: shedding (0 low, 1 med, 2 high)
    var adherence: Double?                // share of the routine ticked that day (0...1)
    var marks: HairlineMarks?
    var metrics: PhotoMetrics?            // measured on the phone (see MetricsEngine); nil until analysed
    var fileName = ""                     // "<series>/<name>.jpg" relative to the progress folder

    enum CodingKeys: String, CodingKey { case id, series, date, note, ratings, adherence, marks, metrics, fileName }
    init(series: PhotoSeries, date: Date, note: String = "", ratings: [String: Int] = [:], adherence: Double? = nil, marks: HairlineMarks? = nil) {
        self.series = series; self.date = date; self.note = note; self.ratings = ratings; self.adherence = adherence; self.marks = marks
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        series = try c.decode(PhotoSeries.self, forKey: .series)
        date = try c.decode(Date.self, forKey: .date)
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
        ratings = (try? c.decode([String: Int].self, forKey: .ratings)) ?? [:]
        adherence = (try? c.decodeIfPresent(Double.self, forKey: .adherence)) ?? nil
        marks = (try? c.decodeIfPresent(HairlineMarks.self, forKey: .marks)) ?? nil
        metrics = (try? c.decodeIfPresent(PhotoMetrics.self, forKey: .metrics)) ?? nil
        fileName = (try? c.decode(String.self, forKey: .fileName)) ?? ""
    }
}

/// Where progress photos live: Application Support/Progress/<series>/<date>.jpg plus a .json with the entry. Nothing here is ever sent
/// anywhere; the folder is excluded from device backups unless the user opts in.
struct ProgressStore {
    let root: URL
    private let fm = FileManager.default

    init(root: URL = ProgressStore.defaultRoot()) { self.root = root }

    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Progress", isDirectory: true)
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: d)
    }
    private var coder: (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }

    func folder(_ s: PhotoSeries) -> URL { root.appendingPathComponent(s.rawValue, isDirectory: true) }
    func photoURL(_ e: ProgressEntry) -> URL { root.appendingPathComponent(e.fileName) }
    private func jsonURL(_ e: ProgressEntry) -> URL { photoURL(e).deletingPathExtension().appendingPathExtension("json") }

    /// Capture-time segmentation mattes ("hair", "skin") live next to the photo as <name>.hair.png / <name>.skin.png.
    static let matteKinds = ["hair", "skin"]
    func matteURL(_ e: ProgressEntry, _ kind: String) -> URL { photoURL(e).deletingPathExtension().appendingPathExtension(kind).appendingPathExtension("png") }
    func hasMatte(_ e: ProgressEntry, _ kind: String) -> Bool { fm.fileExists(atPath: matteURL(e, kind).path) }

    /// Saves the JPEG data and the entry (plus PNG mattes when given). A second photo on the same day gets "-2", "-3" ... Returns the entry with its file name set.
    @discardableResult
    func save(jpeg: Data, entry: ProgressEntry, mattes: [String: Data] = [:], excludeFromBackup: Bool) throws -> ProgressEntry {
        var e = entry
        let dir = folder(e.series)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = Self.stamp(e.date), n = 1
        while fm.fileExists(atPath: dir.appendingPathComponent(name + ".jpg").path) { n += 1; name = Self.stamp(e.date) + "-\(n)" }
        e.fileName = "\(e.series.rawValue)/\(name).jpg"
        try jpeg.write(to: photoURL(e), options: [.atomic, .completeFileProtection])
        for (kind, png) in mattes where Self.matteKinds.contains(kind) { try png.write(to: matteURL(e, kind), options: [.atomic, .completeFileProtection]) }
        try write(e)
        applyBackupFlag(excludeFromBackup)
        return e
    }

    /// Rewrites an entry's JSON (note, ratings, marks).
    func write(_ e: ProgressEntry) throws {
        try coder.0.encode(e).write(to: jsonURL(e), options: [.atomic, .completeFileProtection])
    }

    func entries(_ s: PhotoSeries) -> [ProgressEntry] {
        let dir = folder(s)
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? coder.1.decode(ProgressEntry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date != $1.date ? $0.date < $1.date : $0.fileName < $1.fileName }
    }

    func lastDate(_ s: PhotoSeries) -> Date? { entries(s).last?.date }
    func jpeg(_ e: ProgressEntry) -> Data? { try? Data(contentsOf: photoURL(e)) }

    func delete(_ e: ProgressEntry) {
        try? fm.removeItem(at: photoURL(e)); try? fm.removeItem(at: jsonURL(e))
        for k in Self.matteKinds { try? fm.removeItem(at: matteURL(e, k)) }
    }

    func deleteAll() { try? fm.removeItem(at: root) }

    /// Sets (or clears) the "exclude from backup" flag on the progress folder, which covers everything inside it.
    func applyBackupFlag(_ exclude: Bool) {
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        var u = root
        var v = URLResourceValues(); v.isExcludedFromBackup = exclude
        try? u.setResourceValues(v)
    }

    var isExcludedFromBackup: Bool { (try? URL(fileURLWithPath: root.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false }
}

enum HairlineMetric {
    /// Mean distance from the hairline points to the brow line, divided by the distance between the brows (so camera distance cancels out).
    static func ratio(_ m: HairlineMarks) -> Double? {
        guard m.hairline.count == 3, m.brows.count == 2 else { return nil }
        let a = m.brows[0], b = m.brows[1]
        let dx = b.x - a.x, dy = b.y - a.y
        let inter = (dx * dx + dy * dy).squareRoot()
        guard inter > 0.0001 else { return nil }
        let dists = m.hairline.map { abs(dx * (a.y - $0.y) - dy * (a.x - $0.x)) / inter }
        return dists.reduce(0, +) / Double(dists.count) / inter
    }

    enum Trend: String { case notEnough = "not enough data", stable, receding, improving }

    /// A least-squares line through the ratios (oldest first). Says receding or improving only with 4+ entries and a fitted change over 5%.
    static func trend(_ ratios: [Double]) -> (trend: Trend, change: Double) {
        let n = ratios.count
        guard n >= 4 else { return (.notEnough, 0) }
        let xs = (0..<n).map(Double.init), mx = xs.reduce(0, +) / Double(n), my = ratios.reduce(0, +) / Double(n)
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 0 else { return (.stable, 0) }
        let slope = zip(xs, ratios).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
        let start = my - slope * mx, end = start + slope * Double(n - 1)
        guard start > 0 else { return (.stable, 0) }
        let change = (end - start) / start
        // A bigger hairline-to-brow distance means the hairline has moved back.
        return (change > 0.05 ? .receding : change < -0.05 ? .improving : .stable, change)
    }
}
