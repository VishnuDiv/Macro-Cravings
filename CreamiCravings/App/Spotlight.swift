import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

enum Spotlight {
    static func index(_ recipes: [Recipe]) {
        let items = recipes.map { r -> CSSearchableItem in
            let a = CSSearchableItemAttributeSet(contentType: .content)
            a.title = r.name
            a.contentDescription = "Ninja Creami recipe · " + r.tags.prefix(4).joined(separator: ", ")
            a.keywords = r.tags + ["creami", "ice cream", "recipe"]
            return CSSearchableItem(uniqueIdentifier: r.id, domainIdentifier: "recipes", attributeSet: a)
        }
        let index = CSSearchableIndex.default()
        index.deleteAllSearchableItems { _ in index.indexSearchableItems(items) }
    }
}
