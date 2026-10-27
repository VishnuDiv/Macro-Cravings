import Foundation

/// Decodes an element or yields nil, so one bad element does not fail the whole array.
struct LenientBox<U: Decodable>: Decodable {
    var v: U?
    init(from d: Decoder) throws { v = try? U(from: d) }
}

func decodeLenientArray<T: Decodable, K: CodingKey>(from c: KeyedDecodingContainer<K>, key: K) -> [T] {
    ((try? c.decodeIfPresent([LenientBox<T>].self, forKey: key)) ?? nil)?.compactMap { $0.v } ?? []
}
