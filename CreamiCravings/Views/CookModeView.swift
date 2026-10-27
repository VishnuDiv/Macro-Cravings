import SwiftUI

struct CookModeView: View {
    let request: CookRequest
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    enum Page: Hashable { case checklist, step(Int), rate }

    @State private var pageIndex = 0
    @State private var forward = true
    @State private var checked: Set<String> = []
    @State private var rating = 0
    @State private var note = ""
    @State private var finished = false

    private var recipe: Recipe? { store.recipeByID[request.recipeId].map { user.effectiveRecipe($0, catalog: store.catalog) } }

    private var pages: [Page] {
        guard let r = recipe else { return [] }
        var p: [Page] = []
        let start = request.skipChecklist ? CookModeView.firstPostFreezeStep(r) : 0
        if !request.skipChecklist { p.append(.checklist) }
        p += (start..<r.instructions.count).map { Page.step($0) }
        p.append(.rate)
        return p
    }

    /// Index of the instruction that follows the "freeze" step (usually "run your pint under hot water").
    static func firstPostFreezeStep(_ r: Recipe) -> Int {
        let hints = ["hot water", "run your pint", "remove", "spin", "process"]
        for (i, s) in r.instructions.enumerated() where i > 0 {
            let l = s.lowercased()
            if hints.contains(where: { l.contains($0) }) { return i }
        }
        return min(1, max(0, r.instructions.count - 1))
    }

    var body: some View {
        Group {
            if let r = recipe {
                content(r)
            } else {
                ContentUnavailableView("Recipe not found", systemImage: "questionmark.circle")
            }
        }
        #if os(iOS)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }

    private func content(_ r: Recipe) -> some View {
        let pgs = pages
        let idx = min(pageIndex, max(0, pgs.count - 1))
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                ProgressView(value: Double(idx + 1), total: Double(max(1, pgs.count)))
                Text(r.name).font(.footnote.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding()

            ZStack {
                if let p = pgs[safe: idx] {
                    pageView(p, r)
                        .id(idx)
                        .transition(.push(from: forward ? .trailing : .leading))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                if v.translation.width < -60 { go(1, pgs.count) } else if v.translation.width > 60 { go(-1, pgs.count) }
            })

            HStack(spacing: 12) {
                Button { go(-1, pgs.count) } label: { Label("Back", systemImage: "chevron.left").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).disabled(idx == 0)
                if idx < pgs.count - 1 {
                    Button { go(1, pgs.count) } label: { Label("Next", systemImage: "chevron.right").labelStyle(.titleAndIcon).frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
            .padding()
        }
        .background(Color.screenBackground)
        .sensoryFeedback(.selection, trigger: pageIndex)
    }

    private func go(_ d: Int, _ count: Int) {
        let n = pageIndex + d
        guard n >= 0, n < count else { return }
        forward = d > 0
        withAnimation(.snappy) { pageIndex = n }
    }

    @ViewBuilder private func pageView(_ p: Page, _ r: Recipe) -> some View {
        switch p {
        case .checklist:
            let res = user.result(for: r, store: store)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ingredients").font(.largeTitle.bold())
                    if res.pints > 1 { Text("Scaled for \(res.pints) pints").foregroundStyle(.secondary) }
                    VStack(spacing: 0) {
                        ForEach(res.lines.filter { $0.included }) { l in
                            Button {
                                if checked.contains(l.lineKey) { checked.remove(l.lineKey) } else { checked.insert(l.lineKey) }
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: checked.contains(l.lineKey) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3).foregroundStyle(checked.contains(l.lineKey) ? Color.accentColor : Color.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(checklistText(l)).font(.body)
                                            .strikethrough(checked.contains(l.lineKey))
                                            .foregroundStyle(checked.contains(l.lineKey) ? .secondary : .primary)
                                            .multilineTextAlignment(.leading)
                                        if l.swap != nil || l.milk != nil || l.powder != nil {
                                            Text("instead of \(l.ing.text)").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 10).padding(.horizontal)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading)
                        }
                    }
                    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(.horizontal)
            }
            .sensoryFeedback(.selection, trigger: checked.count)
        case .step(let i):
            VStack(alignment: .leading, spacing: 18) {
                Text("Step \(i + 1) of \(r.instructions.count)").font(.headline).foregroundStyle(Color.accentColor)
                ScrollView {
                    Text(r.instructions[i]).font(.system(.title, design: .rounded).weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if i == r.instructions.count - 1, let tip = r.proTip(vegMode: user.data.isVegetarian) {
                    Label(tip.text, systemImage: "lightbulb.fill").font(.footnote).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 24)
        case .rate:
            VStack(spacing: 18) {
                Image(systemName: "party.popper.fill").font(.system(size: 52)).foregroundStyle(Color.accentColor)
                Text("Rate it").font(.largeTitle.bold())
                StarRating(rating: $rating)
                TextField("Notes for next time", text: $note, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.roundedBorder)
                Button {
                    finish(r)
                } label: { Label("Save to my log", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Skip") { finish(r, log: false) }.foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .sensoryFeedback(.success, trigger: finished)
        }
    }

    private func checklistText(_ l: LineResult) -> String {
        if l.swap != nil || l.milk != nil || l.powder != nil {
            return l.scaledGrams > 0 ? "\(l.displayName) — \(Int(l.scaledGrams.rounded())) g" : l.displayName
        }
        return NutritionCalculator.amountText(l)
    }

    private func finish(_ r: Recipe, log: Bool = true) {
        if log { user.logMade(recipeId: r.id, rating: rating, note: note) }
        if let tid = request.timerID, let t = user.data.freezer.first(where: { $0.id == tid }) {
            Notifier.cancel(t)
            user.data.freezer.removeAll { $0.id == tid }
        }
        finished.toggle()
        dismiss()
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
