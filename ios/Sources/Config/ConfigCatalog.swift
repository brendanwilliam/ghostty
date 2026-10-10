import Foundation

/// Every Ghostty config option with its documentation, generated from
/// Ghostty's own docs by `ios/scripts/gen-config-catalog.py`.
final class ConfigCatalog {
    struct Option: Decodable, Identifiable, Hashable {
        enum Kind: String, Decodable {
            case bool, enumeration = "enum", color, number, text
        }

        var id: String { key }
        let key: String
        let doc: String
        let defaultValue: String
        let kind: Kind
        let repeatable: Bool
        let values: [String]?
        /// Set for options that only apply to a desktop platform
        /// (`macos` or `gtk`), which have no effect on iOS.
        let platform: String?

        private enum CodingKeys: String, CodingKey {
            case key, doc, defaultValue = "default", kind, repeatable, values, platform
        }

        /// The first paragraph of the docs, for list rows.
        var summary: String {
            doc.components(separatedBy: "\n\n").first?
                .replacingOccurrences(of: "\n", with: " ") ?? ""
        }
    }

    static let shared = ConfigCatalog()

    let options: [Option]
    private let byKey: [String: Option]

    init(url: URL? = Bundle.main.url(forResource: "ConfigCatalog", withExtension: "json")) {
        let options = url
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([Option].self, from: $0) } ?? []
        self.options = options
        self.byKey = Dictionary(options.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func option(_ key: String) -> Option? {
        byKey[key]
    }
}
