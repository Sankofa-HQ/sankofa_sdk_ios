import Foundation

/// Wire-shape types for the Pulse SDK. These mirror the server's
/// JSON envelopes from `server/engine/ee/pulse/` (handlers_handshake.go,
/// handlers_questions.go, handlers_ingest.go).
///
/// Kept in one file so the network layer + the renderer share a
/// single source of truth — drift here would silently break ingest.

public enum SankofaPulseSurveyKind: String, Codable, Sendable {
    case nps
    case csat
    case custom
    case serviceDesk = "service_desk"
}

public enum SankofaPulseQuestionKind: String, Codable, Sendable {
    case shortText = "short_text"
    case longText = "long_text"
    case number
    case rating
    case nps
    case single
    case multi
    case boolean
    case slider
    case date
    case statement
    case ranking
    case matrix
    case consent
    case imageChoice = "image_choice"
    case maxdiff
    case signature
    case file
    case payment
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SankofaPulseQuestionKind(rawValue: raw) ?? .unknown
    }
}

public struct SankofaPulseQuestionOption: Codable, Sendable, Hashable {
    public let key: String
    public let label: String
    public let imageURL: String?

    enum CodingKeys: String, CodingKey {
        case key, label
        case imageURL = "image_url"
    }
}

public struct SankofaPulseQuestion: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let kind: SankofaPulseQuestionKind
    public let prompt: String
    public let helptext: String?
    public let required: Bool
    public let orderIndex: Int
    public let options: [SankofaPulseQuestionOption]?
    /// JSON-encoded validation block; per-kind shape (see server
    /// answer_validation.go). Decoded lazily by the renderer that
    /// knows the expected shape for each kind.
    public let validation: SankofaPulseValidation?

    enum CodingKeys: String, CodingKey {
        case id, kind, prompt, helptext, required, options, validation
        case orderIndex = "order_index"
    }
}

/// Per-kind validation rules — opaque JSON object on the wire. We
/// decode lazily into per-kind structs at the renderer level.
public struct SankofaPulseValidation: Codable, Sendable, Hashable {
    public let raw: [String: SankofaPulseAnyJSON]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.raw = try container.decode([String: SankofaPulseAnyJSON].self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    public func int(_ key: String) -> Int? { raw[key]?.intValue }
    public func double(_ key: String) -> Double? { raw[key]?.doubleValue }
    public func string(_ key: String) -> String? { raw[key]?.stringValue }
    public func array(_ key: String) -> [SankofaPulseAnyJSON]? { raw[key]?.arrayValue }
}

/// Type-erased JSON value — the validation block needs to round-trip
/// arbitrary structures (the rows/columns of a matrix question, for
/// instance) without us baking in every per-kind shape here.
public enum SankofaPulseAnyJSON: Codable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([SankofaPulseAnyJSON])
    case object([String: SankofaPulseAnyJSON])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([SankofaPulseAnyJSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: SankofaPulseAnyJSON].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unsupported JSON value")
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let b):    try c.encode(b)
        case .int(let i):     try c.encode(i)
        case .double(let d):  try c.encode(d)
        case .string(let s):  try c.encode(s)
        case .array(let a):   try c.encode(a)
        case .object(let o):  try c.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    public var arrayValue: [SankofaPulseAnyJSON]? {
        if case .array(let a) = self { return a }; return nil
    }
}

