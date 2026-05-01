import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Public entry point for Pulse on iOS.
///
/// ## Quick Start
/// ```swift
/// // After Sankofa.shared.initialize(...)
/// SankofaPulse.shared.register()
///
/// // Programmatic show:
/// SankofaPulse.shared.show(surveyId: "psv_abc", from: viewController)
///
/// // Or fetch the matching surveys for the current user/screen and
/// // pick one yourself:
/// SankofaPulse.shared.activeMatchingSurveys { surveys in ... }
/// ```
///
/// SwiftUI hosts can use the `.sankofaPulse(surveyId:isPresented:)`
/// view modifier (defined alongside) to drive presentation off
/// existing state instead of imperative show calls.
@available(iOS 14.0, macOS 11.0, *)
public final class SankofaPulse {

    // MARK: - Singleton

    public static let shared = SankofaPulse()
    private init() {}

    // MARK: - Internal state

    private var client: SankofaPulseClient?
    private var queue: SankofaPulseQueue?
    private var registered: Bool = false
    private var cachedSurveys: [SankofaPulseSurvey] = []

    /// In-flight partial-save task. Coalesce on a 750ms debounce so
    /// a fast-clicking respondent who skips through several questions
    /// only burns one save call; the latest pending state always wins.
    private var partialSaveTask: Task<Void, Never>? = nil
    private let partialSaveDebounceNs: UInt64 = 750_000_000

    /// Lifecycle event listener registry. Per-event buckets so an
    /// `onCompleted` subscriber doesn't run for `dismissed` events.
    private var listeners: [SankofaPulseEvent: [UUID: (SankofaPulseEventPayload) -> Void]] = [:]
    private let listenerLock = NSLock()

    /// Snapshot of the active replay session id, refreshed on the
    /// MainActor when a survey presents. Cached so the partial-save
    /// background task can read it without bouncing back to main.
    private var cachedReplaySessionId: String?

    private var apiKey: String? { Sankofa.shared.apiKeyString }
    private var endpoint: String? { Sankofa.shared.endpointString }

    // MARK: - Public lifecycle

    /// Wires Pulse to the host's already-initialised Sankofa SDK.
    /// Idempotent — calling twice is a no-op. Returns false if the
    /// host hasn't called `Sankofa.shared.initialize` yet.
    @discardableResult
    public func register() -> Bool {
        guard !registered else { return true }
        guard let apiKey = apiKey, !apiKey.isEmpty,
              let endpoint = endpoint, !endpoint.isEmpty else {
            return false
        }
        self.client = SankofaPulseClient(endpoint: endpoint, apiKey: apiKey)
        if let store = SankofaPulseQueue.defaultStoreURL() {
            self.queue = SankofaPulseQueue(storeURL: store)
        }
        self.registered = true
        Task { await refreshSurveys() }
        return true
    }

    // MARK: - Public reads

    // MARK: - Lifecycle event subscriptions

    /// Subscribe to one Pulse lifecycle event. Returns a
    /// `SankofaPulseSubscription` — call `cancel()` to remove the
    /// listener. Mirrors the Web SDK's `Sankofa.pulse.on(event,
    /// listener)` shape so a host swapping between platforms doesn't
    /// relearn the API.
    @discardableResult
    public func on(
        _ event: SankofaPulseEvent,
        listener: @escaping (SankofaPulseEventPayload) -> Void
    ) -> SankofaPulseSubscription {
        let id = UUID()
        listenerLock.lock()
        var bucket = listeners[event] ?? [:]
        bucket[id] = listener
        listeners[event] = bucket
        listenerLock.unlock()
        return SankofaPulseSubscription { [weak self] in
            guard let self = self else { return }
            self.listenerLock.lock()
            self.listeners[event]?.removeValue(forKey: id)
            if self.listeners[event]?.isEmpty == true {
                self.listeners.removeValue(forKey: event)
            }
            self.listenerLock.unlock()
        }
    }

    private func emit(_ payload: SankofaPulseEventPayload) {
        // Auto-emit into the host's analytics queue with a "$pulse."
        // prefix so survey lifecycle shows up in the same dashboard
        // / warehouse as every other event the host tracks. Listeners
        // registered through on(...) still fire as well — that path
        // is for in-process integrations (Slack pings, conditional
        // UI), not for analytics.
        var trackProps: [String: Any] = ["survey_id": payload.surveyId]
        if let rid = payload.responseId { trackProps["response_id"] = rid }
        if let reason = payload.reason { trackProps["reason"] = reason }
        Sankofa.shared.track(
            "$pulse.\(payload.event.rawValue)", properties: trackProps)

        listenerLock.lock()
        let snapshot = listeners[payload.event]?.values.map { $0 } ?? []
        listenerLock.unlock()
        for l in snapshot { l(payload) }
    }

