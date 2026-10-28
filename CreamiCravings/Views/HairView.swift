import SwiftUI

/// Hair tab: profile quiz, ranked styles, hair-loss guide with evidence grades, plans, myths and the hair routine.
struct HairView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @State private var showQuiz = false

    private var content: HaircareContent? { store.catalog.haircare }
    private var profile: HairProfile { user.data.hairProfile }

    var body: some View {
        NavigationStack {
            List {
                Section { ModeSwitch().listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
                if let c = content {
                    profileSection(c)
                    if profile.isComplete { stylesSection(c) }
                    routineSection(c)
                    lossSection(c)
                    Section("Guides") {
                        ForEach(c.guides) { g in NavigationLink { GuideDetailView(guide: g) } label: { Label(g.title, systemImage: g.icon) } }
                    }
                    Section { HealthNote(text: "Hair-loss treatments such as finasteride and minoxidil are medical decisions. Talk to a dermatologist before starting, changing or stopping one.") }
                        .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView("Hair content not loaded", systemImage: "comb")
                }
            }
            .navigationTitle("Hair")
            .sheet(isPresented: $showQuiz) { HairQuizSheet() }
        }
    }

    private func profileSection(_ c: HaircareContent) -> some View {
        Section("Your hair") {
            if profile.isComplete {
                VStack(alignment: .leading, spacing: 4) {
                    Text([profile.hairType, profile.thickness, profile.length].compactMap { $0 }.map(Pretty.text).joined(separator: ", ")).font(.headline)
                    Text("Face shape: \(Pretty.text(profile.faceShape ?? ""))").font(.subheadline).foregroundStyle(.secondary)
                    if let n = profile.norwood, let s = c.norwood.first(where: { $0.stage == n }) {
                        let first = s.description.split(separator: ".").first.map(String.init) ?? ""
                        Text("Hairline: Norwood \(n)" + (first.isEmpty ? "" : " (\(first.prefix(1).lowercased() + first.dropFirst()))")).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Button("Edit answers") { showQuiz = true }
            } else {
                Button { showQuiz = true } label: { Label("Take the hair quiz", systemImage: "list.bullet.clipboard") }
            }
        }
    }

    private func stylesSection(_ c: HaircareContent) -> some View {
        let ranked = HairStyles.rank(profile, content: c)
        return Section("Styles for you") {
            ForEach(ranked.prefix(8)) { m in
                NavigationLink { StyleDetailView(match: m) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(m.style.name).font(.headline)
                            if m.style.receding == "great" { Label("Hairline-friendly", systemImage: "checkmark.seal.fill").labelStyle(.iconOnly).foregroundStyle(.green) }
                        }
                        Text(m.reasons.joined(separator: ", ").capitalizedFirst).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if ranked.isEmpty { Text("No styles match these answers yet. Try changing length or hair type.").font(.footnote).foregroundStyle(.secondary) }
            else if ranked.count > 8 { NavigationLink("All \(ranked.count) styles") { AllStylesView(matches: ranked) } }
        }
    }

    private func routineSection(_ c: HaircareContent) -> some View {
        Section("My hair routine") {
            ForEach(user.data.hairItems) { it in
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.title)
                    Text(Pretty.text(it.schedule)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .onDelete { user.data.hairItems.remove(atOffsets: $0) }
            NavigationLink { HairRoutinePicker() } label: { Label("Add to my routine", systemImage: "plus.circle") }
            Text("Items here show up on your Today checklist on the days they are due.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func lossSection(_ c: HaircareContent) -> some View {
        Section("Hair-loss guide") {
            NavigationLink { HairLossGuideView() } label: { Label("What works, ranked by evidence", systemImage: "chart.bar.doc.horizontal") }
            NavigationLink { HairPlansView() } label: { Label("Plans by Norwood stage", systemImage: "list.number") }
            NavigationLink { MythsView() } label: { Label("Myths and facts", systemImage: "questionmark.bubble") }
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

struct StyleDetailView: View {
    let match: StyleMatch
    var body: some View {
        let s = match.style
        List {
            Section { Text(s.description) }
            if !match.reasons.isEmpty { Section("Why it fits") { Text(match.reasons.joined(separator: ", ").capitalizedFirst) } }
            Section("Ask your barber for") { Text(s.barberAsk).font(.body) }
            if !s.productTips.isEmpty { Section("Styling") { Text(s.productTips) } }
            Section("Upkeep") { Text("Maintenance: \(s.maintenance)") }
            if s.receding == "great" { Section { HealthNote(text: "Works well with a receding hairline.", symbol: "checkmark.seal") }.listRowBackground(Color.clear) }
        }
        .navigationTitle(s.name).inlineTitle()
    }
}

struct AllStylesView: View {
    let matches: [StyleMatch]
    var body: some View {
        List(matches) { m in NavigationLink(m.style.name) { StyleDetailView(match: m) } }.navigationTitle("Styles")
    }
}

struct HairQuizSheet: View {
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss
    @State private var p = HairProfile()
    @State private var showHow = false
    private let concerns = ["receding_hairline", "thinning_crown", "shedding", "dandruff", "dryness", "frizz"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Hair type") { SingleChips(options: ["straight", "wavy", "curly", "coily"].map { ($0, $0.capitalized) }, selection: $p.hairType) }
                Section("Thickness") { SingleChips(options: ["fine", "medium", "thick"].map { ($0, $0.capitalized) }, selection: $p.thickness) }
                Section("Length") { SingleChips(options: ["short", "medium", "long"].map { ($0, $0.capitalized) }, selection: $p.length) }
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                        ForEach(store.catalog.haircare?.faceShapes ?? []) { f in
                            Button { p.faceShape = (p.faceShape == f.id) ? nil : f.id } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: f.symbol).font(.title)
                                    Text(f.name).font(.caption.weight(.semibold))
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(p.faceShape == f.id ? Color.accentColor : Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(p.faceShape == f.id ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button("How to tell your face shape") { showHow.toggle() }
                    if showHow {
                        ForEach(store.catalog.haircare?.howToMeasure ?? [], id: \.self) { Text($0).font(.footnote) }
                        ForEach(store.catalog.haircare?.faceShapes ?? []) { f in
                            Text("\(f.name): \(f.howToTell)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Face shape") }
                Section("What bothers you?") { MultiChips(options: concerns.map { ($0, Pretty.text($0)) }, selection: $p.concerns) }
                Section {
                    ForEach(store.catalog.haircare?.norwood ?? []) { n in
                        Button { p.norwood = (p.norwood == n.stage) ? nil : n.stage } label: {
                            HStack(alignment: .top) {
                                Image(systemName: p.norwood == n.stage ? "largecircle.fill.circle" : "circle").foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(n.stage). \(n.label)").font(.subheadline.weight(.semibold))
                                    Text(n.description).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: { Text("Hairline stage (Norwood scale)") } footer: { Text("Your own best guess. Skip it if your hairline has not changed.") }
            }
            .navigationTitle("Hair quiz").inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { user.data.hairProfile = p; dismiss() }.disabled(p.hairType == nil || p.faceShape == nil) }
            }
            .onAppear { p = user.data.hairProfile }
        }
    }
}

struct HairLossGuideView: View {
    @Environment(RecipeStore.self) private var store
    var body: some View {
        List {
            Section { HealthNote(text: "Ranked by how strong the evidence is (A strong, D none). Prescription options need a doctor.") }.listRowBackground(Color.clear)
            ForEach((store.catalog.haircare?.interventions ?? []).sorted { $0.rank < $1.rank }) { i in
                NavigationLink { InterventionDetailView(item: i) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(i.name).font(.headline); Spacer(); EvidenceBadge(grade: i.evidence) }
                        Text(i.type == "Rx" ? "Prescription" : i.type).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("What works").inlineTitle()
    }
}

struct InterventionDetailView: View {
    let item: HairIntervention
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user

    var body: some View {
        List {
            Section { HStack { EvidenceBadge(grade: item.evidence); Text(item.type == "Rx" ? "Prescription" : item.type).font(.footnote).foregroundStyle(.secondary); if !item.cost.isEmpty { Text("· \(item.cost)").font(.footnote).foregroundStyle(.secondary) } } }
            if item.needsDoctor { Section { HealthNote(text: item.rxNote ?? "Talk to a dermatologist before starting this.") }.listRowBackground(Color.clear) }
            row("What it does", item.whatItDoes)
            row("How to use", item.howToUse)
            row("When to expect results", item.whenToExpect)
            row("Side effects", item.sideEffects)
            row("Regrow or maintain", item.regrowVsMaintain)
            let templates = (store.catalog.haircare?.routineItems ?? []).filter { $0.linkedIntervention == item.id }
            if !templates.isEmpty {
                Section("Add to Today") {
                    ForEach(templates) { t in
                        let have = user.data.hairItems.contains { $0.interventionId == item.id && $0.title == t.name }
                        Button {
                            if !have { user.data.hairItems.append(HairRoutineItem(title: t.name, interventionId: item.id, schedule: t.schedule, note: t.note)) }
                        } label: { Label(have ? "\(t.name) (added)" : t.name, systemImage: have ? "checkmark.circle.fill" : "plus.circle") }
                    }
                }
            }
        }
        .navigationTitle(item.name).inlineTitle()
    }
    @ViewBuilder private func row(_ title: String, _ text: String) -> some View {
        if !text.isEmpty { Section(title) { Text(text) } }
    }
}

struct HairPlansView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    var body: some View {
        let mine = user.data.hairProfile.norwood
        List(store.catalog.haircare?.plans ?? []) { p in
            Section {
                if !p.goal.isEmpty { Text(p.goal).font(.subheadline) }
                ForEach(Array(p.steps.enumerated()), id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.catalog.haircare?.intervention(s.interventionId)?.name ?? Pretty.text(s.interventionId)).font(.body.weight(.medium))
                        Text("\(Pretty.text(s.priority)): \(s.how)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !p.notes.isEmpty { Text(p.notes).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("\(p.name) (Norwood \(p.norwoodMin)-\(p.norwoodMax))" + ((mine.map { (p.norwoodMin...p.norwoodMax).contains($0) } ?? false) ? "  ·  fits you" : ""))
            }
        }
        .navigationTitle("Plans").inlineTitle()
    }
}

struct MythsView: View {
    @Environment(RecipeStore.self) private var store
    var body: some View {
        List(store.catalog.haircare?.myths ?? [], id: \.myth) { m in
            VStack(alignment: .leading, spacing: 4) {
                Text("Myth: \(m.myth)").font(.subheadline.weight(.semibold))
                Text(m.truth).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Myths and facts").inlineTitle()
    }
}

struct HairRoutinePicker: View {
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""
    var body: some View {
        List {
            Section("Suggested") {
                ForEach(store.catalog.haircare?.routineItems ?? []) { t in
                    let have = user.data.hairItems.contains { $0.title == t.name }
                    Button {
                        if !have { user.data.hairItems.append(HairRoutineItem(title: t.name, interventionId: t.linkedIntervention, schedule: t.schedule, note: t.note)) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(t.name); Spacer(); if have { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } }
                            Text("\(Pretty.text(t.schedule))\(t.note.isEmpty ? "" : " · " + t.note)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Your own") {
                TextField("Name", text: $custom)
                Button("Add daily item") {
                    let t = custom.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { user.data.hairItems.append(HairRoutineItem(title: t)); custom = "" }
                }
            }
        }
        .navigationTitle("Add to routine").inlineTitle()
    }
}
