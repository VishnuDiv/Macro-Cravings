import SwiftUI

/// "Protein upgrade": Cauliflower -> [Original | Tofu | Paneer | Seitan | Soy chunks], each chip showing the change per serving.
struct UpgradeCard: View {
    let card: UpgradeCardData
    let onPick: (String?) -> Void

    private func color(_ a: String) -> Color { a == "everywhere" ? .green : (a == "specialty" ? .orange : .blue) }

    private func deltaText(_ d: Nutrition) -> String {
        func s(_ v: Double, _ u: String) -> String { (v >= 0 ? "+" : "−") + "\(Int(abs(v).rounded()))" + u }
        return "\(s(d.protein, " g P")) · \(s(d.calories, " kcal"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Protein upgrade", systemImage: "bolt.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
            Text("\(card.baseName) → \(card.chosen?.label ?? "Original")").font(.headline)
                .contentTransition(.interpolate)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(card.options.enumerated()), id: \.offset) { _, o in
                        let on = o.key == card.chosenKey
                        Button { onPick(o.key) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(o.label).font(.footnote.weight(.semibold)).lineLimit(1)
                                if let a = o.alt {
                                    Text(a.availabilityTitle).font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(color(a.availability).opacity(on ? 0.9 : 0.2), in: Capsule())
                                        .foregroundStyle(on ? Color.white : color(a.availability))
                                    Text(deltaText(o.deltaPerServing)).font(.caption2.monospacedDigit())
                                        .foregroundStyle(on ? .white.opacity(0.9) : .secondary)
                                } else {
                                    Text("as written").font(.caption2).foregroundStyle(on ? .white.opacity(0.9) : .secondary)
                                }
                            }
                            .padding(8)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .background(on ? Color.green : Color.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: card.chosenKey)
            if let c = card.chosen, let a = c.alt {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Int(c.grams)) g \(a.key.contains("soy_chunks") ? "dry soy chunks (rehydrated)" : a.name.lowercased()) replaces \(Int(card.weight)) g \(card.baseName.lowercased())")
                        .font(.caption.weight(.medium))
                    if let w = a.whereToBuy, !w.isEmpty { (Text("Where to buy: ").bold() + Text(w)).font(.caption) }
                    if let b = a.brands, !b.isEmpty { (Text("Brands: ").bold() + Text(b)).font(.caption) }
                    if let p = a.prep, !p.isEmpty { (Text("Prep: ").bold() + Text(p)).font(.caption) }
                    if let y = a.why, !y.isEmpty { Text(y).font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                Text("Swap the \(card.baseName.lowercased()) for a protein at the same weight to turn these into real protein wings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
