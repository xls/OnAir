import Foundation
import OnAirCore

/// What the active mode is decoding: a summary, cards and tables, as OnAir's own result tables name them.
struct Results: Decodable {
    struct Table: Decodable {
        let name: String
        let cols: [String]
        let rows: [[String]]

        func column(_ names: String...) -> Int? {
            for name in names { if let i = cols.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return i } }
            return nil
        }

        func value(_ row: [String], _ names: String...) -> String {
            for name in names {
                if let i = cols.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }), i < row.count, !row[i].isEmpty { return row[i] }
            }
            return ""
        }
    }

    var summary: String?
    var cards: [[String]]?
    var tables: [Table]?

    func table(_ name: String) -> Table? { tables?.first { $0.name == name } }
    func table(withColumn name: String) -> Table? { tables?.first { $0.column(name) != nil } }

    func card(_ name: String) -> String { cards?.first { $0.first == name }?.last ?? "" }

    static func current() -> Results? {
        guard let text = onair_results_json() else { return nil }
        return try? JSONDecoder().decode(Results.self, from: Data(String(cString: text).utf8))
    }
}
