import SwiftUI

/// Plan tab: a day (or week) of meals that lands on the daily calorie and protein targets.
struct PlanView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(Router.self) private var router
    @State private var planner: MealPlanner?
    @State private var date = Date()
    @State private var weekMode = false
    @State private var swapSlot: PlanSlotName?
    @State private var addedToList = false

    private var key: String { PlanKey.key(date) }
    private var targets: PlanTargets { PlanTargets(kcal: Double(user.data.dailyKcal), protein: Double(user.data.dailyProtein)) }
    private var plan: DayPlan? { user.data.plans[key] }
    private var focus: Benefit? { user.data.planFocus.flatMap(Benefit.init(rawValue:)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ModeSwitch()
                    Picker("View", selection: $weekMode.animation(.snappy)) {
                        Text("Day").tag(false)
                        Text("Week").tag(true)
                    }
                    .pickerStyle(.segmented).padding(.horizontal)
                    dateBar
                    if weekMode { weekView } else { dayView }
                    freezerLink
                }
                .padding(.vertical, 8)
            }
            .background(Color.screenBackground)
            .navigationTitle("Plan")
            .navigationDestination(for: String.self) { id in
                if let r = store.recipeByID[id] { RecipeDetailView(recipe: r) } else { ContentUnavailableView("Recipe not found", systemImage: "questionmark.circle") }
            }
            .sheet(item: $swapSlot) { slot in
                if let planner, let p = plan { SwapSheetPlan(planner: planner, slot: slot, plan: p, targets: targets, date: date) { r, portion in apply(slot, r, portion) } }
            }
            .onAppear { if planner == nil { planner = MealPlanner(store: store, user: user) } }
        }
    }

    // MARK: pieces

    private var dateBar: some View {
        HStack {
            Button { date = Calendar.current.date(byAdding: .day, value: weekMode ? -7 : -1, to: date) ?? date } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(weekMode ? weekTitle : date.formatted(.dateTime.weekday(.wide).month().day())).font(.headline)
            Spacer()
            Button { date = Calendar.current.date(byAdding: .day, value: weekMode ? 7 : 1, to: date) ?? date } label: { Image(systemName: "chevron.right") }
        }
        .padding(.horizontal, 24)
    }

    private var weekTitle: String {
        let start = weekStart
        let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
        return "\(start.formatted(.dateTime.month().day())) – \(end.formatted(.dateTime.month().day()))"
    }
    private var weekStart: Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)) ?? date
    }

    @ViewBuilder private var dayView: some View {
        let totals = planner.map { p in plan.map { p.totals($0) } } ?? nil
        VStack(spacing: 14) {
            HStack(spacing: 24) {
                Ring(value: totals?.calories ?? 0, target: targets.kcal, color: .calorieRed, title: "kcal")
                Ring(value: totals?.protein ?? 0, target: targets.protein, color: .proteinGreen, title: "g protein")
            }
            .padding(.horizontal)
            if let plan, planner != nil {
                ForEach(plan.slots) { s in slotRow(s) }
                    .padding(.horizontal)
                HStack(spacing: 10) {
                    Button { generate(regenerate: true) } label: { Label("Regenerate", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                    Button { toggleDessert() } label: { Label(plan.slots.contains { $0.slot == .dessert } ? "Remove dessert" : "Add dessert", systemImage: "birthday.cake") }
                        .buttonStyle(.bordered)
                }
                .controlSize(.large).padding(.horizontal)
                focusPicker
            } else {
                ContentUnavailableView {
                    Label("No plan for this day", systemImage: "calendar.badge.plus")
                } description: {
                    Text("Builds breakfast, lunch, dinner and a snack from vegetarian recipes to hit \(user.data.dailyKcal) kcal and \(user.data.dailyProtein) g protein.")
                } actions: {
                    Button { generate(regenerate: false) } label: { Text("Generate day") }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var focusPicker: some View {
        HStack {
            Text("Good for focus").font(.subheadline)
            Spacer()
            Menu {
                Button("None") { user.data.planFocus = nil }
                ForEach(Benefit.allCases) { b in Button(b.title) { user.data.planFocus = b.rawValue } }
            } label: { Text(focus?.title ?? "None").foregroundStyle(Color.accentColor) }
        }
        .padding(.horizontal, 24)
    }

    private func slotRow(_ s: MealSlotPlan) -> some View {
        let r = s.recipeId.flatMap { store.recipeByID[$0] }
        let m = r.flatMap { rr in planner?.macros(of: rr, goal: s.goal) }.map { $0 * s.portion }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(s.slot.title, systemImage: s.slot.symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { setLock(s, !s.locked) } label: { Image(systemName: s.locked ? "lock.fill" : "lock.open") }
                    .buttonStyle(.plain).foregroundStyle(s.locked ? Color.accentColor : .secondary)
                    .accessibilityLabel(s.locked ? "Unlock slot" : "Lock slot")
                Button { swapSlot = s.slot } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).accessibilityLabel("Swap")
            }
            if let r {
                NavigationLink(value: r.id) {
                    HStack {
                        Text(planner?.displayTitle(of: r) ?? r.name).font(.headline).multilineTextAlignment(.leading).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if let m { SmallPill(text: "\(Int(m.calories.rounded())) kcal", color: .calorieRed); SmallPill(text: "\(Int(m.protein.rounded())) g P", color: .proteinGreen) }
                    SmallPill(text: s.goal.title, color: s.goal.color)
                    Spacer()
                    Stepper(value: Binding(get: { s.portion }, set: { setPortion(s, $0) }), in: 0.5...2, step: 0.25) {
                        Text("\(FilterFormat.portion(s.portion))×").font(.subheadline.monospacedDigit())
                    }
                    .fixedSize()
                }
            } else {
                Text("Nothing planned").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private var weekView: some View {
        VStack(spacing: 10) {
            ForEach(0..<7, id: \.self) { i in
                let day = Calendar.current.date(byAdding: .day, value: i, to: weekStart) ?? weekStart
                let p = user.data.plans[PlanKey.key(day)]
                let n = planner.flatMap { pl in p.map { pl.totals($0) } }
                Button { date = day; weekMode = false } label: {
                    HStack {
                        Text(day.formatted(.dateTime.weekday(.abbreviated).day())).font(.subheadline.weight(.semibold)).frame(width: 64, alignment: .leading)
                        if let n {
                            SmallPill(text: "\(Int(n.calories.rounded())) kcal", color: .calorieRed)
                            SmallPill(text: "\(Int(n.protein.rounded())) g P", color: .proteinGreen)
                        } else { Text("Not planned").font(.subheadline).foregroundStyle(.secondary) }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12).background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                Button { generateWeek() } label: { Label("Generate week", systemImage: "wand.and.stars").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                Button { addWeekToList() } label: { Label("Add to list", systemImage: "cart.badge.plus") }.buttonStyle(.bordered)
                    .sensoryFeedback(.success, trigger: addedToList)
            }
            .controlSize(.large)
        }
        .padding(.horizontal)
    }

    private var freezerLink: some View {
        NavigationLink { FreezerView() } label: {
            HStack {
                Label("Freezer", systemImage: "snowflake")
                Spacer()
                if user.data.freezer.contains(where: { $0.isReady() }) { SmallPill(text: "ready", color: .green) }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12).background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain).padding(.horizontal)
    }

    // MARK: actions

    private func avoid(for day: Date) -> Set<String> { planner?.recentIds(before: day, plans: user.data.plans) ?? [] }

    private func generate(regenerate: Bool) {
        guard let planner else { return }
        let seed = (plan?.seed ?? 0) + 1
        let p = planner.generateDay(seed: seed, targets: targets, goal: user.data.goal, existing: plan, avoid: avoid(for: date),
                                    includeDessert: plan?.slots.contains { $0.slot == .dessert } ?? false, focus: focus)
        user.data.plans[key] = p
    }

    private func generateWeek() {
        guard let planner else { return }
        for i in 0..<7 {
            let day = Calendar.current.date(byAdding: .day, value: i, to: weekStart) ?? weekStart
            let k = PlanKey.key(day)
            let seed = (user.data.plans[k]?.seed ?? 0) + 1 + i
            user.data.plans[k] = planner.generateDay(seed: seed, targets: targets, goal: user.data.goal, existing: user.data.plans[k],
                                                     avoid: planner.recentIds(before: day, plans: user.data.plans), focus: focus)
        }
    }

    private func toggleDessert() {
        guard var p = plan else { return }
        if p.slots.contains(where: { $0.slot == .dessert }) { p.slots.removeAll { $0.slot == .dessert }; user.data.plans[key] = p }
        else if let planner {
            let np = planner.generateDay(seed: p.seed, targets: targets, goal: user.data.goal, existing: DayPlan(slots: p.slots.map { var s = $0; s.locked = true; return s }, seed: p.seed),
                                         avoid: avoid(for: date), includeDessert: true, focus: focus)
            user.data.plans[key] = np
        }
    }

    private func setLock(_ s: MealSlotPlan, _ on: Bool) {
        guard var p = plan, let i = p.slots.firstIndex(where: { $0.slot == s.slot }) else { return }
        p.slots[i].locked = on; user.data.plans[key] = p
    }
    private func setPortion(_ s: MealSlotPlan, _ v: Double) {
        guard var p = plan, let i = p.slots.firstIndex(where: { $0.slot == s.slot }) else { return }
        p.slots[i].portion = v; user.data.plans[key] = p
    }
    private func apply(_ slot: PlanSlotName, _ r: Recipe, _ portion: Double) {
        guard var p = plan, let i = p.slots.firstIndex(where: { $0.slot == slot }) else { return }
        p.slots[i].recipeId = r.id; p.slots[i].portion = portion; user.data.plans[key] = p
    }

    private func addWeekToList() {
        var items: [ShoppingItem] = []
        for i in 0..<7 {
            let day = Calendar.current.date(byAdding: .day, value: i, to: weekStart) ?? weekStart
            if let p = user.data.plans[PlanKey.key(day)] { items += PlanShopping.items(for: p, store: store, user: user) }
        }
        ShoppingList.merge(items, into: &user.data.shopping)
        addedToList.toggle()
    }
}

/// A progress ring: value against target.
struct Ring: View {
    let value: Double
    let target: Double
    let color: Color
    let title: String
    var body: some View {
        let frac = target > 0 ? min(1.3, value / target) : 0
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 12)
            Circle().trim(from: 0, to: min(1, frac)).stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(value.rounded()))").font(.title3.bold().monospacedDigit()).contentTransition(.numericText(value: value))
                Text("of \(Int(target)) \(title)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 120, height: 120)
        .animation(.snappy, value: value)
    }
}

struct SwapSheetPlan: View {
    let planner: MealPlanner
    let slot: PlanSlotName
    let plan: DayPlan
    let targets: PlanTargets
    let date: Date
    let pick: (Recipe, Double) -> Void
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let goal = plan.slots.first { $0.slot == slot }?.goal ?? user.data.goal
        let cands = planner.swapCandidates(for: slot, in: plan, targets: targets, goal: goal, avoid: planner.recentIds(before: date, plans: user.data.plans))
        NavigationStack {
            List {
                if cands.isEmpty { Text("Nothing else fits what is left of the day.").foregroundStyle(.secondary) }
                ForEach(cands, id: \.recipe.id) { c in
                    let m = planner.macros(of: c.recipe, goal: goal) * c.portion
                    Button { pick(c.recipe, c.portion); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(planner.displayTitle(of: c.recipe)).foregroundStyle(.primary)
                            Text("\(FilterFormat.portion(c.portion))× · \(Int(m.calories.rounded())) kcal · \(Int(m.protein.rounded())) g protein").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Swap \(slot.title.lowercased())")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
