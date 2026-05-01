#if canImport(SwiftUI)
import SwiftUI
import PencilKit

/// SwiftUI survey renderer. One question at a time with a Next /
/// Back / Submit footer. Renders all 19 question kinds the server
/// supports — falls back to a placeholder for unknown kinds so
/// SDK upgrades that lag the server don't crash the host.
@available(iOS 14.0, macOS 11.0, *)
public struct SankofaSurveyView: View {
    @StateObject private var coordinator: SankofaSurveyCoordinator

    public init(
        survey: SankofaPulseSurvey,
        branchingRules: [SankofaPulseBranchingRule] = [],
        translator: SankofaPulseTranslator? = nil,
        initialAnswers: [String: SankofaPulseAnyJSON] = [:],
        initialQuestionId: String? = nil,
        onProgress: ((_ answers: [String: SankofaPulseAnyJSON],
                      _ currentQuestionId: String) -> Void)? = nil,
        onSubmit: @escaping (SankofaPulseSubmitPayload) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        _coordinator = StateObject(
            wrappedValue: SankofaSurveyCoordinator(
                survey: survey,
                branchingRules: branchingRules,
                translator: translator,
                initialAnswers: initialAnswers,
                initialQuestionId: initialQuestionId,
                onProgress: onProgress,
                onSubmit: onSubmit,
                onDismiss: onDismiss))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ScrollView {
                if let q = coordinator.currentQuestion {
                    QuestionView(
                        question: q,
                        translator: coordinator.translator,
                        valueBinding: coordinator.binding(for: q))
                        .padding(.horizontal)
                        .foregroundColor(themeForeground)
                }
            }
            footer
        }
        .padding(.vertical, 16)
        .background(themeBackground)
        .environment(\.font, themeFont)
        // Flip the entire dialog tree into right-to-left reading
        // order when the resolved translation locale is RTL — even
        // if the host's app is LTR. Mirrors the Web SDK's `dir="rtl"`.
        .environment(\.layoutDirection,
            sankofaPulseLocaleIsRTL(coordinator.translator?.locale)
                ? .rightToLeft : .leftToRight)
    }

    // ── Theme resolution ───────────────────────────────────────
    //
    // We honour the seven theme fields on SankofaPulseTheme:
    //   primary_color    → accent (buttons, highlights)
    //   background_color → dialog background
    //   foreground_color → primary text
    //   muted_color      → secondary text + close button
    //   border_color     → input outlines (where applicable)
    //   font_family      → environment .font
    //   dark_mode        → "auto" / "light" / "dark"

    private var isDarkPalette: Bool {
        switch coordinator.survey.theme?.darkMode?.lowercased() {
        case "dark": return true
        case "light": return false
        default:
            #if canImport(UIKit)
            return UITraitCollection.current.userInterfaceStyle == .dark
            #else
            return false
            #endif
        }
    }

    private var themeAccent: Color {
        parseHex(coordinator.survey.theme?.primaryColor)
            ?? (isDarkPalette ? Color(red: 0.984, green: 0.443, blue: 0.522)
                              : Color(red: 0.957, green: 0.247, blue: 0.369))
    }

    private var themeBackground: Color {
        parseHex(coordinator.survey.theme?.backgroundColor)
            ?? (isDarkPalette ? Color(red: 0.039, green: 0.039, blue: 0.039)
                              : Color.white)
    }

    private var themeForeground: Color {
        parseHex(coordinator.survey.theme?.foregroundColor)
            ?? (isDarkPalette ? Color(red: 0.98, green: 0.98, blue: 0.98)
                              : Color(red: 0.094, green: 0.094, blue: 0.106))
    }

    private var themeMuted: Color {
        parseHex(coordinator.survey.theme?.mutedColor)
            ?? (isDarkPalette ? Color(red: 0.631, green: 0.631, blue: 0.667)
                              : Color(red: 0.443, green: 0.443, blue: 0.478))
    }

    private var themeFont: Font? {
        if let family = coordinator.survey.theme?.fontFamily, !family.isEmpty {
            return .custom(family, size: UIFont.systemFontSize)
        }
        return nil
    }

    private func parseHex(_ hex: String?) -> Color? {
        guard let raw = hex else { return nil }
        let cleaned = raw.replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard cleaned.count == 6 || cleaned.count == 8 else { return nil }
        let scanner = Scanner(string: cleaned)
        var hexInt: UInt64 = 0
        guard scanner.scanHexInt64(&hexInt) else { return nil }
        let a, r, g, b: UInt64
        if cleaned.count == 8 {
            a = (hexInt & 0xFF000000) >> 24
            r = (hexInt & 0x00FF0000) >> 16
            g = (hexInt & 0x0000FF00) >> 8
            b = hexInt & 0x000000FF
        } else {
            a = 0xFF
            r = (hexInt & 0xFF0000) >> 16
            g = (hexInt & 0x00FF00) >> 8
            b = hexInt & 0x0000FF
        }
        return Color(.sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: Double(a) / 255.0)
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            if let urlString = coordinator.survey.theme?.logoURL,
               let url = URL(string: urlString),
               !urlString.isEmpty {
                // 24pt logo block alongside the survey title. We use
                // AsyncImage on iOS 15+; on iOS 14 we silently skip
                // (no good fallback without a third-party image lib).
                if #available(iOS 15.0, macCatalyst 15.0, macOS 12.0, *) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(coordinator.translator?.surveyName(coordinator.survey)
                     ?? coordinator.survey.name)
                    .font(.headline)
                    .foregroundColor(themeForeground)
                if let desc = coordinator.translator?.surveyDescription(coordinator.survey)
                                ?? coordinator.survey.description,
                   !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(themeMuted)
                }
            }
            Spacer()
            Button(action: { coordinator.dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(themeMuted)
                    .padding(8)
            }
            .accessibilityLabel("Close survey")
        }
        .padding(.horizontal)
        ProgressView(value: coordinator.progress)
            .accentColor(themeAccent)
            .padding(.horizontal)
    }

    @ViewBuilder
    private var footer: some View {
        if let error = coordinator.errorMessage {
            // Error red is intentionally NOT theme-resolved — it
            // must always be unmistakable as an error, not blend
            // with the brand.
            let errorColor = isDarkPalette
                ? Color(red: 0.984, green: 0.647, blue: 0.647)
                : Color(red: 0.863, green: 0.149, blue: 0.149)
            Text(error).font(.caption).foregroundColor(errorColor).padding(.horizontal)
        }
        HStack {
            Button(coordinator.canGoBack ? "Back" : "Cancel") {
                coordinator.canGoBack ? coordinator.previous() : coordinator.dismiss()
            }
            .foregroundColor(themeMuted)
            Spacer()
            primarySubmitButton
        }
        .padding(.horizontal)
    }

    /// `.borderedProminent` requires iOS 15+. Fall back to the
    /// default styling on iOS 14 — still legible, just less polished.
    @ViewBuilder
    private var primarySubmitButton: some View {
        let title = coordinator.isLast ? "Submit" : "Next"
        let action: () -> Void = {
            coordinator.isLast ? coordinator.submit() : coordinator.next()
        }
        if #available(iOS 15.0, macCatalyst 15.0, macOS 12.0, *) {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .tint(themeAccent)
                .disabled(coordinator.isSubmitting)
        } else {
            Button(title, action: action)
                .foregroundColor(themeAccent)
                .disabled(coordinator.isSubmitting)
        }
    }
}

