import SwiftUI

/// The Food | Health switch, a compact pill at the top of every root screen.
struct ModeSwitch: View {
    @Environment(UserStore.self) private var user
    @Environment(Router.self) private var router
    @Environment(HealthLock.self) private var lock
    var compact = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppMode.allCases) { m in
                Button { select(m) } label: {
                    Label(m.title, systemImage: m == .food ? "fork.knife" : "heart.text.square")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(user.data.appMode == m ? Color.accentColor : Color.clear, in: Capsule())
                        .foregroundStyle(user.data.appMode == m ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.cardBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25)))
        .sensoryFeedback(.selection, trigger: user.data.appMode)
        .frame(maxWidth: compact ? nil : .infinity)
        .padding(.vertical, compact ? 0 : 6)
    }

    private func select(_ m: AppMode) {
        guard m != user.data.appMode else { return }
        withAnimation(.snappy) {
            user.data.appMode = m
            router.tab = (m == .food) ? .recipes : .today
        }
        if m == .health && user.data.healthLockEnabled { Task { await lock.unlock() } }
    }
}

/// Health screens only show once the Face ID / passcode lock is open.
struct HealthGate<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(UserStore.self) private var user
    @Environment(HealthLock.self) private var lock

    var body: some View {
        if !user.data.healthLockEnabled || lock.unlocked {
            content()
        } else {
            VStack(spacing: 18) {
                ModeSwitch()
                Spacer()
                Image(systemName: "lock.shield.fill").font(.system(size: 60)).foregroundStyle(Color.accentColor)
                Text("Health is locked").font(.title2.bold())
                Text(lock.failed ? "Authentication did not succeed. Try again." : "Your skin, hair and progress photos stay on this device and behind Face ID.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 30)
                Button { Task { await lock.unlock() } } label: { Label("Unlock", systemImage: "faceid").frame(maxWidth: 220) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Spacer()
            }
            .task { await lock.unlock() }
        }
    }
}
