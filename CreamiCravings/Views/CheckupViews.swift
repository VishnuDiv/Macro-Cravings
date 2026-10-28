import SwiftUI
#if os(iOS)
import UIKit

// AI check-up screens (HEALTH_SPEC §10b): key setup, run + consent, results, history and compare.

// MARK: key setup (Settings)

struct CheckupSettingsView: View {
    @State private var keys = CheckupEnvironment.keys()
    @State private var input = ""
    @State private var hasKey = false
    @State private var status: String?
    @State private var statusOK = false
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                if hasKey, let m = keys.masked {
                    LabeledContent("API key", value: m)
                    Button("Remove key", role: .destructive) { keys.remove(); hasKey = false; status = nil }
                }
                SecureField(hasKey ? "Paste a new key to replace it" : "Paste your API key (sk-ant-…)", text: $input)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save key") {
                    if keys.save(input) { input = ""; hasKey = true; status = "Saved in this phone's Keychain."; statusOK = true }
                    else { status = "That key is empty."; statusOK = false }
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    test()
                } label: {
                    HStack { Text("Test key"); if testing { Spacer(); ProgressView() } }
                }
                .disabled(!hasKey || testing)
                if let status { Text(status).font(.footnote).foregroundStyle(statusOK ? Color.green : Color.red) }
                Link(destination: URL(string: "https://console.anthropic.com/settings/keys")!) { Label("Get a key at console.anthropic.com", systemImage: "arrow.up.right.square") }
            } header: { Text("Anthropic API key") } footer: {
                Text("The key is stored only in this phone's Keychain (this device only, never backed up or synced). The app works fully without it. The test sends one tiny message and costs a fraction of a cent.")
            }
            Section("What a check-up sends") {
                Text("Only when you tap Send on the review screen: the photos you picked (shrunk, with location and camera data removed), your quiz answers, your current routine and a one-line summary of your last check-up. They go only to api.anthropic.com. No analytics, no other server.")
                    .font(.footnote)
            }
        }
        .navigationTitle("AI check-up").inlineTitle()
        .onAppear { hasKey = keys.hasKey }
    }

    private func test() {
        guard let key = keys.key else { return }
        testing = true; status = nil
        Task {
            do { try await CheckupEnvironment.client().testKey(key); status = "The key works."; statusOK = true }
            catch let e as CheckupError { status = e.message; statusOK = false }
            catch { status = "The test failed."; statusOK = false }
            testing = false
        }
    }
}

// MARK: home: run + history

struct CheckupHomeView: View {
    @Environment(ProgressLibrary.self) private var lib
    @State private var hasKey = CheckupEnvironment.keys().hasKey

