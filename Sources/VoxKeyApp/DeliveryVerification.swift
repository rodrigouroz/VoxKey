import Foundation

enum PreferredDeliveryRoute: Equatable {
    case accessibilitySelection
    case pasteboard
}

enum DeliveryRoutePolicy {
    static func preferredRoute(
        isWebBacked: Bool,
        directInsertionSettable: Bool,
        directInsertionKnownUnsupported: Bool
    ) -> PreferredDeliveryRoute {
        if isWebBacked || !directInsertionSettable || directInsertionKnownUnsupported {
            return .pasteboard
        }
        return .accessibilitySelection
    }
}

enum DestinationCapabilityClassifier {
    static func isEditable(
        role: String?, editable: Bool?, enabled: Bool?, hasSelection: Bool,
        directInsertionSettable: Bool
    ) -> Bool {
        guard enabled != false, editable != false, hasSelection else { return false }
        if directInsertionSettable || editable == true { return true }
        return role.map { ["AXTextField", "AXTextArea", "AXComboBox"].contains($0) } == true
    }

    private static let webRoles: Set<String> = ["AXWebArea"]
    private static let webAttributeNames: Set<String> = [
        "AXDOMIdentifier",
        "AXHasWebApplicationAncestor",
        "AXSelectedTextMarkerRange"
    ]

    static func isWebBacked(role: String?, attributeNames: Set<String>) -> Bool {
        role.map(webRoles.contains) == true || !webAttributeNames.isDisjoint(with: attributeNames)
    }
}

struct TextMutationSnapshot: Equatable {
    let location: Int
    let length: Int
    let preceding: String?
    let following: String?
    let selectedPrefix: String?
    let selectedSuffix: String?
    let characterCount: Int?

    init(
        range: CFRange, preceding: String?, following: String?,
        selectedPrefix: String? = nil, selectedSuffix: String? = nil, characterCount: Int? = nil
    ) {
        location = range.location
        length = range.length
        self.preceding = preceding
        self.following = following
        self.selectedPrefix = selectedPrefix
        self.selectedSuffix = selectedSuffix
        self.characterCount = characterCount
    }

    var hasReadableContext: Bool { preceding != nil && following != nil }

    func matchesIntent(_ original: Self) -> Bool {
        guard location == original.location, length == original.length,
              preceding == original.preceding, following == original.following else { return false }
        if length == 0 { return true }
        return selectedPrefix != nil && selectedSuffix != nil
            && selectedPrefix == original.selectedPrefix && selectedSuffix == original.selectedSuffix
    }
}

enum TextMutationVerification {
    enum Result: Equatable {
        case confirmed
        case unchanged
        case ambiguous
    }

    enum Evidence: String {
        case snapshotUnavailable
        case unchanged
        case precedingTextMismatch
        case followingTextMismatch
        case confirmedContext
        case insufficientContext

        var result: Result {
            switch self {
            case .unchanged: .unchanged
            case .confirmedContext: .confirmed
            default: .ambiguous
            }
        }
    }

    static func evaluate(
        original: TextMutationSnapshot,
        current: TextMutationSnapshot?,
        insertedText: String,
        contextLimit: Int
    ) -> Result {
        evidence(
            original: original, current: current, insertedText: insertedText,
            contextLimit: contextLimit
        ).result
    }

    static func evidence(
        original: TextMutationSnapshot,
        current: TextMutationSnapshot?,
        insertedText: String,
        contextLimit: Int
    ) -> Evidence {
        guard let current else { return .snapshotUnavailable }
        if current == original { return .unchanged }

        let expectedLocation = original.location + insertedText.utf16.count
        let expectedPreceding = original.preceding.map { utf16Suffix($0 + insertedText, limit: contextLimit) }
        let rangeMatches = current.location == expectedLocation && current.length == 0
        if let expectedPreceding, let actual = current.preceding, actual != expectedPreceding { return .precedingTextMismatch }
        if let expected = original.following, let actual = current.following, actual != expected { return .followingTextMismatch }
        // A missing context value is not an empty string. Caret movement alone
        // cannot establish delivery; readable contradictory text always wins.
        let textMatches = expectedPreceding != nil && current.preceding == expectedPreceding
        let followingMatches = original.following != nil && current.following == original.following
        return textMatches && (rangeMatches || followingMatches) ? .confirmedContext : .insufficientContext
    }

    private static func utf16Suffix(_ text: String, limit: Int) -> String {
        let units = text.utf16
        let count = min(max(0, limit), units.count)
        let start = units.index(units.endIndex, offsetBy: -count)
        return String(decoding: units[start...], as: UTF16.self)
    }
}