public struct SankofaPulseSurvey: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let kind: SankofaPulseSurveyKind
    public let name: String
    public let description: String?
    public let questions: [SankofaPulseQuestion]
    public let theme: SankofaPulseTheme?

    public static func == (lhs: SankofaPulseSurvey, rhs: SankofaPulseSurvey) -> Bool {
        lhs.id == rhs.id
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct SankofaPulseTheme: Codable, Sendable, Hashable {
    public let primaryColor: String?
    public let backgroundColor: String?
    public let foregroundColor: String?
    public let mutedColor: String?
    public let borderColor: String?
    public let fontFamily: String?
    public let darkMode: String?
    public let logoURL: String?

    enum CodingKeys: String, CodingKey {
        case primaryColor = "primary_color"
        case backgroundColor = "background_color"
        case foregroundColor = "foreground_color"
        case mutedColor = "muted_color"
        case borderColor = "border_color"
        case fontFamily = "font_family"
        case darkMode = "dark_mode"
        case logoURL = "logo_url"
    }
}

public struct SankofaPulseHandshakeResponse: Codable, Sendable {
    public let surveys: [SankofaPulseSurvey]
}

/// Lightweight projection returned by GET /api/pulse/surveys —
/// pairs each survey's identity with its targeting rules so the
/// SDK can run local eligibility evaluation without a per-survey
/// bundle fetch. Mirrors the server's `sdkSurveySummary`.
public struct SankofaPulseSurveySummary: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let description: String?
    public let kind: SankofaPulseSurveyKind
    public let status: String
    public let slug: String?
    public let targetingRules: [SankofaPulseTargetingRule]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case kind
        case status
        case slug
        case targetingRules = "targeting_rules"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.kind = try c.decode(SankofaPulseSurveyKind.self, forKey: .kind)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        self.slug = try c.decodeIfPresent(String.self, forKey: .slug)
        self.targetingRules = try c.decodeIfPresent(
            [SankofaPulseTargetingRule].self, forKey: .targetingRules) ?? []
    }

    public init(
        id: String,
        name: String,
        description: String? = nil,
        kind: SankofaPulseSurveyKind,
        status: String,
        slug: String? = nil,
        targetingRules: [SankofaPulseTargetingRule] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.kind = kind
        self.status = status
        self.slug = slug
        self.targetingRules = targetingRules
    }
}

public struct SankofaPulseSurveysResponse: Codable, Sendable {
    public let surveys: [SankofaPulseSurveySummary]?
}

/// Full survey bundle — survey row + targeting rules + branching
/// rules. Mirrors the server's `sdkSurveyBundle`
/// (handlers_sdk_bundle.go). Themes, translations, and partial
/// state will land here as those features graduate; the Go-side
/// wire shape includes them all already.
///
/// On the wire, questions come on a sibling `questions` key rather
/// than nested in `survey`. We merge them into the survey during
/// decode so callers see one self-contained `survey` value with its
/// questions populated.
public struct SankofaPulseSurveyBundle: Codable, Sendable {
    public let survey: SankofaPulseSurvey
    public let targetingRules: [SankofaPulseTargetingRule]
    public let branchingRules: [SankofaPulseBranchingRule]

    /// Per-locale string overrides keyed first by BCP-47 locale tag
    /// (e.g. "en-US"), then by the dot-path key (e.g.
    /// "question.psq_q1.prompt"). Empty when the survey hasn't been
    /// translated.
    public let translations: [String: [String: String]]

    public init(
        survey: SankofaPulseSurvey,
        targetingRules: [SankofaPulseTargetingRule] = [],
        branchingRules: [SankofaPulseBranchingRule] = [],
        translations: [String: [String: String]] = [:]
    ) {
        self.survey = survey
        self.targetingRules = targetingRules
        self.branchingRules = branchingRules
        self.translations = translations
    }

