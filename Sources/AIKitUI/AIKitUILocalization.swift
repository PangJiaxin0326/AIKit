import Foundation

enum AIKitUILocalization {
    static func string(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: .module)
    }
}
