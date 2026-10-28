import SwiftUI

/// Skin tab: profile quiz, routine from templates, my products, conflict warnings, active ingredients and guides.
struct SkinView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @State private var showQuiz = false
    @State private var editing: SkinProduct?
    @State private var adding = false

    private var content: SkincareContent? { store.catalog.skincare }
    private var profile: SkinProfile { user.data.skinProfile }

    var body: some View {
        NavigationStack {
            List {
                Section { ModeSwitch().listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
                if let c = content {
                    profileSection
                    if profile.isComplete { suggestedSection(c) }
                    routineSection(c)
                    productsSection(c)
                    activesSection(c)
                    guidesSection(c)
                    Section { HealthNote(text: "General skincare information, not medical advice. For persistent acne, a changing mole or a prescription retinoid, see a dermatologist.") }
                        .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView("Skin content not loaded", systemImage: "face.smiling")
                }
            }
            .navigationTitle("Skin")
            .sheet(isPresented: $showQuiz) { SkinQuizSheet() }
            .sheet(item: $editing) { p in ProductEditor(product: p, isNew: false) }
            .sheet(isPresented: $adding) { ProductEditor(product: SkinProduct(name: "", step: "treatment"), isNew: true) }
        }
    }

    private var profileSection: some View {
        Section("Your skin") {
            if profile.isComplete {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Pretty.text(profile.skinType ?? "")).font(.headline)
                    if !profile.concerns.isEmpty { Text(profile.concerns.sorted().map(Pretty.text).joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary) }
                    if let s = profile.sun { Text("Sun exposure: \(s)").font(.footnote).foregroundStyle(.secondary) }
                }
                Button("Edit answers") { showQuiz = true }
            } else {
                Button { showQuiz = true } label: { Label("Take the 1-minute skin quiz", systemImage: "list.bullet.clipboard") }
            }
        }
    }

    private func suggestedSection(_ c: SkincareContent) -> some View {
        let ranked = SkinRoutine.templates(for: profile, content: c).prefix(3)
        return Section("Routines for you") {
            ForEach(Array(ranked)) { t in
                NavigationLink { RoutineDetailView(template: t) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).font(.headline)
                        Text(t.description).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            NavigationLink("All routines") { AllRoutinesView() }
        }
    }

    @ViewBuilder private func routineSection(_ c: SkincareContent) -> some View {
        let warnings = SkinRoutine.conflicts(products: user.data.products, content: c)
        Section("My routine") {
            if user.data.products.isEmpty {
                Text("Pick a routine above, or add the products you already use.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(["am", "pm"], id: \.self) { period in
                let list = user.data.products.filter { $0.period == period || $0.period == "both" }
                if !list.isEmpty {
                    Text(period == "am" ? "Morning" : "Evening").font(.subheadline.weight(.bold))
                    ForEach(list) { p in
                        Button { editing = p } label: { productRow(p, c) }.buttonStyle(.plain)
                    }
                }
            }
            ForEach(warnings) { w in ConflictRow(w: w, content: c) }
            if user.data.products.contains(where: { $0.frequency == "ramp-up" }) {
                HealthNote(text: rampText(c), symbol: "calendar.badge.clock")
            }
        }
    }

    private func rampText(_ c: SkincareContent) -> String {
        guard let p = user.data.products.first(where: { $0.frequency == "ramp-up" }) else { return "" }
        let w = SkinRoutine.weeks(from: p.startedAt, to: Date())
        let n = SkinRoutine.rampNights(weeksSinceStart: w, ramp: c.rampUps["retinoid"] ?? [])
        return "\(p.name) ramp-up, week \(w + 1): \(n) night\(n == 1 ? "" : "s") this week."
    }

    private func productRow(_ p: SkinProduct, _ c: SkincareContent) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name.isEmpty ? Pretty.step(p.step) : p.name).font(.body)
                Text([Pretty.step(p.step), p.activeId.flatMap { c.active($0)?.name }, frequencyText(p)].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
    }

    private func frequencyText(_ p: SkinProduct) -> String {
        switch p.frequency {
        case "ramp-up": return "ramp-up"
        case "daily": return "daily"
        default: return Pretty.days(p.weekdays)
        }
    }

    private func productsSection(_ c: SkincareContent) -> some View {
        Section("My products") {
            Button { adding = true } label: { Label("Add a product", systemImage: "plus.circle") }
            ForEach(user.data.products) { p in
                Button { editing = p } label: { productRow(p, c) }.buttonStyle(.plain)
            }
            .onDelete { user.data.products.remove(atOffsets: $0) }
        }
    }

    private func activesSection(_ c: SkincareContent) -> some View {
        Section("Ingredients explained") {
            ForEach(c.actives) { a in
                NavigationLink { ActiveDetailView(active: a) } label: {
                    HStack { Text(a.name); Spacer(); EvidenceBadge(grade: a.evidence) }
                }
            }
        }
    }

    private func guidesSection(_ c: SkincareContent) -> some View {
        Section("Guides") {
            ForEach(c.guides) { g in
                NavigationLink { GuideDetailView(guide: g) } label: { Label(g.title, systemImage: g.icon) }
            }
        }
    }
}