    /// Refreshes the cached survey list from the server. Called
    /// automatically on register() and after a successful submit.
    public func refreshSurveys() async {
        guard let client = client else { return }
        do {
            let r = try await client.handshake()
            await MainActor.run { self.cachedSurveys = r.surveys }
            // Drain any queued submissions while we have a working
            // network connection.
            await drainQueue()
        } catch {
            // Swallow — handshake failures shouldn't crash the host;
            // the next call retries.
        }
    }

    /// Returns the surveys eligible for the current user/session.
    /// In v1 this is just every published survey from the handshake;
    /// targeting evaluation lands in a future release.
    public func activeMatchingSurveys(
        _ completion: @escaping ([SankofaPulseSurvey]) -> Void
    ) {
        if !cachedSurveys.isEmpty {
            completion(cachedSurveys); return
        }
        Task {
            await refreshSurveys()
            await MainActor.run { completion(self.cachedSurveys) }
        }
    }

    // MARK: - Programmatic presentation

    #if canImport(UIKit)
    /// Programmatically show a survey by id. Fetches the full
    /// bundle, runs targeting locally; if the respondent isn't
    /// eligible we silently skip (the host can call `isEligible`
    /// up-front to decide on its own what to do with a 'no').
    ///
    /// `properties` populates `userProperties` for `user_property`
    /// rules; `flags` populates `flagValues` for `feature_flag`
    /// rules. Other context fields auto-fill from Sankofa core
    /// (identity, session) or are left empty.
    @MainActor
    public func show(
        surveyId: String,
        from presenter: UIViewController,
        properties: [String: SankofaPulseAnyJSON] = [:],
        flags: [String: SankofaPulseAnyJSON] = [:]
    ) {
        guard registered else { return }
        Task { [weak self, weak presenter] in
            guard let self = self, let presenter = presenter,
                  let client = self.client else { return }
            let bundle: SankofaPulseSurveyBundle
            do {
                bundle = try await client.loadSurveyBundle(surveyId)
            } catch {
                // Bundle unavailable — silently bail; the host can
                // retry on the next show().
                return
            }
            if bundle.survey.id.isEmpty { return }
            let decision = self.evaluateLocally(
                surveyId: surveyId,
                rules: bundle.targetingRules,
                properties: properties,
                flags: flags)
            guard decision.eligible else { return }

            // Hydrate from any in-progress partial. Load failures
            // (offline, expired, server error) are swallowed — the
            // survey simply starts fresh, which is strictly better
            // than refusing to show.
            let externalId = Sankofa.shared.distinctId
            var partial: SankofaPulsePartial? = nil
            if !externalId.isEmpty {
                partial = try? await client.loadPartial(
                    surveyId: surveyId, externalId: externalId)
            }

            let translator = SankofaPulseTranslator.build(
                bundle.translations,
                deviceLocale: Locale.current.identifier)
            await MainActor.run {
                if presenter.view.window != nil {
                    self.present(
                        survey: bundle.survey,
                        branchingRules: bundle.branchingRules,
                        translator: translator,
                        externalId: externalId,
                        initialAnswers: partial?.answers ?? [:],
                        initialQuestionId: partial?.currentQuestionId,
                        from: presenter)
                }
            }
        }
    }

    /// Returns the targeting Decision for `surveyId` without
    /// showing. Useful for hosts that want to render their own UI
    /// affordance ("answer a quick survey?") only if eligible.
    public func isEligible(
        surveyId: String,
        properties: [String: SankofaPulseAnyJSON] = [:],
        flags: [String: SankofaPulseAnyJSON] = [:]
    ) async -> SankofaPulseDecision {
        guard registered else {
            return SankofaPulseDecision(eligible: false,
                reason: "pulse not registered")
        }
        guard let client = client else {
            return SankofaPulseDecision(eligible: false, reason: "no client")
        }
        let bundle: SankofaPulseSurveyBundle
        do {
            bundle = try await client.loadSurveyBundle(surveyId)
        } catch {
            return SankofaPulseDecision(
                eligible: false, reason: "bundle fetch failed")
        }
        if bundle.survey.id.isEmpty {
            return SankofaPulseDecision(
                eligible: false, reason: "survey not found")
        }
        return evaluateLocally(
            surveyId: surveyId,
            rules: bundle.targetingRules,
            properties: properties,
            flags: flags)
    }

    private func evaluateLocally(
        surveyId: String,
        rules: [SankofaPulseTargetingRule],
        properties: [String: SankofaPulseAnyJSON],
        flags: [String: SankofaPulseAnyJSON]
    ) -> SankofaPulseDecision {
        if rules.isEmpty { return SankofaPulseDecision(eligible: true) }
        let distinct = Sankofa.shared.distinctId
        let ctx = SankofaPulseEligibilityContext(
            surveyId: surveyId,
            respondentExternalId: distinct,
            userProperties: properties,
            flagValues: mergeWithSwitchFlags(flags))
        return SankofaPulseTargeting.evaluate(rules: rules, context: ctx)
    }