    enum CodingKeys: String, CodingKey {
        case survey
        case questions
        case targetingRules = "targeting_rules"
        case branchingRules = "branching_rules"
        case translations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decode the questions sibling list and the survey row in
        // parallel, then merge the questions into the survey so
        // callers see one self-contained `survey` value.
        let questions = try c.decodeIfPresent(
            [SankofaPulseQuestion].self, forKey: .questions) ?? []
        if let baseSurvey = try c.decodeIfPresent(
            SankofaPulseSurvey.self, forKey: .survey) {
            self.survey = SankofaPulseSurvey(
                id: baseSurvey.id,
                kind: baseSurvey.kind,
                name: baseSurvey.name,
                description: baseSurvey.description,
                questions: questions,
                theme: baseSurvey.theme)
        } else {
            self.survey = SankofaPulseSurvey(
                id: "",
                kind: .custom,
                name: "",
                description: nil,
                questions: questions,
                theme: nil)
        }
        self.targetingRules = try c.decodeIfPresent(
            [SankofaPulseTargetingRule].self, forKey: .targetingRules) ?? []
        self.branchingRules = try c.decodeIfPresent(
            [SankofaPulseBranchingRule].self, forKey: .branchingRules) ?? []
        self.translations = try c.decodeIfPresent(
            [String: [String: String]].self, forKey: .translations) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(survey, forKey: .survey)
        try c.encode(survey.questions, forKey: .questions)
        try c.encode(targetingRules, forKey: .targetingRules)
        try c.encode(branchingRules, forKey: .branchingRules)
        try c.encode(translations, forKey: .translations)
    }
}

/// Respondent identity envelope. Mirrors the server's
/// `ingestRespondent` shape (server/engine/ee/pulse/handlers_ingest.go).
/// At least one of the three fields should be set; the server tolerates
/// all-empty for fully anonymous submissions but the dashboard groups
/// responses by the most-specific id present.
public struct SankofaPulseRespondent: Codable, Sendable {
    public let userId: String?
    public let externalId: String?
    public let email: String?

    public init(userId: String? = nil, externalId: String? = nil, email: String? = nil) {
        self.userId = userId
        self.externalId = externalId
        self.email = email
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case externalId = "external_id"
        case email
    }
}

/// Final-submit payload. The wire shape matches the server's
/// `ingestPayload`: `answers` is a map keyed by question_id (NOT a
/// list of {question_id, value} pairs — that earlier shape silently
/// 400'd in production because the Go decoder treats arrays + maps
/// as different types). Web + RN already speak this shape; iOS,
/// Android, and Flutter follow.
public struct SankofaPulseSubmitPayload: Codable, Sendable {
    public let surveyId: String
    public let respondent: SankofaPulseRespondent
    public let context: SankofaPulseContext?
    public let submittedAt: String?
    public let answers: [String: SankofaPulseAnyJSON]

    public init(
        surveyId: String,
        respondent: SankofaPulseRespondent = SankofaPulseRespondent(),
        context: SankofaPulseContext? = nil,
        submittedAt: String? = nil,
        answers: [String: SankofaPulseAnyJSON]
    ) {
        self.surveyId = surveyId
        self.respondent = respondent
        self.context = context
        self.submittedAt = submittedAt
        self.answers = answers
    }

    enum CodingKeys: String, CodingKey {
        case surveyId = "survey_id"
        case respondent
        case context
        case submittedAt = "submitted_at"
        case answers
    }
}

public struct SankofaPulseContext: Codable, Sendable {
    public let sessionId: String?
    public let anonymousId: String?
    public let platform: String?
    public let osVersion: String?
    public let appVersion: String?
    public let locale: String?
    /// Session id of the active replay recording, when replay is on.
    /// Lets the dashboard deep-link from a Pulse response straight
    /// to the recorded session. Nil when replay is disabled,
    /// sampled out, or not yet started.
    public let replaySessionId: String?

    public init(
        sessionId: String? = nil,
        anonymousId: String? = nil,
        platform: String? = nil,
        osVersion: String? = nil,
        appVersion: String? = nil,
        locale: String? = nil,
        replaySessionId: String? = nil
    ) {
        self.sessionId = sessionId
        self.anonymousId = anonymousId
        self.platform = platform
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.locale = locale
        self.replaySessionId = replaySessionId
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case anonymousId = "anonymous_id"
        case platform
        case osVersion = "os_version"
        case appVersion = "app_version"
        case locale
        case replaySessionId = "replay_session_id"
    }
}

