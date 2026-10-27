import SwiftUI

/// "Add protein" for low-protein overnight oats: optional, combinable, off by default.
struct ProteinBoostCard: View {
    let recipe: Recipe
    let options: [BoostOption]
    let totalProteinPerServing: Double
    let isOn: (String) -> Bool
    let toggle: (String, Bool) -> Void

    private func delta(_ n: Nutrition) -> String { "+\(Int(n.protein.rounded())) g P · +\(Int(n.calories.rounded())) kcal" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Add protein", systemImage: "plus.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
            Text("Now \(Int(totalProteinPerServing.rounded())) g protein per \(recipe.name.lowercased().contains("overnight") ? "jar" : "serving")")
                .font(.headline)
                .contentTransition(.numericText(value: totalProteinPerServing))
            ForEach(options) { o in
                Toggle(isOn: Binding(get: { isOn(o.id) }, set: { toggle(o.id, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.title).font(.footnote.weight(.medium))
                        Text(delta(o.deltaPerServing)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if let n = o.note, isOn(o.id) { Text(n).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .toggleStyle(.switch).tint(.green)
            }
            Text("Optional, vegetarian, per serving. Choices are added to the ingredients, macros, cook mode and shopping list.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sensoryFeedback(.selection, trigger: totalProteinPerServing)
    }
}
