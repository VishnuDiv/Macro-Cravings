import SwiftUI

/// Small pieces shared by the Skin, Hair and Progress screens.

struct EvidenceBadge: View {
    let grade: String
    var color: Color {
        switch grade.first { case "A": return .green; case "B": return .teal; case "C": return .orange; default: return .gray }
    }
    var body: some View {
        Text("Evidence \(grade)").font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
    }
}

/// One choice out of several, shown as chips.
struct SingleChips: View {
    let options: [(id: String, title: String)]
    @Binding var selection: String?
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.id) { o in
                ChipToggle(title: o.title, isOn: selection == o.id) { selection = (selection == o.id) ? nil : o.id }
            }
        }
    }
}

/// Several choices out of many, shown as chips.
struct MultiChips: View {
    let options: [(id: String, title: String)]
    @Binding var selection: Set<String>
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.id) { o in
                ChipToggle(title: o.title, isOn: selection.contains(o.id)) {
                    if selection.contains(o.id) { selection.remove(o.id) } else { selection.insert(o.id) }
                }
            }
        }
    }
}

struct WeekdayPicker: View {
    @Binding var days: Set<Int>
    private let names = ["S", "M", "T", "W", "T", "F", "S"]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { d in
                Button {
                    if days.contains(d) { days.remove(d) } else { days.insert(d) }
                } label: {
                    Text(names[d - 1]).font(.subheadline.weight(.semibold)).frame(width: 34, height: 34)
                        .background(days.contains(d) ? Color.accentColor : Color.cardBackground, in: Circle())
                        .foregroundStyle(days.contains(d) ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct HealthNote: View {
    let text: String
    var symbol = "stethoscope"
    var body: some View {
        Label { Text(text).font(.footnote) } icon: { Image(systemName: symbol) }
            .foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 10))
    }
}