struct ConflictRow: View {
    let w: ConflictWarning
    let content: SkincareContent
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: w.severity == "caution" ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(w.severity == "caution" ? Color.orange : Color.blue)
            Text(w.message).font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var title: String {
        if w.a == "*new_active" || w.b == "*new_active" { return "Too many new actives at once" }
        let names = [w.a, w.b].map { content.active($0)?.name ?? Pretty.text($0) }.joined(separator: " + ")
        let when = w.period.isEmpty ? "" : (w.period == "am" ? " (morning)" : " (evening)")
        return names + when
    }
}

struct SkinQuizSheet: View {
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss
    @State private var p = SkinProfile()
    private let concerns = ["acne", "oil", "dryness", "dark_spots", "texture", "redness", "aging", "dark_circles"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Skin type") {
                    SingleChips(options: ["oily", "dry", "combination", "normal", "sensitive"].map { ($0, $0.capitalized) }, selection: $p.skinType)
                    Text("Unsure? A clean, bare face after an hour: shiny all over is oily, tight is dry, shiny only in the T-zone is combination, stinging with most products is sensitive.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("What do you want to work on?") {
                    MultiChips(options: concerns.map { ($0, Pretty.text($0)) }, selection: $p.concerns)
                }
                Section("Sun exposure on a normal day") {
                    SingleChips(options: [("low", "Mostly indoors"), ("moderate", "Some"), ("high", "A lot")], selection: $p.sun)
                }
            }
            .navigationTitle("Skin quiz").inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { user.data.skinProfile = p; dismiss() }.disabled(p.skinType == nil) }
            }
            .onAppear { p = user.data.skinProfile }
        }
    }
}