    /// Merge SankofaSwitch flag values into the eligibility context
    /// so feature_flag rules can target without the host re-passing
    /// every flag. Host-supplied `overrides` win over Switch values
    /// by key — that lets a host force a flag for testing without
    /// the runtime Switch decision overriding them.
    private func mergeWithSwitchFlags(
        _ overrides: [String: SankofaPulseAnyJSON]
    ) -> [String: SankofaPulseAnyJSON] {
        var merged: [String: SankofaPulseAnyJSON] = [:]
        // Walk every known Switch key; SankofaSwitch returns an empty
        // list before init, which is exactly the no-op we want.
        for key in SankofaSwitch.shared.getAllKeys() {
            guard let decision = SankofaSwitch.shared.getDecision(key) else { continue }
            // For variant flags we expose the variant string; for
            // boolean flags we expose the bool value. The targeting
            // evaluator's jsonEqual handles either.
            if !decision.variant.isEmpty {
                merged[key] = .string(decision.variant)
            } else {
                merged[key] = .bool(decision.value)
            }
        }
        for (k, v) in overrides { merged[k] = v }
        return merged
    }

    @MainActor
    private func present(
        survey: SankofaPulseSurvey,
        branchingRules: [SankofaPulseBranchingRule] = [],
        translator: SankofaPulseTranslator? = nil,
        externalId: String = "",
        initialAnswers: [String: SankofaPulseAnyJSON] = [:],
        initialQuestionId: String? = nil,
        from presenter: UIViewController
    ) {
        let surveyId = survey.id
        let onSubmit: (SankofaPulseSubmitPayload) -> Void = { [weak self] payload in
            self?.handleSubmit(
                payload: payload, presenter: presenter, surveyId: surveyId)
            // Server auto-deletes the partial on a successful insert.
            // Best-effort client-side delete too so a dismissed-then-
            // resumed-in-a-different-session doesn't surface a stale
            // partial during the brief window.
            if !externalId.isEmpty {
                self?.deletePartialAsync(surveyId: surveyId, externalId: externalId)
            }
        }
        let onDismiss: () -> Void = { [weak self, weak presenter] in
            self?.emit(SankofaPulseEventPayload(
                event: .surveyDismissed, surveyId: surveyId))
            // Keep the partial intact for resume — that's the point.
            presenter?.dismiss(animated: true)
        }
        let onProgress: ((_ answers: [String: SankofaPulseAnyJSON],
                          _ currentQuestionId: String) -> Void)?
        if externalId.isEmpty {
            onProgress = nil
        } else {
            onProgress = { [weak self] answers, currentQuestionId in
                self?.schedulePartialSave(
                    surveyId: surveyId,
                    externalId: externalId,
                    answers: answers,
                    currentQuestionId: currentQuestionId)
            }
        }
        let view = SankofaSurveyView(
            survey: survey,
            branchingRules: branchingRules,
            translator: translator,
            initialAnswers: initialAnswers,
            initialQuestionId: initialQuestionId,
            onProgress: onProgress,
            onSubmit: onSubmit,
            onDismiss: onDismiss)
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .pageSheet
        // sheetPresentationController + detents require iOS 15 / Mac
        // Catalyst 15. Below that, .pageSheet still presents — just
        // without the medium/large detents and grab handle.
        if #available(iOS 15.0, macCatalyst 15.0, *) {
            if let sheet = host.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
            }
        }
        // Snapshot the replay session id while we're on the main
        // actor so the partial-save background task can read it
        // without re-hopping. We refresh again on every present so
        // long-lived SankofaPulse instances pick up replay-restart.
        cachedReplaySessionId = Sankofa.shared.replaySessionId

        presenter.present(host, animated: true)
        emit(SankofaPulseEventPayload(
            event: .surveyShown, surveyId: surveyId))
    }
    #endif

    // MARK: - Submission

    private func handleSubmit(
        payload: SankofaPulseSubmitPayload,
        presenter: AnyObject?,
        surveyId: String
    ) {
        Task { [weak self] in
            guard let self = self, let client = self.client else { return }
            do {
                let resp = try await client.submit(self.enrichContext(payload))
                // Fire SURVEY_COMPLETED with the server-issued response
                // id so hosts can correlate against dashboard rows.
                self.emit(SankofaPulseEventPayload(
                    event: .surveyCompleted,
                    surveyId: surveyId,
                    responseId: resp.id))
                await MainActor.run {
                    #if canImport(UIKit)
                    (presenter as? UIViewController)?.dismiss(animated: true)
                    #endif
                }
            } catch {
                // Network failed — enqueue for later flush.
                await self.queue?.enqueue(self.enrichContext(payload))
                await MainActor.run {
                    #if canImport(UIKit)
                    (presenter as? UIViewController)?.dismiss(animated: true)
                    #endif
                }
            }
        }
    }

    private func enrichContext(_ payload: SankofaPulseSubmitPayload)
    -> SankofaPulseSubmitPayload {
        let distinct = Sankofa.shared.distinctId
        let respondent = SankofaPulseRespondent(
            userId: payload.respondent.userId,
            externalId: payload.respondent.externalId
                ?? (distinct.isEmpty ? nil : distinct),
            email: payload.respondent.email
        )
        return SankofaPulseSubmitPayload(
            surveyId: payload.surveyId,
            respondent: respondent,
            context: buildPulseContext(),
            submittedAt: payload.submittedAt,
            answers: payload.answers
        )
    }

    /// Build the per-call context used by both the final submit
    /// payload and any partial-save calls. Centralising here keeps
    /// "what we tell the server about this device" in one place —
    /// drift between submit + partial would surface as inconsistent
    /// dashboard rows for the same respondent.
    private func buildPulseContext() -> SankofaPulseContext {
        SankofaPulseContext(
            sessionId: Sankofa.shared.currentSessionId,
            anonymousId: Sankofa.shared.anonymousId,
            platform: "ios",
            osVersion: deviceOS(),
            appVersion: appVersion(),
            locale: Locale.current.identifier,
            replaySessionId: cachedReplaySessionId
        )
    }

    /// Schedule a debounced partial save. Cancels any in-flight
    /// save — old state is strictly stale.
    private func schedulePartialSave(
        surveyId: String,
        externalId: String,
        answers: [String: SankofaPulseAnyJSON],
        currentQuestionId: String
    ) {
        partialSaveTask?.cancel()
        partialSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.partialSaveDebounceNs ?? 750_000_000)
            } catch {
                return
            }
            guard let self = self, let client = self.client else { return }
            let payload = SankofaPulsePartialUpsert(
                surveyId: surveyId,
                respondent: SankofaPulseRespondent(externalId: externalId),
                context: self.buildPulseContext(),
                answers: answers,
                currentQuestionId: currentQuestionId
            )
            do {
                _ = try await client.savePartial(payload)
                self.emit(SankofaPulseEventPayload(
                    event: .surveyPartialSaved, surveyId: surveyId))
            } catch {
                // Swallow — partial save failures don't block the
                // respondent. The next save attempt will retry, and
                // worst case the host's resume window narrows.
            }
        }
    }

    private func deletePartialAsync(surveyId: String, externalId: String) {
        Task { [weak self] in
            try? await self?.client?.deletePartial(
                surveyId: surveyId, externalId: externalId)
        }
    }

    private func drainQueue() async {
        guard let queue = queue, let client = client else { return }
        await queue.drain { try await client.submit($0) }
    }

    // MARK: - Helpers

    private func deviceOS() -> String {
        #if canImport(UIKit)
        return "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    private func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return short.isEmpty ? build : "\(short) (\(build))"
    }
}