    var body: some View {
        List {
            Section {
                NavigationLink { RunCheckupView() } label: { Label("Run check-up", systemImage: "sparkles") }.disabled(!hasKey)
                if !hasKey {
                    NavigationLink { CheckupSettingsView() } label: { Label("Add your API key first", systemImage: "key") }
                }
            } footer: { Text("Optional. You choose Skin, Hair or Both and see exactly what is sent before anything leaves the phone.") }
            Section("History") {
                if lib.checkups.records.isEmpty { Text("No check-ups yet.").foregroundStyle(.secondary) }
                ForEach(lib.checkups.records.reversed()) { r in
                    NavigationLink { CheckupResultView(record: r) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.date.formatted(date: .abbreviated, time: .omitted) + " · " + r.scope.capitalized).font(.headline)
                            Text(r.result.overall.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            Text(CheckupPricing.label(r.cost)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in let ids = idx.map { lib.checkups.records.reversed()[$0].id }; ids.forEach { lib.checkups.delete($0) } }
            }
            Section { NavigationLink { CheckupSettingsView() } label: { Label("API key and privacy", systemImage: "key") } }
        }
        .navigationTitle("AI check-up").inlineTitle()
        .onAppear { hasKey = CheckupEnvironment.keys().hasKey }
    }
}

// MARK: run

struct RunCheckupView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(ProgressLibrary.self) private var lib
    @State private var scope = "both"
    @State private var chosen: Set<PhotoSeries> = []
    @State private var entryFor: [PhotoSeries: UUID] = [:]
    @State private var showConsent = false
    @State private var runner = CheckupRunner()
    @State private var loaded = false

    private var candidates: [PhotoSeries] { CheckupPhotos.priority(scope).filter { !lib.entries($0).isEmpty } }

    private func entry(for s: PhotoSeries) -> ProgressEntry? {
        let list = lib.entries(s)
        return entryFor[s].flatMap { id in list.first { $0.id == id } } ?? list.last
    }
    private var selected: [ProgressEntry] { CheckupPhotos.priority(scope).filter { chosen.contains($0) }.compactMap(entry(for:)) }

    private func preselect() {
        var latest: [PhotoSeries: ProgressEntry] = [:]
        for s in candidates { latest[s] = lib.entries(s).last }
        chosen = Set(CheckupPhotos.preselect(scope: scope, latest: latest).map(\.series))
        entryFor = [:]
    }

    var body: some View {
        Group {
            switch runner.state {
            case .idle: form
            case .preparing, .waiting: running
            case .done(let rec): CheckupResultView(record: rec)
            case .failed(let e): failed(e)
            }
        }
        .navigationTitle("Run check-up").inlineTitle()
        .onAppear { if !loaded { loaded = true; preselect() } }
        .sheet(isPresented: $showConsent) {
            CheckupConsentSheet(entries: selected, contextJSON: contextJSON) {
                showConsent = false
                runner.start(scope: scope, entries: selected, lib: lib, user: user, content: (store.catalog.skincare, store.catalog.haircare))
            }
        }
    }

    private var contextJSON: String {
        CheckupContext.json(scope: scope, user: user.data, skincare: store.catalog.skincare, haircare: store.catalog.haircare, previous: lib.checkups.records.last)
    }

    private var form: some View {
        Form {
            Section("What to check") {
                Picker("Scope", selection: $scope) { Text("Skin").tag("skin"); Text("Hair").tag("hair"); Text("Both").tag("both") }.pickerStyle(.segmented)
                    .onChange(of: scope) { _, _ in preselect() }
            }
            Section {
                if candidates.isEmpty { Text("Take a progress photo first.").foregroundStyle(.secondary) }
                ForEach(candidates) { s in
                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(get: { chosen.contains(s) }, set: { if $0 { chosen.insert(s) } else { chosen.remove(s) } })) {
                            HStack(spacing: 10) {
                                if let e = entry(for: s), let img = ProgressImage.thumbnail(lib.store.photoURL(e), maxPixel: 120) {
                                    Image(uiImage: img).resizable().scaledToFill().frame(width: 44, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title)
                                    if let e = entry(for: s) { Text(e.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        .disabled(!chosen.contains(s) && chosen.count >= CheckupPhotos.maxPhotos)
                        if lib.entries(s).count > 1 {
                            Menu {
                                ForEach(lib.entries(s).reversed()) { e in
                                    Button(e.date.formatted(date: .abbreviated, time: .omitted)) { entryFor[s] = e.id }
                                }
                            } label: { Image(systemName: "calendar") }
                        }
                    }
                }
            } header: { Text("Photos (up to \(CheckupPhotos.maxPhotos))") } footer: { Text("The latest photo of each series is picked for you. Change the date with the calendar button.") }
            Section {
                Button { showConsent = true } label: { Text("Review what is sent").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(selected.isEmpty)
            }
        }
    }

    private var running: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(runnerPreparing ? "Preparing photos…" : "Analysing… this can take a minute or two.").foregroundStyle(.secondary)
            Button("Cancel", role: .cancel) { runner.cancel() }.buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var runnerPreparing: Bool { if case .preparing = runner.state { return true }; return false }

    private func failed(_ e: CheckupError) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
            Text(e.message).multilineTextAlignment(.center).padding(.horizontal, 24)
            HStack {
                Button("Try again") { runner.reset(); showConsent = true }.buttonStyle(.borderedProminent)
                Button("Change photos") { runner.reset() }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CheckupConsentSheet: View {
    let entries: [ProgressEntry]
    let contextJSON: String
    let send: () -> Void
    @Environment(ProgressLibrary.self) private var lib
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(entries) { e in
                                VStack(spacing: 4) {
                                    if let img = ProgressImage.thumbnail(lib.store.photoURL(e), maxPixel: 300) {
                                        Image(uiImage: img).resizable().scaledToFill().frame(width: 90, height: 120).clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    Text(e.series.title).font(.caption2)
                                    Text(e.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: { Text("\(entries.count) photo\(entries.count == 1 ? "" : "s") will be sent") } footer: {
                    Text("Each is shrunk to 1568 px on the long edge and re-saved as a new JPEG, so location, camera and time data are removed.")
                }
                Section("Also sent") {
                    Label("Your quiz answers, current routine and last check-up summary", systemImage: "list.bullet.clipboard")
                    DisclosureGroup("Show that text") { Text(contextJSON).font(.caption.monospaced()).textSelection(.enabled) }
                }
                Section {
                    Label("Sent only to api.anthropic.com, only when you tap Send, and only what is listed here.", systemImage: "lock")
                    Label("Costs about $0.05 to $0.15 on your Anthropic account.", systemImage: "dollarsign.circle")
                }
                .font(.footnote)
            }
            .navigationTitle("Review").inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Button { send() } label: { Text("Send \(entries.count) photo\(entries.count == 1 ? "" : "s") and run").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).padding()
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: results

struct SeverityChip: View {
    let severity: String
    let confidence: String
    private var color: Color { switch severity { case "severe": return .red; case "moderate": return .orange; case "mild": return .yellow; default: return .gray } }
    var body: some View {
        Text("\(severity.capitalized) · \(confidence) confidence").font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule()).foregroundStyle(color == .yellow ? Color.orange : color)
    }
}

struct CheckupResultView: View {
    let record: CheckupRecord
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(ProgressLibrary.self) private var lib

    private var r: CheckupResult { record.result }

    var body: some View {
        List {
            Section("Summary") {
                Text(r.overall.summary)
                Text("Next check-up in about \(r.overall.nextCheckupWeeks) week\(r.overall.nextCheckupWeeks == 1 ? "" : "s").").font(.footnote).foregroundStyle(.secondary)
                if let prev = lib.checkups.previous(before: record) {
                    NavigationLink { CheckupCompareView(old: prev, new: record) } label: { Label("Compare with last check-up", systemImage: "arrow.left.arrow.right") }
                }
            }
            if r.seeDermatologist.recommended {
                Section {
                    Label { VStack(alignment: .leading, spacing: 4) { Text("Worth seeing a dermatologist").font(.headline); Text(r.seeDermatologist.reason).font(.subheadline) } } icon: { Image(systemName: "cross.case").foregroundStyle(.red) }
                }
            }
            if let skin = r.skin {
                observations("Skin: what I see", skin.observations)
                if !skin.likelyDrivers.isEmpty { Section("Likely drivers") { ForEach(skin.likelyDrivers, id: \.self) { Text($0) } } }
                Section("Skin: do this") {
                    ForEach(Array(skin.recommendations.enumerated()), id: \.offset) { _, rec in skinRec(rec) }
                }
                if !skin.avoid.isEmpty { Section("Avoid") { ForEach(skin.avoid, id: \.self) { Label($0, systemImage: "nosign") } } }
            }
            if let hair = r.hair {
                Section("Hair: stage") { Text(hair.norwoodEstimate) }
                observations("Hair: what I see", hair.observations)
                Section("Hair: do this") {
                    ForEach(Array(hair.recommendations.enumerated()), id: \.offset) { _, rec in hairRec(rec) }
                }
                let styles = hair.styleIds.compactMap { id in store.catalog.haircare?.styles.first { $0.id == id } }
                if !styles.isEmpty {
                    Section("Styles") {
                        ForEach(styles) { s in NavigationLink(s.name) { StyleDetailView(match: StyleMatch(style: s, score: 0, reasons: [])) } }
                    }
                }
            }
            if !r.photoQuality.ok || !r.photoQuality.issues.isEmpty {
                Section("Photo-quality tips") { ForEach(r.photoQuality.issues, id: \.self) { Label($0, systemImage: "camera.metering.unknown") } }
            }
            Section {
                LabeledContent("Cost", value: CheckupPricing.label(record.cost))
                Text("\(record.usage.inputTokens.formatted()) tokens in, \(record.usage.outputTokens.formatted()) out · \(record.photos.count) photo\(record.photos.count == 1 ? "" : "s") · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Check-up").inlineTitle()
    }

    private func observations(_ title: String, _ list: [CheckupObservation]) -> some View {
        Section(title) {
            if list.isEmpty { Text("Nothing notable.").foregroundStyle(.secondary) }
            ForEach(Array(list.enumerated()), id: \.offset) { _, o in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(o.area).font(.headline); Spacer(); SeverityChip(severity: o.severity, confidence: o.confidence) }
                    Text(o.finding).font(.subheadline)
                }
            }
        }
    }

    private func priorityLabel(_ p: String) -> some View {
        Text(p.capitalized).font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background((p == "high" ? Color.red : p == "medium" ? Color.orange : Color.gray).opacity(0.18), in: Capsule())
    }

    private func skinRec(_ rec: CheckupSkinRec) -> some View {
        let product = CheckupActions.product(for: rec, skincare: store.catalog.skincare)
        let have = rec.activeId.map { a in user.data.products.contains { $0.activeId == a } } ?? false
        return VStack(alignment: .leading, spacing: 5) {
            HStack { Text(rec.action).font(.headline); Spacer(); priorityLabel(rec.priority) }
            Text("\(rec.frequency) · \(rec.why)").font(.subheadline).foregroundStyle(.secondary)
            if let product {
                if have { Label("In your routine", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green) }
                else { Button { CheckupActions.add(product, to: &user.data.products) } label: { Label("Add to routine", systemImage: "plus.circle") }.buttonStyle(.bordered).controlSize(.small) }
            }
        }
    }

    private func hairRec(_ rec: CheckupHairRec) -> some View {
        let item = CheckupActions.hairItem(for: rec, haircare: store.catalog.haircare)
        let have = rec.interventionId.map { i in user.data.hairItems.contains { $0.interventionId == i } } ?? false
        return VStack(alignment: .leading, spacing: 5) {
            HStack { Text(rec.action).font(.headline); Spacer(); priorityLabel(rec.priority) }
            Text(rec.why).font(.subheadline).foregroundStyle(.secondary)
            if let item {
                if have { Label("In your routine", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green) }
                else { Button { CheckupActions.add(item, to: &user.data.hairItems) } label: { Label("Add to routine", systemImage: "plus.circle") }.buttonStyle(.bordered).controlSize(.small) }
            }
        }
    }
}

struct CheckupCompareView: View {
    let old: CheckupRecord
    let new: CheckupRecord

    var body: some View {
        let changes = CheckupDiff.compare(old: old.result, new: new.result)
        List {
            Section {
                Text("\(old.date.formatted(date: .abbreviated, time: .omitted)) → \(new.date.formatted(date: .abbreviated, time: .omitted))").font(.subheadline)
                Text(new.result.overall.summary).font(.footnote).foregroundStyle(.secondary)
            }
            Section("Changes") {
                if changes.isEmpty { Text("No changes since the last check-up.").foregroundStyle(.secondary) }
                ForEach(Array(changes.enumerated()), id: \.offset) { _, c in
                    HStack {
                        Image(systemName: c.better == true ? "arrow.down.right.circle.fill" : c.better == false ? "arrow.up.right.circle.fill" : "circle.dashed")
                            .foregroundStyle(c.better == true ? Color.green : c.better == false ? Color.red : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) { Text(c.area).font(.headline); Text(c.text).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("Compare").inlineTitle()
    }
}
#endif
