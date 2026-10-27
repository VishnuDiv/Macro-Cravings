import SwiftUI

struct IngredientRow: View {
    let recipe: Recipe
    let line: LineResult
    var vegSwap: VegSwap?
    var vegAlt: VegLineAlt?
    var onPickAlt: (String) -> Void = { _ in }
    @State private var showAmount = false
    @State private var showNote = false
    let onSwap: () -> Void
    @Environment(UserStore.self) private var user
    @Environment(RecipeStore.self) private var store

    /// A swap-note line such as "(Omit the baking soda — not needed for seitan)": shown as a note, not as an ingredient.
    private var isNoteRow: Bool {
        let t = line.ing.text.trimmingCharacters(in: .whitespaces)
        return line.ing.key == "mix_in_choice" && t.hasPrefix("(") && t.hasSuffix(")")
    }

    private var note: IngredientNote? {
        guard let k = line.effectiveKey ?? line.ing.key else { return nil }
        return store.catalog.clarity?.ingredientNotes[k]
    }

    var body: some View {
        if isNoteRow {
            Text(line.ing.text).font(.footnote.italic()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.vertical, 8)
        } else {
            rowBody
        }
    }

    @ViewBuilder private var rowBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(NutritionCalculator.amountText(line))
                            .strikethrough(line.missing)
                            .foregroundStyle(line.missing || !line.included ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if note != nil {
                            Button { showNote = true } label: { Image(systemName: "info.circle").font(.footnote) }
                                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                                .accessibilityLabel("About this ingredient")
                        }
                    }
                    if let s = line.swap {
                        Label("Using \(s.name)" + (line.swapFromGoal ? " · goal version" : "") + (line.swapNotRecalculated ? " · macros not recalculated" : ""), systemImage: "arrow.triangle.swap")
                            .font(.caption).foregroundStyle(Color.accentColor)
                    } else if let y = line.yogurtLabel {
                        Label("Using \(y)", systemImage: "leaf").font(.caption).foregroundStyle(Color.accentColor)
                    } else if let p = line.powder {
                        Label("Using \(p.name)", systemImage: "scalemass").font(.caption).foregroundStyle(Color.accentColor)
                    } else if let m = line.milk {
                        Label("Using \(m.name)", systemImage: "cup.and.saucer").font(.caption).foregroundStyle(Color.accentColor)
                    }
                    HStack(spacing: 6) {
                        if line.isBoost {
                            Text("+ boost").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.green.opacity(0.18), in: Capsule()).foregroundStyle(.green)
                        }
                        if line.ing.optional {
                            Button {
                                user.toggleOptional(recipe.id, line: line.lineKey)
                            } label: {
                                Label(line.included ? "Optional · included" : "Optional · tap to include",
                                      systemImage: line.included ? "checkmark.circle.fill" : "circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        if let o = line.overrideLabel {
                            Text(o).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.carbBlue.opacity(0.18), in: Capsule()).foregroundStyle(Color.carbBlue)
                        }
                        if line.amount == .estimated {
                            Button { showAmount = true } label: {
                                Text("≈ \(Int(line.grams.rounded())) g · est.")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.18), in: Capsule()).foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Estimated amount \(Int(line.grams.rounded())) grams. Tap for details.")
                        } else if line.amount == .user {
                            Button { showAmount = true } label: {
                                Text("your amount: \(Int(line.grams.rounded())) g")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.16), in: Capsule()).foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        } else if line.noData && line.included {
                            if line.info == nil { Text("no nutrition data").font(.caption2).foregroundStyle(.secondary) }
                            else {
                                Button { showAmount = true } label: { Text("amount unknown · set").font(.caption2).foregroundStyle(.secondary).underline() }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    if line.missing, let first = line.info?.swaps.first {
                        Label("Swap: \(first.name)", systemImage: "arrow.triangle.swap").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 4)
                if line.isBoost {
                    Label("Boost", systemImage: "plus.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green)
                } else if line.isExtra {
                    Label("Add-on", systemImage: "plus.circle.fill").labelStyle(.iconOnly).foregroundStyle(.orange)
                } else {
                Button(action: onSwap) {
                    Image(systemName: "arrow.left.arrow.right.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityLabel("Swap or I don't have it")
                }
            }
            if let v = vegSwap {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Vegetarian swap: \(line.ing.text)", systemImage: "leaf.fill").font(.footnote.weight(.semibold)).foregroundStyle(.green)
                    Text("instead of \(v.replaces)").font(.caption).foregroundStyle(.secondary)
                    if let n = v.note, !n.isEmpty { Text(n).font(.caption) }
                    if let a = vegAlt, a.options.count > 1 { VegAltPicker(alt: a, onPick: onPickAlt) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if user.data.isVegetarian, let info = line.info, info.vegetarian != .yes {
                NonVegCallout(info: info, catalogSwaps: info.swaps)
            }
            if let a = line.info?.affiliate { AffiliateCallout(affiliate: a, info: line.info) }
        }
        .padding(.horizontal).padding(.vertical, 10)
        .contentShape(Rectangle())
        .sheet(isPresented: $showAmount) { AmountSheet(recipe: recipe, line: line).environment(user) }
        .sheet(isPresented: $showNote) {
            if let n = note { IngredientNoteSheet(title: line.info?.name ?? line.ing.text, note: n) }
        }
        .contextMenu {
            Button { onSwap() } label: { Label("Swap / I don't have it", systemImage: "arrow.left.arrow.right") }
            if let k = line.ing.key {
                Button {
                    user.setMissing(k, !line.missing)
                } label: { Label(line.missing ? "I have this" : "I don't have this", systemImage: line.missing ? "checkmark" : "xmark") }
            }
        }
    }
}

/// Horizontal "Alt 1 · Alt 2 ..." picker for the ranked vegetarian alternatives of a line.
struct VegAltPicker: View {
    let alt: VegLineAlt
    let onPick: (String) -> Void

    private func color(_ a: String) -> Color { a == "everywhere" ? .green : (a == "specialty" ? .orange : .blue) }

    private func deltaText(_ d: Nutrition) -> String {
        func s(_ v: Double, _ u: String) -> String { (v >= 0 ? "+" : "−") + "\(Int(abs(v).rounded()))" + u }
        return "\(s(d.calories, " kcal")) · \(s(d.protein, " g P"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(alt.roleLabel).font(.caption2).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(alt.options.enumerated()), id: \.offset) { i, o in
                        let on = o.alt.key == alt.chosenKey
                        Button { onPick(o.alt.key) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Alt \(i + 1)").font(.caption2.weight(.bold)).foregroundStyle(on ? .white.opacity(0.85) : .secondary)
                                Text(o.alt.name).font(.footnote.weight(.semibold)).lineLimit(1)
                                Text(o.alt.availabilityTitle).font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(color(o.alt.availability).opacity(on ? 0.9 : 0.2), in: Capsule())
                                    .foregroundStyle(on ? Color.white : color(o.alt.availability))
                                Text(o.isDefault ? "book version" : deltaText(o.deltaPerServing)).font(.caption2.monospacedDigit())
                                    .foregroundStyle(on ? .white.opacity(0.85) : .secondary)
                            }
                            .padding(8)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .background(on ? Color.green : Color.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: alt.chosenKey)
            if let c = alt.chosen {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Int(c.grams)) g \(c.alt.name) matches the protein of \(alt.original.text)").font(.caption.weight(.medium))
                    if let w = c.alt.whereToBuy, !w.isEmpty { (Text("Where to buy: ").bold() + Text(w)).font(.caption) }
                    if let b = c.alt.brands, !b.isEmpty { (Text("Brands: ").bold() + Text(b)).font(.caption) }
                    if let p = c.alt.prep, !p.isEmpty { (Text("Prep: ").bold() + Text(p)).font(.caption) }
                    if let y = c.alt.why, !y.isEmpty { Text(y).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

/// Flags an ingredient the catalog marks as not (or not certainly) vegetarian, with veg swap ideas.
struct NonVegCallout: View {
    let info: IngredientInfo
    let catalogSwaps: [SwapOption]
    @Environment(RecipeStore.self) private var store

    private var vegSwaps: [SwapOption] {
        catalogSwaps.filter { s in s.key.map { store.catalog.info($0)?.vegetarian != .no } ?? true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(info.vegetarian == .no ? "Not vegetarian" : "Check if vegetarian", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
            if let n = info.vegNote, !n.isEmpty { Text(n).font(.caption) }
            if !vegSwaps.isEmpty {
                Text("Veg swaps: " + vegSwaps.prefix(3).map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct AffiliateCallout: View {
    let affiliate: Affiliate
    let info: IngredientInfo?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Affiliate pick · \(affiliate.brand)", systemImage: "tag.fill")
                .font(.footnote.weight(.semibold)).foregroundStyle(Color.accentColor)
            if let n = affiliate.note, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary) }
            if let s = info?.storeAlternative, !s.isEmpty {
                (Text("Buy instead: ").bold() + Text(s)).font(.caption)
            }
            if let h = info?.homemadeAlternative, !h.isEmpty {
                (Text("Make it: ").bold() + Text(h)).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SwapSheet: View {
    let recipe: Recipe
    let lineKey: String
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss

    private var cfg: RecipeConfig { user.config(for: recipe, catalog: store.catalog, applyGoal: false) }
    private var calc: NutritionCalculator { NutritionCalculator(catalog: store.catalog) }
    private var line: LineResult? { calc.compute(recipe, cfg).lines.first { $0.lineKey == lineKey } }

    var body: some View {
        NavigationStack {
            List {
                if let l = line {
                    Section {
                        Text(l.ing.text).font(.headline)
                        if let k = l.ing.key {
                            Toggle("I don't have this", isOn: Binding(
                                get: { user.data.pantryMissing.contains(k) },
                                set: { user.setMissing(k, $0) }))
                        }
                    } footer: {
                        if l.info == nil { Text("This ingredient isn't in the catalog yet, so there are no suggested swaps.") }
                    }

                    if let info = l.info {
                        if let a = info.affiliate { Section { AffiliateCallout(affiliate: a, info: info).listRowInsets(EdgeInsets()) .listRowBackground(Color.clear) } }
                        else if info.storeAlternative != nil || info.homemadeAlternative != nil {
                            Section("Alternatives") {
                                if let s = info.storeAlternative { (Text("Buy instead: ").bold() + Text(s)).font(.subheadline) }
                                if let h = info.homemadeAlternative { (Text("Make it: ").bold() + Text(h)).font(.subheadline) }
                            }
                        }
                        Section("Swap with") {
                            Button { user.setSwap(recipe.id, line: lineKey, index: nil); dismiss() } label: {
                                HStack { Text("Original ingredient").foregroundStyle(.primary); Spacer()
                                    if l.swapIndex == nil { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) } }
                            }
                            ForEach(orderedSwaps(info), id: \.offset) { i, s in
                                Button { user.setSwap(recipe.id, line: lineKey, index: i); dismiss() } label: {
                                    swapRow(s, index: i, selected: l.swapIndex == i)
                                }
                            }
                            if info.swaps.isEmpty { Text("No swaps listed for this ingredient.").foregroundStyle(.secondary) }
                        }
                    }
                    if l.isMilkLine {
                        Section {
                            Text("Pick a different milk from the \"Your milk\" menu on the recipe page.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let k = l.ing.key {
                        Section("Nutrition source") {
                            NavigationLink {
                                NutritionLookupView(purpose: .override(key: k, name: l.info?.name ?? l.ing.text)) { _ in }
                            } label: { Label("Use a specific product (scan, search, label)", systemImage: "barcode.viewfinder") }
                            if user.data.nutritionOverrides[k] != nil {
                                Button("Remove my override", role: .destructive) { user.data.nutritionOverrides[k] = nil }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Swap / I don't have it")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    /// Swaps with their original indices; vegetarian ones first for a vegetarian user.
    private func orderedSwaps(_ info: IngredientInfo) -> [(offset: Int, element: SwapOption)] {
        let all = Array(info.swaps.enumerated())
        guard user.data.isVegetarian else { return all }
        func isVeg(_ s: SwapOption) -> Bool { s.key.map { store.catalog.info($0)?.vegetarian != .no } ?? true }
        return all.filter { isVeg($0.element) } + all.filter { !isVeg($0.element) }
    }

    private func swapRow(_ s: SwapOption, index: Int, selected: Bool) -> some View {
        let impact = calc.swapImpact(recipe, lineKey: lineKey, swapIndex: index, cfg: cfg)
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(s.name).foregroundStyle(.primary)
                if let n = s.note, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary) }
                if impact.recalculated {
                    Text(impactText(impact.delta)).font(.caption.monospacedDigit()).foregroundStyle(Color.accentColor)
                } else {
                    Text("macros not recalculated").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
    }

    private func impactText(_ d: Nutrition) -> String {
        func s(_ v: Double, _ u: String) -> String { (v >= 0 ? "+" : "−") + "\(Int(abs(v).rounded()))" + u }
        return "\(s(d.calories, " kcal")), \(s(d.protein, " g protein"))"
    }
}

struct CompareSheet: View {
    let recipe: Recipe
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let res = user.result(for: recipe, store: store)
        NavigationStack {
            List {
                Section("Whole recipe") {
                    row("Book", res.book)
                    row("Calculated", res.calculated)
                    if res.book == nil { Text("This recipe has no printed macros, so Calculated is used.").font(.footnote).foregroundStyle(.secondary) }
                    if let b = res.book {
                        LabeledContent("Difference", value: signed(res.calculated.calories - b.calories) + " kcal")
                    }
                }
                Section("Per ingredient (one pint)") {
                    ForEach(res.lines.filter { $0.included }) { l in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.displayName).font(.subheadline).lineLimit(2)
                            HStack {
                                Text(l.grams > 0 ? "\(Int(l.grams.rounded())) g" : "— g")
                                Spacer()
                                Text(l.noData && l.info == nil ? "no data" : "\(Int(l.nutrition.calories.rounded())) kcal · \(String(format: "%.1f", l.nutrition.protein)) g protein")
                            }
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Compare")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func signed(_ v: Double) -> String { (v >= 0 ? "+" : "−") + "\(Int(abs(v).rounded()))" }

    @ViewBuilder private func row(_ title: String, _ n: Nutrition?) -> some View {
        if let n {
            LabeledContent(title) {
                Text("\(Int(n.calories.rounded())) kcal · \(Int(n.protein.rounded())) P · \(Int(n.carbs.rounded())) C · \(Int(n.fat.rounded())) F")
                    .font(.footnote.monospacedDigit())
            }
        } else {
            LabeledContent(title, value: "—")
        }
    }
}

/// Explains an estimated amount and lets the user type their own grams (saved per recipe and line).
struct AmountSheet: View {
    let recipe: Recipe
    let line: LineResult
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(line.ing.text).font(.headline)
                    if line.amount == .estimated {
                        Label("≈ \(Int(line.grams.rounded())) g (estimate: \(line.estimateReason ?? "typical use"))", systemImage: "wand.and.stars").foregroundStyle(.orange)
                    }
                } footer: {
                    Text("No amount in the recipe. Macro Kitchen estimated this from typical use. Tap to set your own amount.")
                }
                Section("Your amount") {
                    HStack {
                        TextField(line.grams > 0 ? "\(Int(line.grams.rounded()))" : "grams", text: $text).decimalKeyboard()
                        Text("g").foregroundStyle(.secondary)
                    }
                    Button("Save my amount") {
                        user.setLineGrams(recipe.id, line: line.lineKey, grams: Double(text.replacingOccurrences(of: ",", with: ".")))
                        dismiss()
                    }
                    .disabled((Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0) <= 0)
                    if line.amount == .user {
                        Button("Go back to the estimate", role: .destructive) {
                            user.setLineGrams(recipe.id, line: line.lineKey, grams: nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Amount")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

/// "What it is" plus a highlighted "For you" tip for an ingredient (display only).
struct IngredientNoteSheet: View {
    let title: String
    let note: IngredientNote
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("What it is") { Text(note.what) }
                if let tip = note.forYou, !tip.isEmpty {
                    Section {
                        Label { Text(tip) } icon: { Image(systemName: "lightbulb.fill").foregroundStyle(.orange) }
                            .listRowBackground(Color.orange.opacity(0.12))
                    } header: { Text("For you") }
                }
            }
            .navigationTitle(title)
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
