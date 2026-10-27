import SwiftUI

/// Open Food Facts search / barcode / manual label entry. Saves an override or a custom milk.
struct NutritionLookupView: View {
    enum Purpose {
        case override(key: String, name: String)
        case customMilk
        case customPowder
    }
    enum Mode: String, CaseIterable, Identifiable {
        case search = "Search", scan = "Scan", manual = "Label"
        var id: String { rawValue }
    }
    struct Candidate {
        var name: String
        var brand: String
        var per100g: Nutrition
        var label: String       // "OFF" | "Label"
    }

    let purpose: Purpose
    let onSaved: (BaseLiquid?) -> Void
    var onSavedPowder: (ProteinPowder) -> Void = { _ in }
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .search
    @State private var query = ""
    @State private var results: [OFFProduct] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var candidate: Candidate?
    @State private var saveName = ""
    @State private var servingMl = "240"
    // manual
    @State private var mSize = "100"
    @State private var mUnitMl = true
    @State private var mName = ""
    @State private var m: [String] = ["", "", "", "", "", ""]
    @State private var saved = false

    private var isMilk: Bool { if case .customMilk = purpose { return true } else { return false } }
    private var isPowder: Bool { if case .customPowder = purpose { return true } else { return false } }
    private var modes: [Mode] { BarcodeScanner.isAvailable ? Mode.allCases : [.search, .manual] }

