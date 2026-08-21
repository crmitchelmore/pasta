import AppKit
import PastaCore
import PastaDetectors
import PastaSync
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Detection Rules Settings Tab

struct DetectionRulesSettingsTab: View {
    private enum Defaults {
        static let skipAPIKeys = "pasta.skipAPIKeys"
        static let extractContent = "pasta.extractContent"
    }

    private enum Evaluation {
        /// Regex benchmarking is expensive; wait for typing to settle first.
        static let debounceNanoseconds: UInt64 = 300_000_000
    }

    @State private var configuration: DetectorConfiguration = DetectorConfigurationStore.load()
    @State private var saveMessage: String?
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var isReparsing: Bool = false
    @State private var reparseCurrent: Int = 0
    @State private var reparseTotal: Int = 0
    @State private var showReparseConfirmation: Bool = false
    @State private var reparseSummary: String? = nil

    @State private var advancedDetector: BuiltInDetectorKind? = nil
    @State private var advancedEnabledDraft: Bool = false
    @State private var advancedPatternsDraft: String = ""
    @State private var advancedSelectedStrictness: DetectorStrictness = .medium

    @State private var editingCustomDetector: CustomDetectorDefinition? = nil
    @State private var newCustomName: String = ""
    @State private var newCustomPattern: String = ""
    @State private var newCustomCaseInsensitive: Bool = true

    @State private var newPatternPerformance: RegexPerformanceResult? = nil
    @State private var newPatternEvaluationTask: Task<Void, Never>? = nil
    @State private var advancedPatternsPerformance: RegexPerformanceResult? = nil
    @State private var advancedPatternsEvaluationTask: Task<Void, Never>? = nil

