import SwiftUI

struct ShoppingView: View {
    @Environment(UserStore.self) private var user
    @Environment(Router.self) private var router

    var body: some View {
        NavigationStack {
            Group {
                if user.data.shopping.isEmpty {
                    VStack(spacing: 0) { ModeSwitch(); ContentUnavailableView {
                        Label("Your list is empty", systemImage: "cart")
                    } description: {
                        Text("Use \"Add to list\" on a recipe. Your milk and swaps are applied, and pantry staples are left out.")
                    } actions: {
                        Button("Browse recipes") { router.tab = .recipes }.buttonStyle(.borderedProminent)
                    } }
                } else {
                    List {
                        Section { ModeSwitch().listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
                        ForEach(ShoppingList.grouped(user.data.shopping), id: \.category) { g in
                            Section(IngCategory.title(g.category)) {
                                ForEach(g.items) { item in
                                    Button { toggle(item) } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                                                .font(.title3).foregroundStyle(item.checked ? Color.accentColor : Color.secondary)
                                            Text(ShoppingList.label(item))
                                                .strikethrough(item.checked)
                                                .foregroundStyle(item.checked ? .secondary : .primary)
                                            Spacer()
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions {
                                        Button(role: .destructive) { user.data.shopping.removeAll { $0.id == item.id } } label: { Label("Delete", systemImage: "trash") }
                                    }
                                }
                            }
                        }
                    }
                    .groupedListStyle()
                    .sensoryFeedback(.selection, trigger: user.data.shopping.filter(\.checked).count)
                }
            }
            .animation(.snappy, value: user.data.shopping)
            .navigationTitle("Shopping")
            .toolbar {
                if !user.data.shopping.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: ShoppingList.shareText(user.data.shopping)) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { user.data.shopping.removeAll { $0.checked } } label: { Label("Clear checked", systemImage: "checkmark.circle.badge.xmark") }
                            .disabled(!user.data.shopping.contains { $0.checked })
                    }
                }
            }
        }
    }

    private func toggle(_ item: ShoppingItem) {
        if let i = user.data.shopping.firstIndex(where: { $0.id == item.id }) { user.data.shopping[i].checked.toggle() }
    }
}
