import Foundation
@preconcurrency import WhisperKit

enum TranscriptionModel: String, CaseIterable, Sendable {
    case distilCompressed = "distil-whisper_distil-large-v3_594MB"
    case distilFull = "distil-whisper_distil-large-v3"
    case turboCompressed = "openai_whisper-large-v3-v20240930_626MB"
    case turboFull = "openai_whisper-large-v3-v20240930"

    var name: String {
        switch self {
        case .distilCompressed: "Distil-Whisper v3 · Compact"
        case .distilFull: "Distil-Whisper v3 · Full"
        case .turboCompressed: "Whisper v3 Turbo · Compact"
        case .turboFull: "Whisper v3 Turbo · Full"
        }
    }
    var multilingual: Bool { self == .turboCompressed || self == .turboFull }
    var size: String {
        switch self {
        case .distilCompressed: "594 MB"
        case .distilFull: "1.51 GB"
        case .turboCompressed: "627 MB"
        case .turboFull: "1.62 GB"
        }
    }
    var details: String {
        switch self {
        case .distilCompressed: "The default English model. The smallest download of these four choices."
        case .distilFull: "The same English model without compression. A larger download; compare which works better for your voice."
        case .turboCompressed: "Multilingual recognition in a compact download. Speed and accuracy vary by language and Mac."
        case .turboFull: "Multilingual recognition without compression. A larger download to compare with Turbo Compact."
        }
    }
    var languages: [String] {
        guard multilingual else { return ["en"] }
        return ["auto", "en", "es"] + Set(Constants.languages.values).subtracting(["en", "es"]).sorted {
            Self.languageName($0).localizedStandardCompare(Self.languageName($1)) == .orderedAscending
        }
    }
    func normalizedLanguage(_ language: String) -> String { languages.contains(language) ? language : "en" }
    static func languageName(_ code: String) -> String {
        code == "auto" ? "Automatic — detect spoken language" : Locale.current.localizedString(forLanguageCode: code) ?? code
    }
    static let preferenceKey = "VoxKeyTranscriptionModel"
    static let languagePreferenceKey = "VoxKeyTranscriptionLanguage"
}

struct TranscriptionConfiguration: Equatable, Sendable {
    let model: TranscriptionModel
    let language: String
    init(model: TranscriptionModel = .distilCompressed, language: String = "en") {
        self.model = model
        self.language = model.normalizedLanguage(language)
    }
    init(defaults: UserDefaults) {
        self.init(model: TranscriptionModel(rawValue: defaults.string(forKey: TranscriptionModel.preferenceKey) ?? "") ?? .distilCompressed,
                  language: defaults.string(forKey: TranscriptionModel.languagePreferenceKey) ?? "en")
    }
    var decodingLanguage: String? { language == "auto" ? nil : language }
    // Automatic sessions may contain any language. The installed corrector is English-only.
    var supportsGrammarCorrection: Bool { language == "en" }
    func save(to defaults: UserDefaults) {
        defaults.set(model.rawValue, forKey: TranscriptionModel.preferenceKey)
        defaults.set(language, forKey: TranscriptionModel.languagePreferenceKey)
    }
}