// MARK: - Coordinator

@available(iOS 14.0, macOS 11.0, *)
final class SankofaSurveyCoordinator: ObservableObject {
    @Published var currentIndex: Int = 0
    @Published var values: [String: SankofaPulseAnyJSON] = [:]
    @Published var isSubmitting: Bool = false
    @Published var errorMessage: String? = nil

    let survey: SankofaPulseSurvey
    let branchingRules: [SankofaPulseBranchingRule]
    let translator: SankofaPulseTranslator?
    let onProgress: ((_ answers: [String: SankofaPulseAnyJSON],
                      _ currentQuestionId: String) -> Void)?
    let onSubmit: (SankofaPulseSubmitPayload) -> Void
    let onDismiss: () -> Void

    /// Stack of indices the respondent has visited; used to retrace
    /// Back across skip-logic jumps. We push on every forward step
    /// (whether a fall-through or a branching jump) and pop on Back.
    private var history: [Int] = []

    init(
        survey: SankofaPulseSurvey,
        branchingRules: [SankofaPulseBranchingRule] = [],
        translator: SankofaPulseTranslator? = nil,
        initialAnswers: [String: SankofaPulseAnyJSON] = [:],
        initialQuestionId: String? = nil,
        onProgress: ((_ answers: [String: SankofaPulseAnyJSON],
                      _ currentQuestionId: String) -> Void)? = nil,
        onSubmit: @escaping (SankofaPulseSubmitPayload) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        // Sort by order_index so the SDK matches the dashboard's
        // canonical question sequence.
        let sorted = survey.questions.sorted { $0.orderIndex < $1.orderIndex }
        self.survey = SankofaPulseSurvey(
            id: survey.id, kind: survey.kind, name: survey.name,
            description: survey.description, questions: sorted, theme: survey.theme)
        self.branchingRules = branchingRules
        self.translator = translator
        self.onProgress = onProgress
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss
        self.values = initialAnswers
        if let initialId = initialQuestionId,
           let target = sorted.firstIndex(where: { $0.id == initialId }) {
            self.currentIndex = target
        }
    }

