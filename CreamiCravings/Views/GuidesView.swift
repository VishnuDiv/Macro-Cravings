import SwiftUI

struct GuidesView: View {
    @Environment(RecipeStore.self) private var store

    var body: some View {
        List {
            Section {
                NavigationLink { PaneerCalculatorView() } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Paneer calculator").font(.headline)
                            Text("Yield and macros for your milk and volume").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "function").foregroundStyle(Color.accentColor) }
                }
            }
            Section("Guides") {
                if store.catalog.guides.isEmpty {
                    ContentUnavailableView("No guides yet", systemImage: "book.pages",
                                           description: Text("Guides appear here once they are bundled with the app."))
                }
                ForEach(store.catalog.guides) { g in
                    NavigationLink { GuideDetailView(guide: g) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.title).font(.headline)
                                if !g.subtitle.isEmpty { Text(g.subtitle).font(.caption).foregroundStyle(.secondary) }
                            }
                        } icon: { Image(systemName: g.icon).foregroundStyle(Color.accentColor) }
                    }
                }
            }
        }
        .navigationTitle("Guides")
        .inlineTitle()
    }
}

struct GuideDetailView: View {
    let guide: Guide

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Image(systemName: guide.icon).font(.largeTitle).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading) {
                        Text(guide.title).font(.title.bold())
                        if !guide.subtitle.isEmpty { Text(guide.subtitle).foregroundStyle(.secondary) }
                    }
                }
                ForEach(Array(guide.sections.enumerated()), id: \.offset) { _, s in section(s) }
                if guide.id.localizedCaseInsensitiveContains("paneer") {
                    NavigationLink { PaneerCalculatorView() } label: {
                        Label("Open the paneer calculator", systemImage: "function").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            .padding()
        }
        .background(Color.screenBackground)
        .navigationTitle(guide.title)
        .inlineTitle()
    }

    @ViewBuilder private func section(_ s: GuideSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !s.heading.isEmpty { Text(s.heading).font(.title3.bold()) }
            if !s.body.isEmpty { Text(s.body).fixedSize(horizontal: false, vertical: true) }
            if let b = s.bullets, !b.isEmpty {
                ForEach(b, id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) { Text("•"); Text(line).fixedSize(horizontal: false, vertical: true) }
                }
            }
            if let t = s.table, !t.columns.isEmpty { GuideTableView(table: t) }
        }
    }
}

struct GuideTableView: View {
    let table: GuideTable
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow { ForEach(Array(table.columns.enumerated()), id: \.offset) { _, c in Text(c).font(.footnote.bold()) } }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(cell).font(.footnote) } }
                }
            }
            .padding(12)
        }
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct PaneerCalculatorView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @State private var milkId: String?
    @State private var liters = 2.0

    private var model: PaneerModel { store.catalog.paneer ?? .fallback }
    private var milks: [BaseLiquid] { PaneerCalculator.eligible(user.allLiquids(store.catalog)) }
    private var milk: BaseLiquid? { milks.first { $0.id == milkId } ?? milks.first { $0.id == user.data.defaultMilkId } ?? milks.first }

    var body: some View {
        Form {
            if milks.isEmpty {
                ContentUnavailableView("No milks available", systemImage: "drop", description: Text("Add a milk in Settings first."))
            } else if let m = milk {
                let r = PaneerCalculator.estimate(milk: m, liters: liters, model: model)
                Section("Milk and volume") {
                    Picker("Milk", selection: Binding(get: { m.id }, set: { milkId = $0 })) {
                        ForEach(milks) { Text($0.name).tag($0.id) }
                    }
                    VStack(alignment: .leading) {
                        Text("Volume: \(liters.formatted(.number.precision(.fractionLength(1)))) L")
                            .contentTransition(.numericText(value: liters))
                        Slider(value: $liters, in: 0.5...4, step: 0.5)
                    }
                }
                Section("Estimated pressed paneer") {
                    LabeledContent("Yield") {
                        Text("\(Int(r.yieldGrams.rounded())) g").font(.title2.bold().monospacedDigit())
                            .contentTransition(.numericText(value: r.yieldGrams))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Whole batch").font(.caption).foregroundStyle(.secondary)
                        MacroRow(n: r.total)
                        Text("Per 100 g").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        MacroRow(n: r.per100g)
                    }
                    .animation(.snappy, value: r.yieldGrams)
                    if let n = model.notes, !n.isEmpty { Text(n).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    let rows = PaneerCalculator.comparison(milks: milks, model: model)
                    ForEach(rows, id: \.milk.id) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.milk.name).font(.subheadline.weight(row.milk.id == m.id ? .bold : .regular))
                            Text("\(Int(row.result.yieldGrams.rounded())) g · \(Int(row.result.per100g.calories.rounded())) kcal and \(String(format: "%.1f", row.result.per100g.protein)) g protein per 100 g · \(String(format: "%.1f", row.result.per100g.proteinPer100kcal)) g protein per 100 kcal")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Compare for 1 L") } footer: { Text("Sorted by protein per 100 kcal.") }
            }
        }
        .navigationTitle("Paneer calculator")
        .inlineTitle()
    }
}
