import SwiftUI
import Charts
#if os(iOS)

/// One chartable on-device metric.
struct PhotoMetricSpec {
    var title: String
    var note: String
    var value: (PhotoMetrics) -> Double?
    var format: (Double) -> String
    var lowerIsBetter = true

    static func specs(for series: PhotoSeries) -> [PhotoMetricSpec] {
        switch series {
        case .faceFront, .faceLeft, .faceRight:
            return [
                PhotoMetricSpec(title: "Redness", note: "Mean CIELAB a* over the skin (lower is less red).", value: { $0.redness }, format: { String(format: "%.1f", $0) }),
                PhotoMetricSpec(title: "Evenness", note: "Spread of brightness after a 15 px blur (lower is more even).", value: { $0.evenness }, format: { String(format: "%.1f", $0) }),
                PhotoMetricSpec(title: "Spots", note: "Small dark or red blobs, 2 to 12 px.", value: { $0.spots.map(Double.init) }, format: { String(Int($0)) }),
            ]
        case .hairline:
            return [PhotoMetricSpec(title: "Hairline height (automatic)", note: "Hairline to brow line, divided by the distance between the pupils. Bigger = the hairline sits higher.",
                                    value: { $0.hairlineRatio }, format: { String(format: "%.2f", $0) })]
        case .crown:
            return [PhotoMetricSpec(title: "Scalp visible", note: "Share of the centre circle where no hair covers the scalp (lower = denser).",
                                    value: { $0.scalpVisibility }, format: { String(format: "%.0f%%", $0 * 100) })]
        default:
            return []
        }
    }
}

/// Per-metric trend charts on a series screen. Photos whose lighting differs from the series median are greyed out and left out of the trend.
struct MetricChartsSection: View {
    let series: PhotoSeries
    @Environment(ProgressLibrary.self) private var lib

    var body: some View {
        let specs = PhotoMetricSpec.specs(for: series)
        let list = lib.entries(series)
        if !specs.isEmpty && list.contains(where: { $0.metrics != nil }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Measured on this phone").font(.headline)
                ForEach(specs.indices, id: \.self) { MetricChart(spec: specs[$0], entries: list) }
            }
        }
    }
}

struct MetricChart: View {
    let spec: PhotoMetricSpec
    let entries: [ProgressEntry]

    private struct Point: Identifiable { var id: UUID; var date: Date; var value: Double; var flagged: Bool; var lower: Bool }

    private var points: [Point] {
        let flags = LightingGuard.flags(entries.map { $0.metrics?.luminance })
        return entries.enumerated().compactMap { i, e in
            guard let m = e.metrics, let v = spec.value(m) else { return nil }
            return Point(id: e.id, date: e.date, value: v, flagged: flags[i], lower: m.lowerConfidence)
        }
    }

    var body: some View {
        let pts = points
        let usable = pts.filter { !$0.flagged }
        let t = MetricTrend.evaluate(usable.map(\.value), lowerIsBetter: spec.lowerIsBetter)
        let flaggedCount = pts.count - usable.count
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(spec.title).font(.subheadline.weight(.semibold))
                Spacer()
                if let last = usable.last ?? pts.last { Text(spec.format(last.value)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if pts.count < 2 {
                Text("Needs at least 2 measured photos for a chart.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(usable) { p in LineMark(x: .value("Date", p.date), y: .value(spec.title, p.value)).foregroundStyle(Color.accentColor) }
                    ForEach(pts) { p in
                        PointMark(x: .value("Date", p.date), y: .value(spec.title, p.value))
                            .foregroundStyle(p.flagged ? Color.gray.opacity(0.5) : Color.accentColor)
                            .symbol(p.lower ? .diamond : .circle)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false)).frame(height: 120)
                Text(label(t, count: usable.count)).font(.footnote.weight(.semibold))
            }
            Text(spec.note).font(.caption).foregroundStyle(.secondary)
            if flaggedCount > 0 {
                Label("\(flaggedCount) photo\(flaggedCount == 1 ? "" : "s") greyed out: lighting differs, so the trend point may be off.", systemImage: "sun.max").font(.caption).foregroundStyle(.orange)
            }
            if pts.contains(where: { $0.lower }) {
                Label("Diamond points are lower confidence (no hair or skin matte, so landmarks or colour were used).", systemImage: "diamond").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private func label(_ t: (label: MetricTrend.Label, change: Double), count: Int) -> String {
        switch t.label {
        case .notEnough: return "Not enough photos for a trend yet (4 needed, \(count) usable)."
        case .stable: return "Trend: stable (\(pct(t.change)) across \(count) photos)."
        case .improving, .worsening: return "Trend: \(t.label.rawValue) (\(pct(t.change)) across \(count) photos)."
        }
    }
    private func pct(_ c: Double) -> String { "\(c >= 0 ? "+" : "")\(Int((c * 100).rounded()))%" }
}

/// The numbers measured on one photo, on its detail screen.
struct EntryMetricsSection: View {
    let initial: ProgressEntry
    @Environment(ProgressLibrary.self) private var lib

    var body: some View {
        let list = lib.entries(initial.series)
        let entry = list.first { $0.id == initial.id } ?? initial       // fresh copy: the numbers arrive after the photo is saved
        let specs = PhotoMetricSpec.specs(for: entry.series)
        if !specs.isEmpty {
            Section {
                if let m = entry.metrics {
                    ForEach(specs.indices, id: \.self) { i in
                        if let v = specs[i].value(m) { LabeledContent(specs[i].title, value: specs[i].format(v)) }
                    }
                    if entry.series == .hairline, let t = m.hairlineTempleRatio { LabeledContent("At the temples", value: String(format: "%.2f", t)) }
                    if m.lowerConfidence { Label("Lower confidence: no hair or skin matte for this photo, so face landmarks or colour were used.", systemImage: "diamond").font(.footnote).foregroundStyle(.secondary) }
                    if let i = list.firstIndex(where: { $0.id == entry.id }), LightingGuard.flags(list.map { $0.metrics?.luminance })[i] {
                        Label("Lighting differs from the rest of this series, so these numbers may be off.", systemImage: "sun.max").font(.footnote).foregroundStyle(.orange)
                    }
                } else if lib.isAnalyzing(entry.id) {
                    HStack { ProgressView(); Text("Measuring…").foregroundStyle(.secondary) }
                } else {
                    Text("Not measured yet.").foregroundStyle(.secondary)
                }
                Button { lib.analyze(entry, force: true) } label: { Label(entry.metrics == nil ? "Measure this photo" : "Measure again", systemImage: "ruler") }
            } header: { Text("Measured on this phone") } footer: { Text("Automatic numbers from the photo, worked out on the phone. Nothing is sent anywhere.") }
        }
    }
}
#endif