    var currentQuestion: SankofaPulseQuestion? {
        survey.questions.indices.contains(currentIndex)
            ? survey.questions[currentIndex] : nil
    }
    var canGoBack: Bool { !history.isEmpty }
    var isLast: Bool { currentIndex == survey.questions.count - 1 }
    var progress: Double {
        guard !survey.questions.isEmpty else { return 0 }
        return Double(currentIndex + 1) / Double(survey.questions.count)
    }

    func binding(for question: SankofaPulseQuestion) -> Binding<SankofaPulseAnyJSON?> {
        Binding(
            get: { self.values[question.id] },
            set: { self.values[question.id] = $0; self.errorMessage = nil }
        )
    }

    func next() {
        guard let q = currentQuestion else { return }
        if q.required && !hasAnswer(for: q) {
            errorMessage = "This question is required."
            return
        }
        // Ask the branching evaluator first. The Outcome can:
        //  - end the survey early (sentinel)
        //  - jump to a target question id
        //  - fall through (next by order_index)
        let outcome = SankofaPulseBranching.resolveNext(
            rules: branchingRules,
            currentQuestionId: q.id,
            answers: values)
        if outcome.nextQuestionId == SankofaPulseBranchingEndOfSurvey {
            submit()
            return
        }
        if !outcome.nextQuestionId.isEmpty {
            if let target = survey.questions.firstIndex(
                where: { $0.id == outcome.nextQuestionId }) {
                history.append(currentIndex)
                currentIndex = target
                emitProgress()
                return
            }
            // Target id not found in this survey — fall through
            // rather than getting stuck. A "skip to a question that
            // no longer exists" is a survey-builder error, not
            // something to crash the host on.
        }
        if currentIndex < survey.questions.count - 1 {
            history.append(currentIndex)
            currentIndex += 1
            emitProgress()
        }
    }

    private func emitProgress() {
        guard let cb = onProgress, let q = currentQuestion else { return }
        cb(values, q.id)
    }
    func previous() {
        if let prev = history.popLast() { currentIndex = prev }
    }