    var body: some View {
        Form {
            Section {
                Picker("Default strictness", selection: $configuration.globalStrictness) {
                    ForEach(DetectorStrictness.allCases, id: \.self) { strictness in
                        Text(strictness.displayName).tag(strictness)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: configuration.globalStrictness) { _, _ in
                    persistConfiguration()
                }

                Text("Strict reduces false positives, medium is balanced (recommended), and lax captures more loose patterns.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Global Profile", systemImage: "dial.medium")
            }

            Section {
                ForEach(BuiltInDetectorKind.allCases) { detector in
                    let rule = configuration.rule(for: detector)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(detector.title)
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Toggle("Enabled", isOn: enabledBinding(for: detector))
                                .labelsHidden()
                            Button("Advanced…") {
                                openAdvancedEditor(for: detector)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Picker("Strictness", selection: strictnessBinding(for: detector)) {
                            ForEach(DetectorStrictnessOverride.allCases, id: \.self) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .pickerStyle(.menu)

                        Text("Effective profile: \(effectiveStrictnessSummary(for: detector))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if rule.useAdvancedPatterns, !rule.cleanedPatterns.isEmpty {
                            HStack(spacing: 8) {
                                Text("Advanced regex active")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                performanceBadge(RegexPerformanceCache.shared.result(patterns: rule.cleanedPatterns))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Label("Built-in Detectors", systemImage: "shield.lefthalf.filled")
            }

            Section {
                ForEach(configuration.customDetectors) { custom in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(custom.name)
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Toggle("Enabled", isOn: customEnabledBinding(for: custom.id))
                                .labelsHidden()
                            Button("Edit…") {
                                editingCustomDetector = custom
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button(role: .destructive) {
                                removeCustomDetector(custom.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        HStack(spacing: 8) {
                            Text(custom.pattern)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            performanceBadge(
                                RegexPerformanceCache.shared.result(
                                    pattern: custom.pattern,
                                    options: custom.isCaseInsensitive ? [.caseInsensitive] : []
                                )
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Label("Custom Detectors", systemImage: "wand.and.stars")
            }

            Section {
                TextField("Name (e.g. Customer ID)", text: $newCustomName)
                TextField("Regex pattern", text: $newCustomPattern)
                    .font(.system(.body, design: .monospaced))
                Toggle("Case insensitive", isOn: $newCustomCaseInsensitive)

                if !newCustomPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 8) {
                        Text("Pattern performance")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let newPatternPerformance {
                            performanceBadge(newPatternPerformance)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                Button("Add Custom Detector") {
                    addCustomDetector()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newCustomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newCustomPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Label("Add New Detector", systemImage: "plus.circle")
            }

            Section {
                HStack {
                    Text("Reclassify existing history")
                    Spacer()

                    if isReparsing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Reparse History…") {
                            showReparseConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if isReparsing {
                    ProgressView(value: reparseProgressFraction)
                        .progressViewStyle(.linear)
                    Text("Processing \(reparseCurrent) of \(reparseTotal) entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let reparseSummary {
                    Text(reparseSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Runs current detector rules across all saved entries and rebuilds extracted child items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Maintenance", systemImage: "wrench.and.screwdriver")
            }

            if let saveMessage {
                Section {
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Detection Rules Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .confirmationDialog(
            "Reparse clipboard history?",
            isPresented: $showReparseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reparse Now") {
                reparseHistory()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This refreshes content types and metadata for all existing entries and recreates extracted child items.")
        }
        .sheet(item: $advancedDetector) { detector in
            builtInAdvancedSheet(for: detector)
        }
        .sheet(item: $editingCustomDetector) { detector in
            customDetectorSheet(detector: detector)
        }
        .onAppear {
            configuration = DetectorConfigurationStore.load()
        }
        .onChange(of: newCustomPattern) { _, _ in
            scheduleNewPatternEvaluation()
        }
        .onChange(of: newCustomCaseInsensitive) { _, _ in
            scheduleNewPatternEvaluation()
        }
    }

    /// Debounced, off-main-thread regex benchmark for the "add detector" field.
    private func scheduleNewPatternEvaluation() {
        newPatternEvaluationTask?.cancel()
        newPatternPerformance = nil

        let pattern = newCustomPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let caseInsensitive = newCustomCaseInsensitive
        guard !pattern.isEmpty else { return }

        newPatternEvaluationTask = Task {
            try? await Task.sleep(nanoseconds: Evaluation.debounceNanoseconds)
            guard !Task.isCancelled else { return }

            let result = await withCancellableDetachedTask(priority: .utility) { () -> RegexPerformanceResult? in
                guard !Task.isCancelled else { return nil }
                return RegexPerformanceCache.shared.result(
                    pattern: pattern,
                    options: caseInsensitive ? [.caseInsensitive] : []
                )
            }

            guard !Task.isCancelled, let result else { return }
            newPatternPerformance = result
        }
    }

    /// Debounced, off-main-thread regex benchmark for the advanced patterns editor.
    private func scheduleAdvancedPatternsEvaluation() {
        advancedPatternsEvaluationTask?.cancel()
        advancedPatternsPerformance = nil

        let patterns = parsedPatterns(from: advancedPatternsDraft)
        guard !patterns.isEmpty else { return }

        advancedPatternsEvaluationTask = Task {
            try? await Task.sleep(nanoseconds: Evaluation.debounceNanoseconds)
            guard !Task.isCancelled else { return }

            let result = await withCancellableDetachedTask(priority: .utility) { () -> RegexPerformanceResult? in
                guard !Task.isCancelled else { return nil }
                return RegexPerformanceCache.shared.result(patterns: patterns)
            }

            guard !Task.isCancelled, let result else { return }
            advancedPatternsPerformance = result
        }
    }

    private func enabledBinding(for detector: BuiltInDetectorKind) -> Binding<Bool> {
        Binding(
            get: { configuration.rule(for: detector).isEnabled },
            set: { value in
                var rule = configuration.rule(for: detector)
                rule.isEnabled = value
                configuration.setRule(rule, for: detector)
                persistConfiguration()
            }
        )
    }

    private func strictnessBinding(for detector: BuiltInDetectorKind) -> Binding<DetectorStrictnessOverride> {
        Binding(
            get: { configuration.rule(for: detector).strictnessOverride },
            set: { value in
                var rule = configuration.rule(for: detector)
                rule.strictnessOverride = value
                configuration.setRule(rule, for: detector)
                persistConfiguration()
            }
        )
    }

    private func customEnabledBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                configuration.customDetectors.first(where: { $0.id == id })?.isEnabled ?? false
            },
            set: { value in
                guard let index = configuration.customDetectors.firstIndex(where: { $0.id == id }) else { return }
                configuration.customDetectors[index].isEnabled = value
                persistConfiguration()
            }
        )
    }

    private func openAdvancedEditor(for detector: BuiltInDetectorKind) {
        let rule = configuration.rule(for: detector)
        advancedEnabledDraft = rule.useAdvancedPatterns
        advancedSelectedStrictness = configuration.strictness(for: detector)
        let configuredPatterns = rule.cleanedPatterns
        if configuredPatterns.isEmpty {
            let defaults = defaultAdvancedPatterns(for: detector, strictness: advancedSelectedStrictness)
            advancedPatternsDraft = defaults.joined(separator: "\n")
        } else {
            advancedPatternsDraft = configuredPatterns.joined(separator: "\n")
        }
        advancedDetector = detector
    }

    private func builtInAdvancedSheet(for detector: BuiltInDetectorKind) -> some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Selected detector") {
                        Text(detector.title)
                            .font(.callout.weight(.semibold))
                    }
                    LabeledContent("Selected profile") {
                        Text(effectiveStrictnessSummary(for: detector))
                            .font(.callout.weight(.semibold))
                    }

                    if configuration.rule(for: detector).cleanedPatterns.isEmpty {
                        Text("Default regex presets for this profile are loaded automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Showing your saved advanced regex for this detector.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Current Selection", systemImage: "scope")
                }

                Section {
                    Toggle("Use advanced regex overrides", isOn: $advancedEnabledDraft)

                    TextEditor(text: $advancedPatternsDraft)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button("Reset to \(advancedSelectedStrictness.displayName) defaults") {
                        advancedPatternsDraft = defaultAdvancedPatterns(for: detector, strictness: advancedSelectedStrictness)
                            .joined(separator: "\n")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text("One regex per line. If a capture group exists, group 1 is used as the extracted value.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label(detector.title, systemImage: "slider.horizontal.3")
                }

                if !parsedPatterns(from: advancedPatternsDraft).isEmpty {
                    Section {
                        HStack(spacing: 8) {
                            Text("Performance")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let result = advancedPatternsPerformance {
                                performanceBadge(result)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        if !advancedEnabledDraft {
                            Text("Enable advanced regex overrides to apply these patterns.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let result = advancedPatternsPerformance {
                            Text(result.details)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let compileError = result.compileError {
                                Text(compileError)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .onChange(of: advancedPatternsDraft, initial: true) { _, _ in
                scheduleAdvancedPatternsEvaluation()
            }
            .navigationTitle("Advanced Regex - \(detector.title)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        advancedDetector = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var rule = configuration.rule(for: detector)
                        rule.useAdvancedPatterns = advancedEnabledDraft
                        rule.advancedPatterns = parsedPatterns(from: advancedPatternsDraft)
                        configuration.setRule(rule, for: detector)
                        persistConfiguration(showMessage: true)
                        advancedDetector = nil
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private func customDetectorSheet(detector: CustomDetectorDefinition) -> some View {
        CustomDetectorEditorSheet(
            detector: detector,
            onSave: { updated in
                guard let index = configuration.customDetectors.firstIndex(where: { $0.id == updated.id }) else { return }
                configuration.customDetectors[index] = updated
                persistConfiguration(showMessage: true)
                editingCustomDetector = nil
            },
            onCancel: {
                editingCustomDetector = nil
            }
        )
    }

    private var reparseProgressFraction: Double {
        guard reparseTotal > 0 else { return 0 }
        return Double(reparseCurrent) / Double(reparseTotal)
    }

    private func parsedPatterns(from rawValue: String) -> [String] {
        rawValue
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func defaultAdvancedPatterns(for detector: BuiltInDetectorKind, strictness: DetectorStrictness) -> [String] {
        detector.builtInPatterns(for: strictness)
    }

    private func effectiveStrictnessSummary(for detector: BuiltInDetectorKind) -> String {
        let rule = configuration.rule(for: detector)
        let effective = configuration.strictness(for: detector).displayName
        switch rule.strictnessOverride {
        case .inherit:
            return "Inherit (\(configuration.globalStrictness.displayName))"
        case .lax, .medium, .strict:
            return effective
        }
    }

    private func addCustomDetector() {
        let name = newCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = newCustomPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !pattern.isEmpty else { return }

        // Memoized: the debounced field evaluation has usually already run this.
        let result = RegexPerformanceCache.shared.result(
            pattern: pattern,
            options: newCustomCaseInsensitive ? [.caseInsensitive] : []
        )
        if result.rating == .invalid {
            errorMessage = result.compileError ?? "Invalid regular expression."
            showError = true
            return
        }

        configuration.customDetectors.append(
            CustomDetectorDefinition(
                name: name,
                pattern: pattern,
                isEnabled: true,
                isCaseInsensitive: newCustomCaseInsensitive,
                confidence: 0.75
            )
        )
        persistConfiguration(showMessage: true)
        newCustomName = ""
        newCustomPattern = ""
        newCustomCaseInsensitive = true
        newPatternPerformance = nil
    }

    private func removeCustomDetector(_ id: UUID) {
        configuration.customDetectors.removeAll { $0.id == id }
        persistConfiguration(showMessage: true)
    }

    private func persistConfiguration(showMessage: Bool = false) {
        do {
            try DetectorConfigurationStore.save(configuration)
            if showMessage {
                saveMessage = "Detection rules saved."
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func reparseHistory() {
        isReparsing = true
        reparseSummary = nil
        reparseCurrent = 0
        reparseTotal = 0

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let database = try DatabaseManager()
                let detector = ContentTypeDetector()
                let detectorConfiguration = DetectorConfigurationStore.load()
                let extractContent = UserDefaults.standard.bool(forKey: Defaults.extractContent)
                let skipAPIKeys = UserDefaults.standard.bool(forKey: Defaults.skipAPIKeys)

                let total = try database.countPrimaryEntries()
                DispatchQueue.main.async {
                    reparseTotal = total
                }

                // Walk the library in keyset-paged chunks with one write
                // transaction per page, so a 100k-entry library never has to
                // fit (with its rebuilt children) in memory at once.
                let pageSize = 500
                var cursor: DatabaseManager.PrimaryEntryCursor? = nil
                var processed = 0
                var totalUpdated = 0
                var totalRemoved = 0
                var totalInserted = 0

                while true {
                    let page = try database.fetchPrimaryEntries(after: cursor, limit: pageSize)
                    guard !page.isEmpty else { break }
                    cursor = DatabaseManager.PrimaryEntryCursor(after: page[page.count - 1])

                    var updates: [DatabaseManager.ReclassificationUpdate] = []
                    var parentIDs: [UUID] = []
                    parentIDs.reserveCapacity(page.count)
                    var extractedEntries: [ClipboardEntry] = []

                    for entry in page {
                        guard entry.contentType != .image && entry.contentType != .screenshot else { continue }
                        parentIDs.append(entry.id)

                        let output = detector.detect(in: entry.content, configuration: detectorConfiguration)
                        if output.primaryType != entry.contentType || output.metadataJSON != entry.metadata {
                            updates.append(
                                DatabaseManager.ReclassificationUpdate(
                                    entryID: entry.id,
                                    contentType: output.primaryType,
                                    metadata: output.metadataJSON
                                )
                            )
                        }

                        if extractContent {
                            for item in output.extractedItems where !(skipAPIKeys && item.contentType == .apiKey) {
                                extractedEntries.append(
                                    ClipboardEntry(
                                        content: item.content,
                                        contentType: item.contentType,
                                        timestamp: entry.timestamp,
                                        sourceApp: entry.sourceApp,
                                        metadata: item.metadataJSON,
                                        parentEntryId: entry.id
                                    )
                                )
                            }
                        }
                    }

                    let result = try database.applyReclassificationChunk(
                        updates: updates,
                        parentIDs: parentIDs,
                        extractedEntries: extractedEntries
                    )
                    totalUpdated += result.updatedEntries
                    totalRemoved += result.removedExtractedEntries
                    totalInserted += result.insertedExtractedEntries

                    processed += page.count
                    let current = min(processed, total)
                    DispatchQueue.main.async {
                        reparseCurrent = current
                    }
                }

                // The old whole-library rebuild dropped every child row, which
                // also swept children of since-deleted parents; do that sweep
                // explicitly now that children are rebuilt per parent.
                totalRemoved += try database.deleteOrphanedExtractedEntries()

                let summaryProcessed = processed
                let summaryUpdated = totalUpdated
                let summaryRemoved = totalRemoved
                let summaryInserted = totalInserted
                DispatchQueue.main.async {
                    reparseSummary = "Reparsed \(summaryProcessed) entries, updated \(summaryUpdated), removed \(summaryRemoved), rebuilt \(summaryInserted) extracted entries."
                    isReparsing = false
                    NotificationCenter.default.post(name: .entriesDidChange, object: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    showError = true
                    isReparsing = false
                }
            }
        }
    }

    private func performanceBadge(_ result: RegexPerformanceResult) -> some View {
        let color = performanceColor(for: result.rating)

        return Text(result.rating.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func performanceColor(for rating: RegexPerformanceRating) -> Color {
        switch rating {
        case .fast:
            return .green
        case .reasonable:
            return .orange
        case .slow, .invalid:
            return .red
        }
    }
}

struct CustomDetectorEditorSheet: View {
    private enum Evaluation {
        static let debounceNanoseconds: UInt64 = 300_000_000
    }

    @State private var name: String
    @State private var pattern: String
    @State private var isEnabled: Bool
    @State private var isCaseInsensitive: Bool
    @State private var confidence: Double

    @State private var performance: RegexPerformanceResult? = nil
    @State private var evaluationTask: Task<Void, Never>? = nil

    let detectorID: UUID
    let onSave: (CustomDetectorDefinition) -> Void
    let onCancel: () -> Void

    init(
        detector: CustomDetectorDefinition,
        onSave: @escaping (CustomDetectorDefinition) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _name = State(initialValue: detector.name)
        _pattern = State(initialValue: detector.pattern)
        _isEnabled = State(initialValue: detector.isEnabled)
        _isCaseInsensitive = State(initialValue: detector.isCaseInsensitive)
        _confidence = State(initialValue: detector.confidence)
        self.detectorID = detector.id
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextEditor(text: $pattern)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 150)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Toggle("Enabled", isOn: $isEnabled)
                    Toggle("Case insensitive", isOn: $isCaseInsensitive)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Confidence: \(String(format: "%.2f", confidence))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $confidence, in: 0.5...1.0, step: 0.05)
                    }
                }

                Section {
                    if let result = performance {
                        Text("Performance: \(result.rating.displayName)")
                        Text(result.details)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let compileError = result.compileError {
                            Text(compileError)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text("Performance")
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }
            .onChange(of: pattern, initial: true) { _, _ in
                scheduleEvaluation()
            }
            .onChange(of: isCaseInsensitive) { _, _ in
                scheduleEvaluation()
            }
            .navigationTitle("Edit Custom Detector")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Only compile the regex here; benchmarking is handled by the
                    // debounced evaluation above.
                    let canSave = !trimmedName.isEmpty
                        && RegexPerformanceEvaluator.isValid(
                            pattern: trimmedPattern,
                            options: isCaseInsensitive ? [.caseInsensitive] : []
                        )

                    Button("Save") {
                        onSave(
                            CustomDetectorDefinition(
                                id: detectorID,
                                name: trimmedName,
                                pattern: trimmedPattern,
                                isEnabled: isEnabled,
                                isCaseInsensitive: isCaseInsensitive,
                                confidence: confidence
                            )
                        )
                    }
                    .disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    /// Debounced, off-main-thread regex benchmark for the editor sheet.
    private func scheduleEvaluation() {
        evaluationTask?.cancel()
        performance = nil

        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let caseInsensitive = isCaseInsensitive

        evaluationTask = Task {
            try? await Task.sleep(nanoseconds: Evaluation.debounceNanoseconds)
            guard !Task.isCancelled else { return }

            let result = await withCancellableDetachedTask(priority: .utility) { () -> RegexPerformanceResult? in
                guard !Task.isCancelled else { return nil }
                return RegexPerformanceCache.shared.result(
                    pattern: trimmedPattern,
                    options: caseInsensitive ? [.caseInsensitive] : []
                )
            }

            guard !Task.isCancelled, let result else { return }
            performance = result
        }
    }
}
