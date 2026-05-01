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
            await MainActor.run {
                if presenter.view.window != nil {
                    self.present(
                        survey: bundle.survey,
                        branchingRules: bundle.branchingRules,
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
            flagValues: flags)
        return SankofaPulseTargeting.evaluate(rules: rules, context: ctx)
    }

    @MainActor
    private func present(
        survey: SankofaPulseSurvey,
        branchingRules: [SankofaPulseBranchingRule] = [],
        from presenter: UIViewController
    ) {
        let onSubmit: (SankofaPulseSubmitPayload) -> Void = { [weak self] payload in
            self?.handleSubmit(payload: payload, presenter: presenter)
        }
        let onDismiss: () -> Void = { [weak presenter] in
            presenter?.dismiss(animated: true)
        }
        let view = SankofaSurveyView(
            survey: survey,
            branchingRules: branchingRules,
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
        presenter.present(host, animated: true)
    }
    #endif

    // MARK: - Submission

    private func handleSubmit(
        payload: SankofaPulseSubmitPayload,
        presenter: AnyObject?
    ) {
        Task { [weak self] in
            guard let self = self, let client = self.client else { return }
            do {
                _ = try await client.submit(self.enrichContext(payload))
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
        let context = SankofaPulseContext(
            sessionId: Sankofa.shared.currentSessionId,
            anonymousId: Sankofa.shared.anonymousId,
            platform: "ios",
            osVersion: deviceOS(),
            appVersion: appVersion(),
            locale: Locale.current.identifier
        )
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
            context: context,
            submittedAt: payload.submittedAt,
            answers: payload.answers
        )
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