    func submit() {
        guard let q = currentQuestion else { return }
        if q.required && !hasAnswer(for: q) {
            errorMessage = "This question is required."
            return
        }
        isSubmitting = true
        var answers: [String: SankofaPulseAnyJSON] = [:]
        for question in survey.questions {
            if let v = values[question.id] { answers[question.id] = v }
        }
        let payload = SankofaPulseSubmitPayload(
            surveyId: survey.id,
            respondent: SankofaPulseRespondent(),
            context: nil,
            submittedAt: nil,
            answers: answers
        )
        onSubmit(payload)
    }

    func dismiss() { onDismiss() }

    private func hasAnswer(for q: SankofaPulseQuestion) -> Bool {
        guard let v = values[q.id] else { return false }
        switch v {
        case .null: return false
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        default: return true
        }
    }
}

// MARK: - Per-question views

@available(iOS 14.0, macOS 11.0, *)
struct QuestionView: View {
    let question: SankofaPulseQuestion
    let translator: SankofaPulseTranslator?
    @Binding var valueBinding: SankofaPulseAnyJSON?

    init(
        question: SankofaPulseQuestion,
        translator: SankofaPulseTranslator? = nil,
        valueBinding: Binding<SankofaPulseAnyJSON?>
    ) {
        self.question = question
        self.translator = translator
        self._valueBinding = valueBinding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(translator?.questionPrompt(question) ?? question.prompt)
                .font(.body)
                .fontWeight(.medium)
            if let h = translator?.questionHelptext(question) ?? question.helptext,
               !h.isEmpty {
                Text(h)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            input
        }
    }

    /// Build a per-question option label resolver. Returns the
    /// translated label when a translator is set; otherwise the
    /// source `option.label` straight from the survey row.
    private func labelFor(_ option: SankofaPulseQuestionOption) -> String {
        translator?.optionLabel(question, option) ?? option.label
    }

    @ViewBuilder
    private var input: some View {
        switch question.kind {
        case .shortText: ShortTextInput(value: $valueBinding)
        case .longText:  LongTextInput(value: $valueBinding)
        case .number:    NumberInput(value: $valueBinding, validation: question.validation)
        case .nps:       NPSInput(value: $valueBinding)
        case .rating:    RatingInput(value: $valueBinding, validation: question.validation)
        case .single:    SingleInput(value: $valueBinding, options: question.options ?? [], labelFor: labelFor)
        case .multi:     MultiInput(value: $valueBinding, options: question.options ?? [], labelFor: labelFor)
        case .boolean:   BooleanInput(value: $valueBinding)
        case .slider:    SliderInput(value: $valueBinding, validation: question.validation)
        case .date:      DateInput(value: $valueBinding)
        case .statement: EmptyView()
        case .ranking:   RankingInput(value: $valueBinding, options: question.options ?? [], labelFor: labelFor)
        case .matrix:    MatrixInput(value: $valueBinding, validation: question.validation)
        case .consent:   ConsentInput(value: $valueBinding)
        case .imageChoice: SingleInput(value: $valueBinding, options: question.options ?? [], labelFor: labelFor)
        case .maxdiff:   MaxDiffInput(value: $valueBinding, options: question.options ?? [], labelFor: labelFor)
        case .signature: SignatureInput(value: $valueBinding)
        case .file:      FilePlaceholder()
        case .payment:   PaymentPlaceholder()
        case .unknown:   Text("[Unsupported question kind]")
            .font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - Inputs

@available(iOS 14.0, macOS 11.0, *)
private struct ShortTextInput: View {
    @Binding var value: SankofaPulseAnyJSON?
    @State private var text: String = ""
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .onAppear { if case .string(let s) = value { text = s } }
            .onChange(of: text) { newValue in
                value = newValue.isEmpty ? nil : .string(newValue)
            }
    }
}

@available(iOS 14.0, macOS 11.0, *)
private struct LongTextInput: View {
    @Binding var value: SankofaPulseAnyJSON?
    @State private var text: String = ""
    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                TextField("", text: $text, axis: .vertical)
                    .lineLimit(4...8)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextEditor(text: $text)
                    .frame(minHeight: 96)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3)))
            }
        }
        .onAppear { if case .string(let s) = value { text = s } }
        .onChange(of: text) { newValue in
            value = newValue.isEmpty ? nil : .string(newValue)
        }
    }
}