struct AllRoutinesView: View {
    @Environment(RecipeStore.self) private var store
    var body: some View {
        List(store.catalog.skincare?.routines ?? []) { t in
            NavigationLink { RoutineDetailView(template: t) } label: {
                VStack(alignment: .leading, spacing: 2) { Text(t.name).font(.headline); Text(t.description).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
        .navigationTitle("Routines")
    }
}

struct RoutineDetailView: View {
    let template: SkinRoutineTemplate
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @State private var confirm = false

    var body: some View {
        List {
            Section { Text(template.description) }
            ForEach([("Morning", template.am), ("Evening", template.pm)], id: \.0) { title, steps in
                Section(title) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(s)).font(.body.weight(.medium))
                            Text([s.frequency == "daily" ? nil : Pretty.text(s.frequency), s.note.isEmpty ? nil : s.note].compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button { confirm = true } label: { Label("Use this routine", systemImage: "checkmark.circle.fill") }
            } footer: { Text("Adds these steps to My products so you can swap in the ones you own. Your current list is replaced.") }
        }
        .navigationTitle(template.name).inlineTitle()
        .confirmationDialog("Replace My products with this routine?", isPresented: $confirm) {
            Button("Use this routine") { apply() }
        }
    }

    private func label(_ s: RoutineStep) -> String {
        s.activeId.flatMap { store.catalog.skincare?.active($0)?.name } ?? Pretty.step(s.step)
    }

    private func apply() {
        var out: [SkinProduct] = []
        let now = Date()
        for (period, steps) in [("am", template.am), ("pm", template.pm)] {
            for s in steps {
                var p = SkinProduct(name: s.activeId.flatMap { store.catalog.skincare?.active($0)?.name } ?? "", step: s.step)
                p.activeId = s.activeId; p.period = period; p.startedAt = now
                switch s.frequency {
                case "ramp-up": p.frequency = "ramp-up"
                case "2-3x-week": p.frequency = "2-3x"; p.weekdays = [2, 4, 6]
                case "alternate-nights": p.frequency = "alternate"; p.weekdays = period == "pm" ? [2, 4, 6] : [2, 4, 6]
                case "as-needed": p.frequency = "as-needed"
                default: p.frequency = "daily"
                }
                out.append(p)
            }
        }
        // Two alternate-night products take opposite nights so they never share one.
        var flip = false
        for i in out.indices where out[i].frequency == "alternate" { if flip { out[i].weekdays = [3, 5, 7] }; flip.toggle() }
        user.data.products = out
        user.data.skinRoutineId = template.id
        user.data.skinRoutineStart = now
    }
}

struct ActiveDetailView: View {
    let active: SkinActive
    var body: some View {
        List {
            Section { HStack { EvidenceBadge(grade: active.evidence); Text(active.otc ? "Over the counter" : "Prescription") .font(.footnote).foregroundStyle(.secondary) } }
            row("What it does", active.whatItDoes)
            row("How to start", active.howToStart)
            row("When to expect results", active.whenToExpect)
            row("Side effects", active.sideEffects)
            if let n = active.rxNote { Section { HealthNote(text: n) }.listRowBackground(Color.clear) }
        }
        .navigationTitle(active.name).inlineTitle()
    }
    @ViewBuilder private func row(_ title: String, _ text: String) -> some View {
        if !text.isEmpty { Section(title) { Text(text) } }
    }
}

struct ProductEditor: View {
    @State var product: SkinProduct
    let isNew: Bool
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss
    private let steps = ["cleanser", "treatment", "moisturizer", "spf", "spot", "other"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $product.name)
                    TextField("Brand (optional)", text: $product.brand)
                    Picker("Step", selection: $product.step) { ForEach(steps, id: \.self) { Text(Pretty.step($0)).tag($0) } }
                    Picker("Main active", selection: Binding(get: { product.activeId ?? "" }, set: { product.activeId = $0.isEmpty ? nil : $0 })) {
                        Text("None").tag("")
                        ForEach(store.catalog.skincare?.actives ?? []) { Text($0.name).tag($0.id) }
                    }
                }
                Section("When") {
                    Picker("Time of day", selection: $product.period) { Text("Morning").tag("am"); Text("Evening").tag("pm"); Text("Both").tag("both") }
                    Picker("How often", selection: $product.frequency) {
                        Text("Daily").tag("daily"); Text("2-3 times a week").tag("2-3x"); Text("Weekly").tag("weekly"); Text("Alternate nights").tag("alternate")
                        if isRetinoid { Text("Retinoid ramp-up").tag("ramp-up") }
                        Text("As needed").tag("as-needed")
                    }
                    if ["2-3x", "weekly", "alternate"].contains(product.frequency) { WeekdayPicker(days: $product.weekdays) }
                    DatePicker("Started", selection: $product.startedAt, in: ...Date(), displayedComponents: .date)
                }
                if !isNew {
                    Section { Button("Delete product", role: .destructive) { user.data.products.removeAll { $0.id == product.id }; dismiss() } }
                }
            }
            .navigationTitle(isNew ? "Add product" : "Edit product").inlineTitle()
            .onChange(of: product.frequency) { _, f in
                switch f { case "2-3x", "alternate": if product.weekdays.isEmpty { product.weekdays = [2, 4, 6] }; case "weekly": product.weekdays = [product.weekdays.first ?? 2]; default: product.weekdays = [] }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(product.name.trimmingCharacters(in: .whitespaces).isEmpty && product.activeId == nil)
                }
            }
        }
    }

    private var isRetinoid: Bool { store.catalog.skincare?.active(product.activeId)?.isRetinoid == true }

    private func save() {
        if product.name.trimmingCharacters(in: .whitespaces).isEmpty { product.name = store.catalog.skincare?.active(product.activeId)?.name ?? Pretty.step(product.step) }
        if isNew { user.data.products.append(product) }
        else if let i = user.data.products.firstIndex(where: { $0.id == product.id }) { user.data.products[i] = product }
        dismiss()
    }
}
