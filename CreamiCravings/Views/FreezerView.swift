import SwiftUI

struct FreezerView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(Router.self) private var router

    var body: some View {
        NavigationStack {
            Group {
                if user.data.freezer.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing in the freezer or fridge", systemImage: "snowflake")
                    } description: {
                        Text("Start a freeze timer from any recipe and you'll get a notification when it's ready to spin (or ready to eat).")
                    } actions: {
                        Button("Browse recipes") { router.tab = .recipes }.buttonStyle(.borderedProminent)
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        list(now: ctx.date)
                    }
                }
            }
            .navigationTitle("Freezer")
            .background(Color.screenBackground)
        }
    }

    private func sorted(_ now: Date) -> [FreezeTimer] {
        user.data.freezer.sorted {
            let a = $0.isReady(at: now), b = $1.isReady(at: now)
            return a != b ? a : $0.readyAt < $1.readyAt
        }
    }

    private func list(now: Date) -> some View {
        List {
            ForEach(sorted(now)) { t in
                if let r = store.recipeByID[t.recipeId] {
                    row(t, r, now)
                        .swipeActions {
                            Button(role: .destructive) { remove(t) } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            }
        }
        .groupedListStyle()
        .animation(.snappy, value: user.data.freezer.count)
    }

    private func row(_ t: FreezeTimer, _ r: Recipe, _ now: Date) -> some View {
        let ready = t.isReady(at: now)
        let total = max(1, t.readyAt.timeIntervalSince(t.start))
        let progress = min(1, max(0, now.timeIntervalSince(t.start) / total))
        return HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 6)
                Circle().trim(from: 0, to: ready ? 1 : progress)
                    .stroke(ready ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: ready ? "checkmark" : "snowflake").foregroundStyle(ready ? Color.green : Color.accentColor)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.name).font(.headline)
                if ready {
                    Text(r.usesServings ? "Ready to eat" : "Ready to spin").font(.subheadline).foregroundStyle(.green)
                } else {
                    Text(timerInterval: now...t.readyAt, countsDown: true).font(.subheadline.monospacedDigit())
                }
                Text("Started \(t.start.formatted(date: .abbreviated, time: .shortened)) · ready \(t.readyAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if ready {
                Button(r.usesServings ? "Cook it" : "Spin it") { router.cook = CookRequest(recipeId: r.id, skipChecklist: true, timerID: t.id) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }

    private func remove(_ t: FreezeTimer) {
        Notifier.cancel(t)
        user.data.freezer.removeAll { $0.id == t.id }
    }
}
