import Foundation

/// Translation helpers — wire-shape lookups + locale resolution.
/// Mirrors `i18n.ts` in the Web SDK so a survey rendered on iOS
/// picks the same locale + same per-string fallback chain as the
/// same survey rendered in a browser.
///
/// Lookup keys are dot-paths:
///   - survey.name
///   - survey.description
///   - question.<question_id>.prompt
///   - question.<question_id>.helptext
///   - question.<question_id>.option.<option_key>.label
///
/// Missing keys fall back to the source string on the survey /
/// question / option object — never throws, never blanks the UI.
/// BCP-47 language tags whose script renders right-to-left.
/// Matches the Unicode CLDR list; used by the SDK to flip dialog
/// layout when a survey's resolved locale is RTL even though the
/// host's system locale is LTR.
private let pulseRtlLanguageTags: Set<String> = [
    "ar", "fa", "he", "iw", "ji", "ku", "ps", "sd", "ug", "ur", "yi"
]

public func sankofaPulseLocaleIsRTL(_ locale: String?) -> Bool {
    guard let locale = locale, !locale.isEmpty else { return false }
    let language = locale.split(separator: "-").first.map(String.init) ?? locale
    return pulseRtlLanguageTags.contains(language.lowercased())
}

public struct SankofaPulseTranslator: Sendable {
    public let strings: [String: String]

    /// BCP-47 tag this translator was built for; nil when no
    /// translation was applied (source strings render unchanged).
    public let locale: String?

    public init(strings: [String: String], locale: String? = nil) {
        self.strings = strings
        self.locale = locale
    }

    public func surveyName(_ survey: SankofaPulseSurvey) -> String {
        strings["survey.name"] ?? survey.name
    }

    public func surveyDescription(_ survey: SankofaPulseSurvey) -> String? {
        strings["survey.description"] ?? survey.description
    }

    public func questionPrompt(_ question: SankofaPulseQuestion) -> String {
        strings["question.\(question.id).prompt"] ?? question.prompt
    }

    public func questionHelptext(_ question: SankofaPulseQuestion) -> String? {
        strings["question.\(question.id).helptext"] ?? question.helptext
    }

    public func optionLabel(
        _ question: SankofaPulseQuestion,
        _ option: SankofaPulseQuestionOption
    ) -> String {
        strings["question.\(question.id).option.\(option.key).label"]
            ?? option.label
    }

    /// Resolution order:
    ///   1. Exact match against translations keys
    ///   2. Language-only fallback (en-US → en)
    ///   3. Device default — exact, then language-only
    ///   4. nil → render source strings unchanged
    public static func resolveLocale(
        _ translations: [String: [String: String]]?,
        preferred: String? = nil,
        deviceLocale: String? = nil
    ) -> String? {
        guard let translations = translations, !translations.isEmpty else { return nil }
        var candidates: [String] = []
        if let preferred = preferred, !preferred.isEmpty { candidates.append(preferred) }
        if let device = deviceLocale, !device.isEmpty { candidates.append(device) }
        for candidate in candidates {
            if translations[candidate] != nil { return candidate }
            let language = candidate.split(separator: "-").first.map(String.init) ?? candidate
            if language != candidate, translations[language] != nil { return language }
        }
        return nil
    }

    public static func build(
        _ translations: [String: [String: String]]?,
        preferred: String? = nil,
        deviceLocale: String? = nil
    ) -> SankofaPulseTranslator? {
        guard let locale = resolveLocale(
            translations, preferred: preferred, deviceLocale: deviceLocale)
        else { return nil }
        guard let strings = translations?[locale] else { return nil }
        return SankofaPulseTranslator(strings: strings, locale: locale)
    }
}
