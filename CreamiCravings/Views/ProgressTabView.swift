import SwiftUI
import PhotosUI
import Charts
#if os(iOS)
import UIKit

/// Progress tab: one row per photo series with its latest photo, schedule and a due marker.
struct ProgressTabView: View {
    @Environment(UserStore.self) private var user
    @Environment(ProgressLibrary.self) private var lib
    @Environment(Router.self) private var router
    @State private var capture: PhotoSeries?
    @State private var ssCheckup: CheckupRecord?

    var body: some View {
        NavigationStack {
            List {
                Section { ModeSwitch().listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
                let due = lib.dueSeries(user)
                if !due.isEmpty {
                    Section("Due today") {
                        ForEach(due) { s in
                            Button { capture = s } label: { Label("Take your \(s.title.lowercased()) photo", systemImage: "camera.fill") }
                        }
                    }
                }
                ForEach([("Skin", PhotoSeries.allCases.filter(\.isSkin)), ("Hair", PhotoSeries.allCases.filter { !$0.isSkin })], id: \.0) { title, list in
                    Section(title) {
                        ForEach(list) { s in
                            NavigationLink { SeriesView(series: s) } label: { seriesRow(s, due: due.contains(s)) }
                        }
                    }
                }
                Section {
                    NavigationLink { CheckupHomeView() } label: { Label("AI check-up", systemImage: "sparkles") }
                } footer: { Text("Optional. Sends the photos you pick to Claude only after you confirm. Needs your own API key.") }
                Section { HealthNote(text: "Photos are saved only on this phone, in the app's private storage. They are never uploaded. Sharing happens only when you tap Share.", symbol: "lock") }
                    .listRowBackground(Color.clear)
            }
            .navigationTitle("Progress")
            .fullScreenCover(item: $capture) { s in CaptureView(series: s) }
            .navigationDestination(item: $ssCheckup) { CheckupResultView(record: $0) }
            #if DEBUG
            .onAppear { if router.ssOpenCheckup, ssCheckup == nil { ssCheckup = lib.checkups.records.last } }
            #endif
        }
    }

    private func seriesRow(_ s: PhotoSeries, due: Bool) -> some View {
        let list = lib.entries(s)
        return HStack(spacing: 12) {
            Group {
                if let last = list.last, let img = ProgressImage.thumbnail(lib.store.photoURL(last), maxPixel: 160) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else { Image(systemName: "camera").foregroundStyle(.secondary) }
            }
            .frame(width: 52, height: 52).background(Color.cardBackground).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.headline)
                Text(list.isEmpty ? "No photos yet" : "\(list.count) photo\(list.count == 1 ? "" : "s"), last \(list.last!.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if due { Circle().fill(Color.orange).frame(width: 10, height: 10) }
        }
    }
}

struct SeriesView: View {
    let series: PhotoSeries
    @Environment(UserStore.self) private var user
    @Environment(ProgressLibrary.self) private var lib
    @State private var capture = false
    @State private var picked: PhotosPickerItem?
    @State private var imported: CapturedPhoto?
    @State private var selected: ProgressEntry?

