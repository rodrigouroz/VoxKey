#if VOXKEY_PERFORMANCE && !VOXKEY_RELEASE
import Foundation

struct FocusDiagnosticAttempt: Codable, Sendable {
    var route = "unresolved"
    var searchResult: String?
    var visited = 0
    var candidates = 0
    var maximumDepth = 0
    var editorDepth: Int?
    var milliseconds: Double = 0
    var manualAccessibilityResult: Int32?
    var enhancedAccessibilityResult: Int32?
}

struct DestinationDiagnosticRecord: Codable, Sendable {
    var status = "pending"
    var applicationCategory: String?
    var role: String?
    var editable: Bool?
    var enabled: Bool?
    var selectionAvailable: Bool?
    var directInsertionSettable: Bool?
    var readableContext: Bool?
    var deliveryRoute: String?
    var directWriteResult: Int32?
    var pasteDispatched: Bool?
    var confirmation: String?
    var confirmationEvidence: String?
    var rangeReadback: String?
    var resolutionAttempts = 0
    var focusAttempts: [FocusDiagnosticAttempt] = []
    var axErrors: [String: Int32] = [:]
}

/// Scoped to a capture/delivery operation. Background focus observation has no
/// scope and cannot overwrite the explanation for the actual dictation attempt.
/// All values come from already-required AX calls; diagnostics add no IPC reads.
@MainActor
final class DestinationDiagnostics {
    @TaskLocal static var current: DestinationDiagnostics?
    private var record = DestinationDiagnosticRecord()
    private var sealed = false

    func update(_ body: (inout DestinationDiagnosticRecord) -> Void) {
        guard !sealed else { return }
        body(&record)
    }

    func finish(status: String) -> DestinationDiagnosticRecord {
        record.status = status
        sealed = true
        return record
    }

    func append(_ attempt: FocusDiagnosticAttempt) {
        update {
            $0.resolutionAttempts += 1
            if $0.focusAttempts.count == 8 { $0.focusAttempts.removeFirst() }
            $0.focusAttempts.append(attempt)
        }
    }

    func axError(_ code: Int32, operation: String) {
        guard code != 0 else { return }
        // Never allow an arbitrary attribute name into a persisted record.
        let known = ["AXFocusedUIElement", "AXFocusedWindow", "AXFocused", "AXRole", "AXChildren",
                     "AXSelectedTextRange", "AXEnabled", "AXEditable", "AXSubrole", "AXNumberOfCharacters",
                     "AXStringForRange", "AXAttributedStringForRange", "AXAttributeNames", "AXIsAttributeSettable"]
        guard known.contains(operation) else { return }
        update { $0.axErrors[operation] = code }
    }

    static func applicationCategory(_ name: String) -> String {
        switch name.lowercased() {
        case "conductor": "conductor"
        case "codex": "codex"
        case "cursor": "cursor"
        case "claude": "claude"
        default: "other"
        }
    }

    static func role(_ role: String?) -> String {
        let known = ["AXTextArea", "AXTextField", "AXComboBox", "AXSecureTextField", "AXGroup",
                     "AXWebArea", "AXScrollArea", "AXButton", "AXWindow", "AXApplication"]
        guard let role else { return "unavailable" }
        return known.contains(role) ? role : "other"
    }
}
#endif
