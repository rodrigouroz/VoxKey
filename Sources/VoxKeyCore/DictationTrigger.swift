/// Deliberate modifier-only triggers. Caps Lock and general shortcuts are unsupported.
public enum DictationTrigger: String, CaseIterable, Sendable {
    case globe, rightOption, rightCommand, rightControl

    public var displayName: String {
        switch self {
        case .globe: "Globe/Fn"
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        case .rightControl: "Right Control"
        }
    }

    public var keyCode: UInt16 {
        switch self {
        case .globe: 63
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        }
    }

    public var hint: String {
        switch self {
        case .globe: "May conflict with ‘Press Globe key to…’ in System Settings → Keyboard."
        case .rightOption: "Use the right Option key alone. Left Option keeps its normal meaning."
        case .rightCommand: "Use the right Command key alone. Left Command keeps its normal meaning."
        case .rightControl: "Use the right Control key alone. Left Control keeps its normal meaning."
        }
    }
}
