import SwiftUI

/// "Good for" chips on a recipe; tapping one explains why.
struct GoodForRow: View {
    let results: [BenefitResult]
    let maxChips: Int
    @State private var picked: BenefitResult?

    var body: some View {
        if !results.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Good for").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(results.prefix(maxChips)) { r in
                        Button { picked = r } label: {
                            Label(r.benefit.title, systemImage: r.benefit.symbol)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.green.opacity(0.14), in: Capsule())
                                .foregroundStyle(Color.green)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .sheet(item: $picked) { BenefitSheet(result: $0) }
        }
    }
}

struct BenefitSheet: View {
    let result: BenefitResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(result.reasons, id: \.self) { reason in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(reason.title).font(.headline)
                            if !reason.why.isEmpty { Text(reason.why).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                } footer: { Text("General nutrition information, not medical advice.") }
            }
            .navigationTitle(result.benefit.sheetTitle)
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