    private var list: [ProgressEntry] { lib.entries(series) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Button { capture = true } label: { Label("Take photo", systemImage: "camera.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                    PhotosPicker(selection: $picked, matching: .images) { Label("Import", systemImage: "photo").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                }
                .controlSize(.large)
                HStack {
                    NavigationLink { ScheduleView(series: series) } label: { Label(scheduleText, systemImage: "bell") }
                    Spacer()
                    if list.count >= 2 { NavigationLink { CompareView(series: series) } label: { Label("Compare", systemImage: "rectangle.split.2x1") } }
                }
                .font(.subheadline)
                if series == .hairline { HairlineChart(series: series) }
                MetricChartsSection(series: series)
                if list.isEmpty {
                    ContentUnavailableView("No photos yet", systemImage: "camera", description: Text(series.tip))
                } else {
                    Text("Timeline").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
                        ForEach(list.reversed()) { e in
                            Button { selected = e } label: {
                                ZStack(alignment: .bottomLeading) {
                                    if let img = ProgressImage.thumbnail(lib.store.photoURL(e), maxPixel: 300) {
                                        Image(uiImage: img).resizable().scaledToFill().frame(minHeight: 120).clipped()
                                    } else { Color.cardBackground.frame(height: 120) }
                                    Text(e.date.formatted(.dateTime.month(.abbreviated).day())).font(.caption2.bold()).padding(3).background(.black.opacity(0.5)).foregroundStyle(.white)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(series.title).inlineTitle()
        .fullScreenCover(isPresented: $capture) { CaptureView(series: series) }
        .sheet(item: $imported) { p in EntryEditorSheet(series: series, jpeg: p.data) { _ in imported = nil } }
        .sheet(item: $selected) { e in EntryDetailView(entry: e) }
        .task(id: list.count) { if !CheckupEnvironment.isFixtureMode { for e in list where e.metrics == nil { lib.analyze(e) } } }
        .onChange(of: picked) { _, item in
            Task { if let d = try? await item?.loadTransferable(type: Data.self) { imported = CapturedPhoto(data: d) }; picked = nil }
        }
    }

    private var scheduleText: String {
        guard let s = user.data.photoSchedules[series.rawValue], s.enabled else { return "Reminders off" }
        let f = ["daily": "Daily", "every2": "Every 2 days", "weekly": "Weekly"][s.frequency] ?? "Every \(s.customDays) days"
        return "\(f) at \(String(format: "%d:%02d", s.hour, s.minute))"
    }
}

struct ScheduleView: View {
    let series: PhotoSeries
    @Environment(UserStore.self) private var user
    @Environment(ProgressLibrary.self) private var lib

    private var binding: Binding<PhotoSchedule> {
        Binding(get: { user.data.photoSchedules[series.rawValue] ?? PhotoSchedule() }, set: { user.data.photoSchedules[series.rawValue] = $0 })
    }

    var body: some View {
        Form {
            Toggle("Remind me", isOn: binding.enabled)
            if binding.wrappedValue.enabled {
                Picker("How often", selection: binding.frequency) {
                    Text("Every day").tag("daily"); Text("Every 2 days").tag("every2"); Text("Every week").tag("weekly"); Text("Custom").tag("custom")
                }
                if binding.wrappedValue.frequency == "custom" { Stepper("Every \(binding.wrappedValue.customDays) days", value: binding.customDays, in: 2...60) }
                DatePicker("At", selection: Binding(
                    get: { Calendar.current.date(bySettingHour: binding.wrappedValue.hour, minute: binding.wrappedValue.minute, second: 0, of: Date()) ?? Date() },
                    set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); var s = binding.wrappedValue; s.hour = c.hour ?? 9; s.minute = c.minute ?? 0; binding.wrappedValue = s }
                ), displayedComponents: .hourAndMinute)
            }
            Section { Text(series.tip).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("\(series.title) reminders").inlineTitle()
        .onChange(of: user.data.photoSchedules) { _, _ in Task { await lib.rearmReminders(user) } }
    }
}

struct EntryDetailView: View {
    @State var entry: ProgressEntry
    @Environment(ProgressLibrary.self) private var lib
    @Environment(\.dismiss) private var dismiss
    @State private var marking = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                if let img = ProgressImage.thumbnail(lib.store.photoURL(entry), maxPixel: 1200) {
                    Section { Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: .infinity) }
                }
                Section {
                    Text(entry.date.formatted(date: .long, time: .omitted))
                    TextField("Note", text: $entry.note, axis: .vertical)
                    if let a = entry.adherence { Text("Routine done that day: \(Int((a * 100).rounded()))%").font(.footnote).foregroundStyle(.secondary) }
                }
                if entry.series.isSkin {
                    Section("Ratings (0 to 5)") {
                        ForEach(["breakouts", "redness", "oiliness"], id: \.self) { k in
                            Stepper("\(k.capitalized): \(entry.ratings[k] ?? 0)", value: Binding(get: { entry.ratings[k] ?? 0 }, set: { entry.ratings[k] = $0 }), in: 0...5)
                        }
                    }
                } else {
                    Section("Shedding") {
                        Picker("Shedding", selection: Binding(get: { entry.ratings["shedding"] ?? 0 }, set: { entry.ratings["shedding"] = $0 })) {
                            Text("Low").tag(0); Text("Medium").tag(1); Text("High").tag(2)
                        }.pickerStyle(.segmented)
                    }
                }
                EntryMetricsSection(initial: entry)
                if entry.series == .hairline {
                    Section("Hairline tracker") {
                        Button { marking = true } label: { Label(entry.marks == nil ? "Mark hairline and brows" : "Re-mark hairline and brows", systemImage: "scope") }
                        if let r = entry.marks.flatMap(HairlineMetric.ratio) { Text("Hairline-to-brow ratio: \(r, specifier: "%.2f")").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                Section {
                    ShareLink(item: lib.store.photoURL(entry)) { Label("Share this photo", systemImage: "square.and.arrow.up") }
                    Button("Delete photo", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle("Photo").inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { lib.update(entry); dismiss() } } }
            .sheet(isPresented: $marking) { HairlineMarkView(entry: $entry) }
            .confirmationDialog("Delete this photo from your phone?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { lib.delete(entry); dismiss() }
            }
        }
    }
}

/// Tap three hairline points (left temple peak, center, right temple peak), then two brow points. Stored normalized; no AI involved.
struct HairlineMarkView: View {
    @Binding var entry: ProgressEntry
    @Environment(ProgressLibrary.self) private var lib
    @Environment(\.dismiss) private var dismiss
    @State private var points: [NormPoint] = []
    private let prompts = ["Left temple peak of the hairline", "Center of the hairline", "Right temple peak of the hairline", "Left eyebrow (top, middle)", "Right eyebrow (top, middle)"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text(points.count < 5 ? "Tap: \(prompts[points.count])" : "All set. Tap Save.").font(.subheadline.weight(.semibold))
                if let img = ProgressImage.thumbnail(lib.store.photoURL(entry), maxPixel: 1400) {
                    Image(uiImage: img).resizable().scaledToFit()
                        .overlay { GeometryReader { g in
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture(coordinateSpace: .local) { loc in
                                    guard points.count < 5, g.size.width > 0, g.size.height > 0 else { return }
                                    points.append(NormPoint(x: loc.x / g.size.width, y: loc.y / g.size.height))
                                }
                            ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                                Circle().fill(i < 3 ? Color.orange : Color.cyan).frame(width: 12, height: 12)
                                    .position(x: p.x * g.size.width, y: p.y * g.size.height)
                            }
                        } }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Mark photo").inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Undo") { _ = points.popLast() }.disabled(points.isEmpty)
                    Button("Save") { entry.marks = HairlineMarks(hairline: Array(points[0..<3]), brows: Array(points[3..<5])); lib.update(entry); dismiss() }.disabled(points.count < 5)
                }
            }
            .onAppear { if let m = entry.marks { points = m.hairline + m.brows } }
        }
    }
}

struct HairlineChart: View {
    let series: PhotoSeries
    @Environment(ProgressLibrary.self) private var lib

    var body: some View {
        let pts: [(Date, Double)] = lib.entries(series).compactMap { e in e.marks.flatMap(HairlineMetric.ratio).map { (e.date, $0) } }
        let t = HairlineMetric.trend(pts.map(\.1))
        VStack(alignment: .leading, spacing: 8) {
            Text("Hairline tracker").font(.headline)
            if pts.count < 2 {
                Text("Open a photo and mark your hairline and brows. With 4 or more marked photos you get a trend.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Date", p.0), y: .value("Ratio", p.1)).foregroundStyle(Color.accentColor)
                        PointMark(x: .value("Date", p.0), y: .value("Ratio", p.1)).foregroundStyle(Color.accentColor)
                    }
                    if let line = trendLine(pts) {
                        ForEach(Array(line.enumerated()), id: \.offset) { _, p in
                            LineMark(x: .value("Date", p.0), y: .value("Trend", p.1), series: .value("Series", "trend")).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false)).frame(height: 160)
                Text(t.trend == .notEnough ? "Not enough marked photos for a trend yet (4 needed)." : "Trend: \(t.trend.rawValue) (\(t.change >= 0 ? "+" : "")\(Int((t.change * 100).rounded()))% across \(pts.count) photos).")
                    .font(.footnote.weight(.semibold))
                Text("A bigger number means a bigger gap between hairline and brows. This is your own marking, not an AI measurement, and lighting and head tilt move it a little. If you are worried, ask a dermatologist.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private func trendLine(_ pts: [(Date, Double)]) -> [(Date, Double)]? {
        let n = pts.count
        guard n >= 2 else { return nil }
        let xs = (0..<n).map(Double.init), mx = xs.reduce(0, +) / Double(n), my = pts.map(\.1).reduce(0, +) / Double(n)
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 0 else { return nil }
        let slope = zip(xs, pts.map(\.1)).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
        let b = my - slope * mx
        return [(pts[0].0, b), (pts[n - 1].0, b + slope * Double(n - 1))]
    }
}

struct CompareView: View {
    let series: PhotoSeries
    @Environment(ProgressLibrary.self) private var lib
    @State private var mode = 0
    @State private var a = 0
    @State private var b = 0
    @State private var split = 0.5

    private var list: [ProgressEntry] { lib.entries(series) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("Mode", selection: $mode) { Text("Side by side").tag(0); Text("Slider").tag(1); Text("By month").tag(2) }.pickerStyle(.segmented)
                if mode < 2 {
                    HStack {
                        picker("Before", $a); picker("After", $b)
                    }
                    if list.indices.contains(a), list.indices.contains(b) {
                        if mode == 0 {
                            HStack(spacing: 6) { photo(list[a]); photo(list[b]) }
                        } else {
                            slider(list[a], list[b])
                        }
                    }
                } else {
                    ForEach(months, id: \.0) { m, first, last in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(m).font(.headline)
                            HStack(spacing: 6) { photo(first); if first.id != last.id { photo(last) } }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Compare").inlineTitle()
        .onAppear { a = 0; b = max(0, list.count - 1) }
    }

    private var months: [(String, ProgressEntry, ProgressEntry)] {
        let groups = Dictionary(grouping: list) { $0.date.formatted(.dateTime.year().month(.wide)) }
        return groups.compactMap { k, v in v.first.flatMap { f in v.last.map { (k, f, $0) } } }.sorted { $0.1.date < $1.1.date }
    }

    private func picker(_ title: String, _ sel: Binding<Int>) -> some View {
        Picker(title, selection: sel) { ForEach(list.indices, id: \.self) { Text(list[$0].date.formatted(date: .abbreviated, time: .omitted)).tag($0) } }
    }

    private func photo(_ e: ProgressEntry) -> some View {
        VStack(spacing: 4) {
            if let img = ProgressImage.thumbnail(lib.store.photoURL(e), maxPixel: 900) { Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8)) }
            Text(e.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func slider(_ e1: ProgressEntry, _ e2: ProgressEntry) -> some View {
        let i1 = ProgressImage.thumbnail(lib.store.photoURL(e1), maxPixel: 1200), i2 = ProgressImage.thumbnail(lib.store.photoURL(e2), maxPixel: 1200)
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                if let i2 { Image(uiImage: i2).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped() }
                if let i1 {
                    Image(uiImage: i1).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                        .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * split) }
                }
                Rectangle().fill(.white).frame(width: 3).offset(x: g.size.width * split - 1.5).shadow(radius: 2)
                Circle().fill(.white).frame(width: 30, height: 30).overlay(Image(systemName: "arrow.left.and.right").font(.caption).foregroundStyle(.black))
                    .offset(x: g.size.width * split - 15).shadow(radius: 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { split = min(1, max(0, $0.location.x / g.size.width)) })
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
#else
struct ProgressTabView: View { var body: some View { Text("Progress photos need an iPhone.") } }
#endif