/// Wire payload for `POST /api/pulse/partial`. Same answers shape
/// (map keyed by question_id) as the final-submit body so the SDK
/// doesn't have to reformat between save + submit.
public struct SankofaPulsePartialUpsert: Codable, Sendable {
    public let surveyId: String
    public let respondent: SankofaPulseRespondent
    public let context: SankofaPulseContext?
    public let answers: [String: SankofaPulseAnyJSON]
    public let currentQuestionId: String?

    public init(
        surveyId: String,
        respondent: SankofaPulseRespondent = SankofaPulseRespondent(),
        context: SankofaPulseContext? = nil,
        answers: [String: SankofaPulseAnyJSON] = [:],
        currentQuestionId: String? = nil
    ) {
        self.surveyId = surveyId
        self.respondent = respondent
        self.context = context
        self.answers = answers
        self.currentQuestionId = currentQuestionId
    }

    enum CodingKeys: String, CodingKey {
        case surveyId = "survey_id"
        case respondent
        case context
        case answers
        case currentQuestionId = "current_question_id"
    }
}

/// Shape returned by `POST /api/pulse/partial`.
public struct SankofaPulsePartialAck: Codable, Sendable {
    public let id: String?
    public let surveyId: String?
    public let currentQuestionId: String?
    public let versionNumber: Int?
    public let expiresAt: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case surveyId = "survey_id"
        case currentQuestionId = "current_question_id"
        case versionNumber = "version_number"
        case expiresAt = "expires_at"
        case updatedAt = "updated_at"
    }
}

/// Shape returned by `GET /api/pulse/partial`. Mirrors the server's
/// `ResponsePartial` row.
public struct SankofaPulsePartial: Codable, Sendable {
    public let id: String?
    public let surveyId: String?
    public let respondentExternalId: String?
    public let respondentUserId: String?
    public let respondentEmail: String?
    public let answers: [String: SankofaPulseAnyJSON]?
    public let currentQuestionId: String?
    public let versionNumber: Int?
    public let expiresAt: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case surveyId = "survey_id"
        case respondentExternalId = "respondent_external_id"
        case respondentUserId = "respondent_user_id"
        case respondentEmail = "respondent_email"
        case answers
        case currentQuestionId = "current_question_id"
        case versionNumber = "version_number"
        case expiresAt = "expires_at"
        case updatedAt = "updated_at"
    }
}

public struct SankofaPulseSubmitResponse: Codable, Sendable {
    public let id: String
    public let surveyId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case surveyId = "survey_id"
    }
}

/// Lifecycle events the SDK fires while a survey is on screen.
/// Hosts subscribe via `SankofaPulse.shared.on(...)` to wire Pulse
/// into their own analytics / CRM / replay tooling.
public enum SankofaPulseEvent: String, Sendable, Hashable {
    /// Fired right after the survey dialog opens.
    case surveyShown = "survey_shown"
    /// Fired when the respondent closes without submitting.
    case surveyDismissed = "survey_dismissed"
    /// Fired after a successful submission.
    case surveyCompleted = "survey_completed"
    /// Fired after a successful partial-state save.
    case surveyPartialSaved = "survey_partial_saved"
}

/// Payload delivered to every Pulse listener. `responseId` is only
/// populated on `.surveyCompleted`; `reason` is populated on
/// dismissal when we have one (e.g. eligibility miss).
public struct SankofaPulseEventPayload: Sendable {
    public let event: SankofaPulseEvent
    public let surveyId: String
    public let responseId: String?
    public let reason: String?

    public init(
        event: SankofaPulseEvent,
        surveyId: String,
        responseId: String? = nil,
        reason: String? = nil
    ) {
        self.event = event
        self.surveyId = surveyId
        self.responseId = responseId
        self.reason = reason
    }
}

/// Token returned by `SankofaPulse.shared.on(...)`. Hold it to keep
/// the listener alive; call `cancel()` to remove it.
public final class SankofaPulseSubscription {
    private var action: (() -> Void)?
    public init(_ action: @escaping () -> Void) { self.action = action }
    public func cancel() {
        action?()
        action = nil
    }
}