@available(iOS 14.0, macOS 11.0, *)
private struct NumberInput: View {
    @Binding var value: SankofaPulseAnyJSON?
    let validation: SankofaPulseValidation?
    @State private var text: String = ""
    var body: some View {
        TextField("0", text: $text)
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
            .onAppear { if let n = value?.doubleValue { text = String(n) } }
            .onChange(of: text) { newValue in
                if let n = Double(newValue) { value = .double(n) }
                else if newValue.isEmpty { value = nil }
            }
    }
}

@available(iOS 14.0, macOS 11.0, *)
private struct NPSInput: View {
    @Binding var value: SankofaPulseAnyJSON?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ForEach(0...10, id: \.self) { n in
                    Button(action: { value = .int(n) }) {
                        Text("\(n)")
                            .font(.callout)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(value?.intValue == n
                                ? Color.accentColor : Color.secondary.opacity(0.1))
                            .foregroundColor(value?.intValue == n ? .white : .primary)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Not at all").font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text("Extremely").font(.caption2).foregroundColor(.secondary)
            }
        }
    }
}

@available(iOS 14.0, macOS 11.0, *)
private struct RatingInput: View {
    @Binding var value: SankofaPulseAnyJSON?
    let validation: SankofaPulseValidation?
    var body: some View {
        let max = validation?.int("max") ?? 5
        let min = validation?.int("min") ?? 1
        HStack {
            ForEach(min...max, id: \.self) { n in
                Button(action: { value = .int(n) }) {
                    Image(systemName: (value?.intValue ?? 0) >= n
                          ? "star.fill" : "star")
                        .font(.title2)
                        .foregroundColor(.yellow)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

@available(iOS 14.0, macOS 11.0, *)
private struct SingleInput: View {
    @Binding var value: SankofaPulseAnyJSON?
    let options: [SankofaPulseQuestionOption]
    let labelFor: (SankofaPulseQuestionOption) -> String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(options, id: \.key) { opt in
                Button(action: { value = .string(opt.key) }) {
                    HStack {
                        Image(systemName: value?.stringValue == opt.key
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(value?.stringValue == opt.key
                                             ? .accentColor : .secondary)
                        Text(labelFor(opt))
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

@available(iOS 14.0, macOS 11.0, *)
private struct MultiInput: View {
    @Binding var value: SankofaPulseAnyJSON?
    let options: [SankofaPulseQuestionOption]
    let labelFor: (SankofaPulseQuestionOption) -> String

    private var selected: Set<String> {
        guard case .array(let arr) = value else { return [] }
        return Set(arr.compactMap { $0.stringValue })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(options, id: \.key) { opt in
                Button(action: { toggle(opt.key) }) {
                    HStack {
                        Image(systemName: selected.contains(opt.key)
                              ? "checkmark.square.fill" : "square")
                            .foregroundColor(selected.contains(opt.key)
                                             ? .accentColor : .secondary)
                        Text(labelFor(opt))
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }
    private func toggle(_ key: String) {
        var next = selected
        if next.contains(key) { next.remove(key) } else { next.insert(key) }
        value = .array(next.sorted().map { .string($0) })
    }
}

@available(iOS 14.0, macOS 11.0, *)
private struct BooleanInput: View {
    @Binding var value: SankofaPulseAnyJSON?
    var body: some View {
        Picker("", selection: Binding(
            get: { value?.intValue == 1 ? true : (value?.intValue == 0 ? false : nil as Bool?) },
            set: { newValue in
                if let v = newValue { value = .bool(v) } else { value = nil }
            })
        ) {
            Text("Yes").tag(Bool?.some(true))
            Text("No").tag(Bool?.some(false))
        }
        .pickerStyle(.segmented)
    }
}

@available(iOS 14.0, macOS 11.0, *)
private struct SliderInput: View {
    @Binding var value: SankofaPulseAnyJSON?
    let validation: SankofaPulseValidation?
    @State private var current: Double = 50
    var body: some View {
        let min = validation?.double("min") ?? 0
        let max = validation?.double("max") ?? 100
        let step = validation?.double("step") ?? 1
        VStack {
            Slider(value: $current, in: min...max, step: step)
                .onAppear { current = value?.doubleValue ?? min }
                .onChange(of: current) { v in value = .double(v) }
            Text("\(current, specifier: "%.0f")")
                .font(.caption).foregroundColor(.secondary)
        }
    }
}

@available(iOS 14.0, macOS 11.0, *)
private struct DateInput: View {
    @Binding var value: SankofaPulseAnyJSON?
    @State private var date: Date = Date()
    var body: some View {
        DatePicker("", selection: $date, displayedComponents: [.date])
            .labelsHidden()
            .onChange(of: date) { d in
                let f = ISO8601DateFormatter()
                value = .string(f.string(from: d))
            }
    }
}

@available(iOS 14.0, macOS 11.0, *)
private struct ConsentInput: View {
    @Binding var value: SankofaPulseAnyJSON?
    @State private var checked = false
    var body: some View {
        Toggle("I agree", isOn: $checked)
            .onChange(of: checked) { c in
                value = c ? .bool(true) : nil
            }
    }
}

@available(iOS 14.0, macOS 11.0, *)
private struct RankingInput: View {
    @Binding var value: SankofaPulseAnyJSON?
    let options: [SankofaPulseQuestionOption]
    let labelFor: (SankofaPulseQuestionOption) -> String
    @State private var ordered: [SankofaPulseQuestionOption] = []
    var body: some View {
        List {
            ForEach(ordered, id: \.key) { opt in
                Text(labelFor(opt))
            }
            .onMove { indices, dest in
                ordered.move(fromOffsets: indices, toOffset: dest)
                value = .array(ordered.map { .string($0.key) })
            }
        }
        .environment(\.editMode, .constant(.active))
        .frame(minHeight: CGFloat(options.count) * 44)
        .onAppear {
            if ordered.isEmpty { ordered = options }
            value = .array(ordered.map { .string($0.key) })
        }
    }
}

@available(iOS 14.0, macOS 11.0, *)
private struct MatrixInput: View {
    @Binding var value: SankofaPulseAnyJSON?
    let validation: SankofaPulseValidation?

    private struct Pair: Hashable { let key: String; let label: String }
    private var rows: [Pair] { extractPairs(validation?.array("rows")) }
    private var cols: [Pair] { extractPairs(validation?.array("columns")) }

    @State private var picks: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.key) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.label).font(.caption).foregroundColor(.secondary)
                    HStack {
                        ForEach(cols, id: \.key) { col in
                            Button(action: { setPick(row: row.key, col: col.key) }) {
                                Text(col.label)
                                    .font(.caption2)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(picks[row.key] == col.key
                                                ? Color.accentColor : Color.secondary.opacity(0.1))
                                    .foregroundColor(picks[row.key] == col.key ? .white : .primary)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .onAppear { restoreFromValue() }
    }
    private func setPick(row: String, col: String) {
        picks[row] = col
        var obj: [String: SankofaPulseAnyJSON] = [:]
        for (k, v) in picks { obj[k] = .string(v) }
        value = .object(obj)
    }
    private func restoreFromValue() {
        if case .object(let o) = value {
            for (k, v) in o {
                if case .string(let s) = v { picks[k] = s }
            }
        }
    }
    private func extractPairs(_ arr: [SankofaPulseAnyJSON]?) -> [Pair] {
        guard let arr = arr else { return [] }
        return arr.compactMap { entry in
            guard case .object(let o) = entry else { return nil }
            guard let k = o["key"]?.stringValue,
                  let l = o["label"]?.stringValue else { return nil }
            return Pair(key: k, label: l)
        }
    }
}

@available(iOS 14.0, macOS 11.0, *)
private struct MaxDiffInput: View {
    @Binding var value: SankofaPulseAnyJSON?
    let options: [SankofaPulseQuestionOption]
    let labelFor: (SankofaPulseQuestionOption) -> String
    @State private var best: String = ""
    @State private var worst: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Text("Best").font(.caption).foregroundColor(.secondary).frame(width: 50, alignment: .leading)
                Spacer()
                Text("Worst").font(.caption).foregroundColor(.secondary).frame(width: 50, alignment: .trailing)
            }
            ForEach(options, id: \.key) { opt in
                HStack {
                    Button(action: { setBest(opt.key) }) {
                        Image(systemName: best == opt.key ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(best == opt.key ? .accentColor : .secondary)
                    }.buttonStyle(.plain).disabled(worst == opt.key)
                    Text(labelFor(opt)).frame(maxWidth: .infinity)
                    Button(action: { setWorst(opt.key) }) {
                        Image(systemName: worst == opt.key ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(worst == opt.key ? .red : .secondary)
                    }.buttonStyle(.plain).disabled(best == opt.key)
                }
            }
        }
        .onAppear { restoreFromValue() }
    }
    private func setBest(_ k: String) {
        best = k
        if worst == k { worst = "" }
        publish()
    }
    private func setWorst(_ k: String) {
        worst = k
        if best == k { best = "" }
        publish()
    }
    private func publish() {
        if !best.isEmpty && !worst.isEmpty {
            value = .object(["best": .string(best), "worst": .string(worst)])
        } else { value = nil }
    }
    private func restoreFromValue() {
        if case .object(let o) = value {
            best = o["best"]?.stringValue ?? ""
            worst = o["worst"]?.stringValue ?? ""
        }
    }
}

@available(iOS 14.0, macOS 11.0, *)
private struct SignatureInput: View {
    @Binding var value: SankofaPulseAnyJSON?
    @State private var canvas = PKCanvasView()
    var body: some View {
        VStack {
            SignatureCanvasRepresentable(canvas: $canvas, onChange: capture)
                .frame(height: 160)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Clear") {
                    canvas.drawing = PKDrawing()
                    value = nil
                }.font(.caption)
            }
        }
    }
    private func capture() {
        let image = canvas.drawing.image(
            from: canvas.bounds, scale: UIScreen.main.scale)
        if let data = image.pngData() {
            let base64 = data.base64EncodedString()
            value = .string("data:image/png;base64,\(base64)")
        }
    }
}

@available(iOS 14.0, *)
private struct SignatureCanvasRepresentable: UIViewRepresentable {
    @Binding var canvas: PKCanvasView
    var onChange: () -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.delegate = context.coordinator
        return canvas
    }
    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let onChange: () -> Void
        init(onChange: @escaping () -> Void) { self.onChange = onChange }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { onChange() }
    }
}

@available(iOS 14.0, macOS 11.0, *)
private struct FilePlaceholder: View {
    var body: some View {
        Text("File upload not yet implemented in this SDK release.")
            .font(.caption).foregroundColor(.secondary)
    }
}

@available(iOS 14.0, macOS 11.0, *)
private struct PaymentPlaceholder: View {
    var body: some View {
        Text("Payment input requires host integration with a payments SDK.")
            .font(.caption).foregroundColor(.secondary)
    }
}

#endif