    var body: some View {
        Form {
            Section {
                Picker("Method", selection: $mode) { ForEach(modes) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
            } footer: {
                if case .override(_, let n) = purpose { Text("Use real product numbers for \(n). They replace the built-in values in Calculated mode.") }
                else if isPowder { Text("Find your protein powder and it will appear in the powder picker.") }
                else { Text("Find your milk or shake and it will appear in the milk picker.") }
            }
            switch mode {
            case .search: searchSection
            case .scan: scanSection
            case .manual: manualSection
            }
            if let c = candidate { saveSection(c) }
        }
        .navigationTitle(isMilk ? "Add my milk" : (isPowder ? "Add my powder" : "Product nutrition"))
        .inlineTitle()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .sensoryFeedback(.success, trigger: saved)
    }

    // MARK: sections

    @ViewBuilder private var searchSection: some View {
        Section("Open Food Facts") {
            HStack {
                TextField("Product name", text: $query).noAutocap().submitLabel(.search).onSubmit { Task { await runSearch() } }
                Button("Search") { Task { await runSearch() } }.disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if loading { ProgressView() }
            if let e = errorText { Text(e).font(.footnote).foregroundStyle(.red) }
            ForEach(results) { p in
                Button { pick(p) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).foregroundStyle(.primary)
                        Text("\(p.brand.isEmpty ? "" : p.brand + " · ")\(Int(p.per100g.calories)) kcal, \(Int(p.per100g.protein)) g protein per 100 g")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var scanSection: some View {
        #if os(iOS)
        Section("Point at the barcode") {
            BarcodeScannerView { code in Task { await lookup(code) } }
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .listRowInsets(EdgeInsets())
            if loading { ProgressView() }
            if let e = errorText { Text(e).font(.footnote).foregroundStyle(.red) }
        }
        #else
        Text("Scanning needs an iPhone.")
        #endif
    }

    private var manualSection: some View {
        Section("From the nutrition label") {
            TextField("Product name", text: $mName)
            HStack {
                TextField("Serving size", text: $mSize).decimalKeyboard()
                Picker("Unit", selection: $mUnitMl) { Text("ml").tag(true); Text("g").tag(false) }.pickerStyle(.segmented).frame(maxWidth: 120)
            }
            ForEach(Array(["Calories", "Protein (g)", "Carbs (g)", "Fat (g)", "Sugar (g)", "Fiber (g)"].enumerated()), id: \.offset) { i, label in
                LabeledContent(label) {
                    TextField("0", text: $m[i]).decimalKeyboard().multilineTextAlignment(.trailing)
                }
            }
            Button("Use these numbers") { applyManual() }.disabled(num(mSize) <= 0 || num(m[0]) <= 0 && num(m[1]) <= 0)
        }
    }

    @ViewBuilder private func saveSection(_ c: Candidate) -> some View {
        Section("Per 100 g") {
            MacroRow(n: c.per100g)
            TextField("Name", text: $saveName)
            if isPowder {
                LabeledContent("Scoop (g)") { TextField("30", text: $servingMl).decimalKeyboard().multilineTextAlignment(.trailing) }
            }
            if isMilk {
                LabeledContent("Serving (ml)") { TextField("240", text: $servingMl).decimalKeyboard().multilineTextAlignment(.trailing) }
            }
            Button {
                save(c)
            } label: {
                Label(isMilk ? "Save as my milk" : (isPowder ? "Save as my powder" : "Use for this ingredient"), systemImage: "checkmark.circle.fill")
            }
        }
    }

    // MARK: actions

    private func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }

    private func pick(_ p: OFFProduct) {
        candidate = Candidate(name: p.name, brand: p.brand, per100g: p.per100g, label: "OFF")
        if isPowder { servingMl = "30" }
        saveName = p.name
        errorText = nil
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true; errorText = nil
        do {
            results = try await OpenFoodFacts.search(q)
            if results.isEmpty { errorText = "No results. Try fewer words, or enter the label by hand." }
        } catch { errorText = "Couldn't reach Open Food Facts. Check your connection or enter the label by hand." }
        loading = false
    }

    private func lookup(_ code: String) async {
        loading = true; errorText = nil
        do { pick(try await OpenFoodFacts.product(barcode: code)) }
        catch { errorText = (error as? OFFError)?.errorDescription ?? "Couldn't reach Open Food Facts." }
        loading = false
    }

    private func applyManual() {
        let size = num(mSize)
        let density = mUnitMl ? 1.03 : 1.0
        let n = Nutrition(calories: num(m[0]), protein: num(m[1]), carbs: num(m[2]), fat: num(m[3]), sugar: num(m[4]), fiber: num(m[5]))
        let per100 = NutritionCalculator.per100(fromServing: n, size: size * density)
        candidate = Candidate(name: mName, brand: "", per100g: per100, label: "Label")
        saveName = mName
        if isMilk && mUnitMl { servingMl = String(Int(size)) }
        if isPowder && !mUnitMl { servingMl = String(Int(size)) }
    }

    private func save(_ c: Candidate) {
        let name = saveName.trimmingCharacters(in: .whitespaces).isEmpty ? (c.name.isEmpty ? "My milk" : c.name) : saveName
        switch purpose {
        case .override(let key, _):
            user.data.nutritionOverrides[key] = NutritionOverride(per100g: c.per100g, sourceLabel: c.label, productName: name)
            saved.toggle()
            onSaved(nil)
        case .customPowder:
            let g = max(1, num(servingMl))
            let p = ProteinPowder(id: "custom-" + UUID().uuidString, name: name, brand: c.brand.isEmpty ? nil : c.brand, type: "custom",
                                  scoopGrams: g, perScoop: c.per100g * (g / 100), ingredientKey: nil,
                                  note: "Added from \(c.label == "OFF" ? "Open Food Facts" : "label")")
            user.data.customPowders.append(p)
            saved.toggle()
            onSavedPowder(p)
        case .customMilk:
            let ml = max(1, num(servingMl))
            let l = BaseLiquid(id: "custom-" + UUID().uuidString, name: name, family: "milk", brand: c.brand.isEmpty ? nil : c.brand,
                               servingMl: ml, perServing: c.per100g * (ml * 1.03 / 100), gramsPerMl: 1.03, ingredientKey: nil,
                               note: "Added from \(c.label == "OFF" ? "Open Food Facts" : "label")")
            user.data.customLiquids.append(l)
            saved.toggle()
            onSaved(l)
        }
        dismiss()
    }
}
