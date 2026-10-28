import SwiftUI

/// Today: the day's skin, hair and photo checklist with streaks and a 7-day adherence ring.
struct TodayView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(ProgressLibrary.self) private var lib
    @State private var newExtra = ""
    @State private var capture: PhotoSeries?
    @State private var editing: SkinProduct?

    private var today: Date { Date() }
    private var items: [CheckItem] { TodayChecklist.items(on: today, data: user.data, skincare: store.catalog.skincare, lastPhoto: { lib.lastDate($0) }) }
    private var ticked: Set<String> { TodayChecklist.ticked(user.data, today) }

    var body: some View {
        NavigationStack {
            List {
                Section { ModeSwitch().listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
                header
                let all = items
                if all.filter({ $0.group != .extra }).isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Nothing on your list yet").font(.headline)
                            Text("Pick a skin routine on the Skin tab, add hair items on the Hair tab, or turn on photo reminders on the Progress tab. They show up here.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(CheckGroup.allCases.filter { $0 != .extra }) { g in
                    let list = all.filter { $0.group == g }
                    if !list.isEmpty {
                        Section {
                            ForEach(list) { row($0) }
                        } header: { header(g) }
                    }
                }
                Section("Your extras") {
                    ForEach(all.filter { $0.group == .extra }) { row($0) }
                        .onDelete { idx in
                            let ids = all.filter { $0.group == .extra }
                            for i in idx { if let x = user.data.extraItems.firstIndex(where: { "extra-\($0.id.uuidString)" == ids[i].id }) { user.data.extraItems.remove(at: x) } }
                        }
                    HStack {
                        TextField("Add water, vitamin D ...", text: $newExtra).submitLabel(.done).onSubmit(addExtra)
                        Button("Add", action: addExtra).disabled(newExtra.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Today")
            .fullScreenCoverIfIOS(item: $capture)
            .sheet(item: $editing) { p in ProductEditor(product: p, isNew: false) }
        }
    }

    private var header: some View {
        let week = TodayChecklist.weekAdherence(endingOn: today, data: user.data, skincare: store.catalog.skincare)
        return Section {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                    Circle().trim(from: 0, to: week ?? 0).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text(week.map { "\(Int(($0 * 100).rounded()))%" } ?? "-").font(.subheadline.bold())
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(today.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.headline)
                    Text("Last 7 days of your routine").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func header(_ g: CheckGroup) -> some View {
        let streak = g.isRoutine ? TodayChecklist.streak(g, endingOn: today, data: user.data, skincare: store.catalog.skincare) : 0
        return HStack {
            Label(g.title, systemImage: g.symbol)
            Spacer()
            if streak > 0 { Label("\(streak)", systemImage: "flame.fill").foregroundStyle(.orange).font(.caption.bold()) }
        }
    }

    private func row(_ item: CheckItem) -> some View {
        let done = item.autoDone || ticked.contains(item.id)
        return Button {
            if let s = item.series { if !done { capture = s }; return }
            toggle(item.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : (item.series != nil ? "camera.circle" : "circle")).font(.title3).foregroundStyle(done ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).strikethrough(done, color: .secondary).foregroundStyle(done ? Color.secondary : Color.primary)
                    if let pid = item.productId {
                        if item.productName.isEmpty {
                            Text("Add your product").font(.footnote).foregroundStyle(Color.accentColor)
                                .onTapGesture { editing = user.data.products.first { $0.id == pid } }
                        } else { Text(item.productName).font(.footnote).foregroundStyle(.secondary) }
                    }
                    if !item.detail.isEmpty { Text(item.detail).font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: done)
    }

    private func toggle(_ id: String) {
        let k = TodayChecklist.dayKey(today)
        var s = user.data.checks[k] ?? []
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        user.data.checks[k] = s
    }

    private func addExtra() {
        let t = newExtra.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        user.data.extraItems.append(ExtraCheckItem(title: t)); newExtra = ""
    }
}

private extension View {
    /// Opens the camera for a due photo series (iPhone only).
    @ViewBuilder func fullScreenCoverIfIOS(item: Binding<PhotoSeries?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: item) { CaptureView(series: $0) }
        #else
        self
        #endif
    }
}