#if canImport(SwiftUI) && canImport(UIKit)
@available(iOS 14.0, *)
public extension View {
    /// SwiftUI presentation helper. Drives the survey sheet off a
    /// boolean binding the host already manages.
    func sankofaPulse(surveyId: String, isPresented: Binding<Bool>) -> some View {
        modifier(SankofaPulsePresentation(surveyId: surveyId, isPresented: isPresented))
    }
}

@available(iOS 14.0, *)
private struct SankofaPulsePresentation: ViewModifier {
    let surveyId: String
    @Binding var isPresented: Bool
    @State private var resolved: SankofaPulseSurvey?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: { resolved = nil }) {
                if let s = resolved {
                    SankofaSurveyView(
                        survey: s,
                        onSubmit: { payload in
                            Task {
                                if let endpoint = Sankofa.shared.endpointString,
                                   let key = Sankofa.shared.apiKeyString {
                                    let client = SankofaPulseClient(
                                        endpoint: endpoint, apiKey: key)
                                    _ = try? await client.submit(payload)
                                }
                                await MainActor.run { isPresented = false }
                            }
                        },
                        onDismiss: { isPresented = false }
                    )
                } else {
                    ProgressView().onAppear { Task { await resolve() } }
                }
            }
    }

    private func resolve() async {
        await SankofaPulse.shared.refreshSurveys()
        SankofaPulse.shared.activeMatchingSurveys { list in
            resolved = list.first { $0.id == surveyId }
        }
    }
}
#endif
