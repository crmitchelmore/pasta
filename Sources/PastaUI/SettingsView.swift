import AppKit
import PastaCore
import PastaDetectors
import PastaSync
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    private enum Defaults {
        static let launchAtLogin = "pasta.launchAtLogin"
        static let maxEntries = "pasta.maxEntries"
        static let excludedApps = "pasta.excludedApps"
        static let appMode = "pasta.appMode"
        static let appearance = "pasta.appearance"
        static let retentionDays = "pasta.retentionDays"
        static let pauseMonitoring = "pasta.pauseMonitoring"
        static let playSounds = "pasta.playSounds"
        static let showNotifications = "pasta.showNotifications"
        static let storeImages = "pasta.storeImages"
        static let deduplicateEntries = "pasta.deduplicateEntries"
        static let skipAPIKeys = "pasta.skipAPIKeys"
        static let extractContent = "pasta.extractContent"
    }

    private enum Layout {
        static let settingsWidth: CGFloat = 760
        static let settingsHeight: CGFloat = 500
    }

    @AppStorage(Defaults.launchAtLogin) private var launchAtLogin: Bool = false
    @AppStorage(Defaults.maxEntries) private var maxEntries: Int = 0
    @AppStorage(Defaults.excludedApps) private var excludedAppsText: String = ""
    @AppStorage(Defaults.appMode) private var appMode: String = "both"
    @AppStorage(Defaults.appearance) private var appearance: String = "system"
    @AppStorage(Defaults.retentionDays) private var retentionDays: Int = 0
    @AppStorage(Defaults.pauseMonitoring) private var pauseMonitoring: Bool = false
    @AppStorage(Defaults.playSounds) private var playSounds: Bool = false
    @AppStorage(Defaults.showNotifications) private var showNotifications: Bool = false
    @AppStorage(Defaults.storeImages) private var storeImages: Bool = true
    @AppStorage(Defaults.deduplicateEntries) private var deduplicateEntries: Bool = true
    @AppStorage(Defaults.skipAPIKeys) private var skipAPIKeys: Bool = false
    @AppStorage(Defaults.extractContent) private var extractContent: Bool = true

    @State private var selectedTab: SettingsTab = .general
    
    private let checkForUpdates: (() -> Void)?
    private let automaticallyChecksForUpdates: Binding<Bool>?
    private let syncManager: SyncManager?
    private let allEntries: (() -> [ClipboardEntry])?
    private let markSynced: (([UUID]) -> Void)?
    private let syncedCount: (() -> Int)?

    public init(
        syncManager: SyncManager? = nil,
        allEntries: (() -> [ClipboardEntry])? = nil,
        markSynced: (([UUID]) -> Void)? = nil,
        syncedCount: (() -> Int)? = nil,
        checkForUpdates: (() -> Void)? = nil,
        automaticallyChecksForUpdates: Binding<Bool>? = nil
    ) {
        self.syncManager = syncManager
        self.allEntries = allEntries
        self.markSynced = markSynced
        self.syncedCount = syncedCount
        self.checkForUpdates = checkForUpdates
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(
                launchAtLogin: $launchAtLogin,
                appMode: $appMode,
                appearance: $appearance
            )
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            .tag(SettingsTab.general)

            ClipboardSettingsTab(
                pauseMonitoring: $pauseMonitoring,
                storeImages: $storeImages,
                deduplicateEntries: $deduplicateEntries,
                skipAPIKeys: $skipAPIKeys,
                extractContent: $extractContent,
                playSounds: $playSounds,
                showNotifications: $showNotifications,
                excludedAppsText: $excludedAppsText
            )
            .tabItem {
                Label("Clipboard", systemImage: "doc.on.clipboard")
            }
            .tag(SettingsTab.clipboard)

            DetectionRulesSettingsTab()
                .tabItem {
                    Label("Detection", systemImage: "line.3.horizontal.decrease.circle")
                }
                .tag(SettingsTab.detection)

            StorageSettingsTab(
                retentionDays: $retentionDays,
                maxEntries: $maxEntries
            )
            .tabItem {
                Label("Storage", systemImage: "internaldrive")
            }
            .tag(SettingsTab.storage)
            
            if let syncManager {
                iCloudSettingsTab(
                    syncManager: syncManager,
                    allEntries: allEntries ?? { [] },
                    markSynced: markSynced,
                    syncedCount: syncedCount ?? { 0 }
                )
                    .tabItem {
                        Label("iCloud", systemImage: "icloud")
                    }
                    .tag(SettingsTab.iCloud)
            }
            
            ImportSettingsTab()
            .tabItem {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .tag(SettingsTab.import)
            
            AboutSettingsTab(
                checkForUpdates: checkForUpdates,
                automaticallyChecksForUpdates: automaticallyChecksForUpdates
            )
            .tabItem {
                Label("About", systemImage: "info.circle")
            }
            .tag(SettingsTab.about)
            
            TipJarView()
            .tabItem {
                Label("Tip Jar", systemImage: "heart.fill")
            }
            .tag(SettingsTab.tipJar)
        }
        // Keep this width in sync with tab count to avoid macOS "Navigation Tab Bar" overflow.
        .frame(width: Layout.settingsWidth, height: Layout.settingsHeight)
        .padding(.top, 8)
        .withAppearance()
        .tint(PastaTheme.accent)
    }

    private enum SettingsTab: Hashable {
        case general, clipboard, detection, storage, iCloud, `import`, about, tipJar
    }
}

// MARK: - General Settings Tab

private struct GeneralSettingsTab: View {
    @Binding var launchAtLogin: Bool
    @Binding var appMode: String
    @Binding var appearance: String

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Open Pasta")
                    Spacer()
                    ShortcutRecorderView(
                        hotKey: PastaHotKey.load()
                    )
                }
            } header: {
                Label("Keyboard Shortcut", systemImage: "keyboard")
            }

            Section {
                Toggle("Launch Pasta at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            let manager = LaunchAtLoginManager()
                            launchAtLogin = try manager.setEnabled(newValue)
                        } catch {
                            launchAtLogin = LaunchAtLoginManager().isEnabled
                        }
                    }
            } header: {
                Label("Startup", systemImage: "power")
            }

            Section {
                Picker("Show Pasta in", selection: $appMode) {
                    Text("Menu bar only").tag("menuBar")
                    Text("Dock only").tag("dock")
                    Text("Menu bar and Dock").tag("both")
                }
                .pickerStyle(.radioGroup)

                Text("Dock mode shows Pasta in ⌘⇥ app switcher.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("App Icon", systemImage: "macwindow")
            }
            
            Section {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.radioGroup)
                
                Text("Choose how Pasta appears on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = LaunchAtLoginManager().isEnabled
        }
    }
}

// MARK: - Clipboard Settings Tab

private struct ClipboardSettingsTab: View {
    @Binding var pauseMonitoring: Bool
    @Binding var storeImages: Bool
    @Binding var deduplicateEntries: Bool
    @Binding var skipAPIKeys: Bool
    @Binding var extractContent: Bool
    @Binding var playSounds: Bool
    @Binding var showNotifications: Bool
    @Binding var excludedAppsText: String

    var body: some View {
        Form {
            Section {
                Toggle("Pause clipboard monitoring", isOn: $pauseMonitoring)
                Toggle("Store copied images", isOn: $storeImages)
                Toggle("Deduplicate identical entries", isOn: $deduplicateEntries)
            } header: {
                Label("Capture", systemImage: "rectangle.and.paperclip")
            }

            Section {
                Toggle("Extract emails, URLs, and more", isOn: $extractContent)
                Text("When enabled, emails, URLs, API keys, and other items found within copied text are also saved as separate entries for easy searching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Content Extraction", systemImage: "text.magnifyingglass")
            }

            Section {
                Toggle("Skip detected API keys", isOn: $skipAPIKeys)
                Text("When enabled, clipboard entries that look like API keys (OpenAI, GitHub, Stripe, AWS, etc.) won't be captured for security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Security", systemImage: "lock.shield")
            }

            Section {
                Toggle("Play sound on capture", isOn: $playSounds)
                Toggle("Show notification on capture", isOn: $showNotifications)
            } header: {
                Label("Feedback", systemImage: "bell")
            }

            Section {
                TextEditor(text: $excludedAppsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("One bundle ID per line (e.g. com.apple.Terminal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Excluded Apps", systemImage: "xmark.app")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Detection Rules Settings Tab

private struct DetectionRulesSettingsTab: View {
    @State private var configuration: DetectorConfiguration = DetectorConfigurationStore.load()
    @State private var saveMessage: String?
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""

    @State private var advancedDetector: BuiltInDetectorKind? = nil
    @State private var advancedEnabledDraft: Bool = false
    @State private var advancedPatternsDraft: String = ""

    @State private var editingCustomDetector: CustomDetectorDefinition? = nil
    @State private var newCustomName: String = ""
    @State private var newCustomPattern: String = ""
    @State private var newCustomCaseInsensitive: Bool = true

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

                        if rule.useAdvancedPatterns, !rule.cleanedPatterns.isEmpty {
                            HStack(spacing: 8) {
                                Text("Advanced regex active")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                performanceBadge(RegexPerformanceEvaluator.evaluate(patterns: rule.cleanedPatterns))
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
                                RegexPerformanceEvaluator.evaluate(
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
                    let result = RegexPerformanceEvaluator.evaluate(
                        pattern: newCustomPattern,
                        options: newCustomCaseInsensitive ? [.caseInsensitive] : []
                    )
                    HStack(spacing: 8) {
                        Text("Pattern performance")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        performanceBadge(result)
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
        .sheet(item: $advancedDetector) { detector in
            builtInAdvancedSheet(for: detector)
        }
        .sheet(item: $editingCustomDetector) { detector in
            customDetectorSheet(detector: detector)
        }
        .onAppear {
            configuration = DetectorConfigurationStore.load()
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
        advancedPatternsDraft = rule.advancedPatterns.joined(separator: "\n")
        advancedDetector = detector
    }

    private func builtInAdvancedSheet(for detector: BuiltInDetectorKind) -> some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use advanced regex", isOn: $advancedEnabledDraft)

                    TextEditor(text: $advancedPatternsDraft)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .disabled(!advancedEnabledDraft)

                    Text("One regex per line. If a capture group exists, group 1 is used as the extracted value.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label(detector.title, systemImage: "slider.horizontal.3")
                }

                if advancedEnabledDraft {
                    let result = RegexPerformanceEvaluator.evaluate(patterns: parsedPatterns(from: advancedPatternsDraft))
                    Section {
                        HStack(spacing: 8) {
                            Text("Performance")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            performanceBadge(result)
                        }
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
            .navigationTitle("Advanced Regex")
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

    private func parsedPatterns(from rawValue: String) -> [String] {
        rawValue
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func addCustomDetector() {
        let name = newCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = newCustomPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !pattern.isEmpty else { return }

        let result = RegexPerformanceEvaluator.evaluate(
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

private struct CustomDetectorEditorSheet: View {
    @State private var name: String
    @State private var pattern: String
    @State private var isEnabled: Bool
    @State private var isCaseInsensitive: Bool
    @State private var confidence: Double

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

                let result = RegexPerformanceEvaluator.evaluate(
                    pattern: pattern,
                    options: isCaseInsensitive ? [.caseInsensitive] : []
                )
                Section {
                    Text("Performance: \(result.rating.displayName)")
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
            .navigationTitle("Edit Custom Detector")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                    let canSave = !trimmedName.isEmpty
                        && !trimmedPattern.isEmpty
                        && RegexPerformanceEvaluator.evaluate(
                            pattern: trimmedPattern,
                            options: isCaseInsensitive ? [.caseInsensitive] : []
                        ).rating != .invalid

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
}

// MARK: - Storage Settings Tab

private struct StorageSettingsTab: View {
    @Binding var retentionDays: Int
    @Binding var maxEntries: Int

    @State private var storageSummary: String = "Calculating..."
    @State private var clearAllSummary: String? = nil
    @State private var isConfirmingClearAll: Bool = false

    var body: some View {
        Form {
            Section {
                Picker("Keep entries for", selection: $retentionDays) {
                    Text("Forever").tag(0)
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }

                Picker("Maximum entries", selection: $maxEntries) {
                    Text("Unlimited").tag(0)
                    Text("500").tag(500)
                    Text("1,000").tag(1000)
                    Text("5,000").tag(5000)
                    Text("10,000").tag(10000)
                    Text("50,000").tag(50000)
                }

                Text("Old entries are cleaned up automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Retention", systemImage: "clock.arrow.circlepath")
            }

            Section {
                LabeledContent("Database") {
                    Text(DatabaseManager.defaultDatabaseURL().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                LabeledContent("Images") {
                    Text(ImageStorageManager.defaultImagesDirectoryURL().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                LabeledContent("Usage") {
                    HStack {
                        Text(storageSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Button {
                            refreshStorageSummary()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Label("Location", systemImage: "folder")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Clear All History…", role: .destructive) {
                        isConfirmingClearAll = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    Spacer()
                }

                if let clearAllSummary {
                    Text(clearAllSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } header: {
                Label("Danger Zone", systemImage: "exclamationmark.triangle")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshStorageSummary()
        }
        .confirmationDialog(
            "Clear all clipboard history?",
            isPresented: $isConfirmingClearAll,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                clearAllHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all entries and stored images.")
        }
    }

    private func refreshStorageSummary() {
        do {
            let dbURL = DatabaseManager.defaultDatabaseURL()
            let dbSize = fileSizeBytes(at: dbURL)
            let imageStorage = try ImageStorageManager()
            let imageBytes = try imageStorage.totalStorageBytes()
            storageSummary = "DB: \(format(bytes: dbSize)) • Images: \(format(bytes: imageBytes))"
        } catch {
            storageSummary = "Unable to calculate"
        }
    }

    private func clearAllHistory() {
        do {
            let database = try DatabaseManager()
            let imageStorage = try ImageStorageManager()
            let deleteService = DeleteService(database: database, imageStorage: imageStorage)
            let count = try deleteService.deleteAll()
            clearAllSummary = "Deleted \(count) entries"
            refreshStorageSummary()
        } catch {
            clearAllSummary = "Failed to clear history"
        }
    }

    private func fileSizeBytes(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - iCloud Settings Tab

private struct iCloudSettingsTab: View {
    @ObservedObject var syncManager: SyncManager
    let allEntries: () -> [ClipboardEntry]
    let markSynced: (([UUID]) -> Void)?
    let syncedCount: () -> Int
    @State private var iCloudAvailable: Bool? = nil
    @State private var isResetting = false
    @State private var displayedSyncedCount: Int = 0

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("iCloud Status")
                    Spacer()
                    statusBadge
                }

                if let lastSync = syncManager.lastSyncDate {
                    LabeledContent("Last Synced") {
                        Text(lastSync, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Synced Entries") {
                    if syncManager.syncState == .syncing && syncManager.totalEntriesToSync > 0 {
                        Text("\(syncManager.syncedEntryCount) / \(syncManager.totalEntriesToSync)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text("\(displayedSyncedCount)")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Status", systemImage: "icloud")
            }

            Section {
                if syncManager.syncState == .syncing && syncManager.totalEntriesToSync > 50 {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Syncing \(syncManager.syncedEntryCount) of \(syncManager.totalEntriesToSync)")
                                .font(.subheadline)
                                .monospacedDigit()
                            Spacer()
                            Button("Cancel") {
                                syncManager.cancelSync()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        ProgressView(
                            value: Double(syncManager.syncedEntryCount),
                            total: Double(max(syncManager.totalEntriesToSync, 1))
                        )
                        .progressViewStyle(.linear)
                        Text("Uploading clipboard history to iCloud. You can cancel and resume later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if syncManager.syncState == .syncing {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Syncing…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text("Sync Now")
                        Spacer()
                        Button("Sync") {
                            let markCallback = markSynced
                            Task {
                                try? await syncManager.setupZone()
                                let entries = allEntries()
                                if !entries.isEmpty {
                                    try? await syncManager.pushEntries(entries, onBatchSynced: markCallback)
                                }
                                _ = try? await syncManager.fetchChanges()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                if case .error(let message) = syncManager.syncState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Pasta syncs clipboard history via iCloud so you can access it on all your devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset Sync…", role: .destructive) {
                        isResetting = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    Spacer()
                }

                Text("Clears the sync token and forces a full re-sync from iCloud.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Danger Zone", systemImage: "exclamationmark.triangle")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            displayedSyncedCount = syncedCount()
        }
        .onChange(of: syncManager.syncState) { _, newState in
            if newState == .idle {
                displayedSyncedCount = syncedCount()
            }
        }
        .task {
            let status = try? await syncManager.checkAccountStatus()
            iCloudAvailable = (status == .available)
        }
        .confirmationDialog(
            "Reset sync data?",
            isPresented: $isResetting,
            titleVisibility: .visible
        ) {
            Button("Reset Sync", role: .destructive) {
                syncManager.resetSync()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the sync token and forces a full re-download from iCloud on next sync.")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch iCloudAvailable {
        case .some(true):
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Connected")
                    .foregroundStyle(.green)
            }
        case .some(false):
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Unavailable")
                    .foregroundStyle(.red)
            }
        case .none:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking…")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Import Settings Tab

private struct ImportSettingsTab: View {
    private enum Defaults {
        static let skipAPIKeys = "pasta.skipAPIKeys"
        static let extractContent = "pasta.extractContent"
    }

    @State private var importResults: [ClipboardApp: ImportResult] = [:]
    @State private var isImporting: ClipboardApp? = nil
    @State private var importProgress: ImportProgress? = nil
    @State private var isExporting: Bool = false
    @State private var isReparsing: Bool = false
    @State private var reparseCurrent: Int = 0
    @State private var reparseTotal: Int = 0
    @State private var showReparseConfirmation: Bool = false
    @State private var reparseSummary: String? = nil
    @State private var exportSummary: String? = nil
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    
    var body: some View {
        Form {
            Section {
                Text("Import clipboard history from other apps. Duplicate entries will be skipped automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Export current history")
                    Spacer()

                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Export My Data…") {
                            exportData()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isImporting != nil || isReparsing)
                    }
                }

                if let exportSummary {
                    Text(exportSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Creates a JSON backup of all clipboard entries, including metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Backup", systemImage: "square.and.arrow.up")
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
                        .disabled(isImporting != nil || isExporting)
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

                Text("Runs current detectors across all saved entries, updates metadata, and rebuilds extracted items to clean up stale detections from older versions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Debug", systemImage: "wrench.and.screwdriver")
            }
            
            Section {
                ForEach(ClipboardApp.allCases) { app in
                    ImportAppRow(
                        app: app,
                        result: importResults[app],
                        isImporting: isImporting == app,
                        isDisabled: isImporting != nil || isExporting || isReparsing,
                        progress: isImporting == app ? importProgress : nil,
                        onImport: { importFrom(app) }
                    )
                }
            } header: {
                Label("Available Sources", systemImage: "tray.and.arrow.down")
            }
        }
        .formStyle(.grouped)
        .alert("Import Error", isPresented: $showError) {
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
    }
    
    private func importFrom(_ app: ClipboardApp) {
        isImporting = app
        importProgress = nil
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let database = try DatabaseManager()
                let imageStorage = try ImageStorageManager()
                let importService = ImportService(database: database, imageStorage: imageStorage)
                let result = try importService.importFrom(app) { progress in
                    DispatchQueue.main.async {
                        self.importProgress = progress
                    }
                }
                
                DispatchQueue.main.async {
                    importResults[app] = result
                    isImporting = nil
                    importProgress = nil
                    
                    // Post notification to refresh main view
                    NotificationCenter.default.post(name: .entriesDidChange, object: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    showError = true
                    isImporting = nil
                    importProgress = nil
                }
            }
        }
    }

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private var reparseProgressFraction: Double {
        guard reparseTotal > 0 else { return 0 }
        return Double(reparseCurrent) / Double(reparseTotal)
    }

    private func exportData() {
        let panel = NSSavePanel()
        panel.title = "Export Pasta Data"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "pasta-export-\(Self.exportDateFormatter.string(from: Date())).json"

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        isExporting = true
        exportSummary = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let database = try DatabaseManager()
                let imageStorage = try ImageStorageManager()
                let importService = ImportService(database: database, imageStorage: imageStorage)
                let result = try importService.exportAllEntries(to: destinationURL)

                DispatchQueue.main.async {
                    exportSummary = "Exported \(result.exported) entries to \(result.fileURL.lastPathComponent)"
                    isExporting = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    showError = true
                    isExporting = false
                }
            }
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
                let entries = try database.fetchPrimaryEntries()

                var updates: [DatabaseManager.ReclassificationUpdate] = []
                updates.reserveCapacity(entries.count)

                var extractedEntries: [ClipboardEntry] = []
                extractedEntries.reserveCapacity(min(entries.count * 2, 20_000))

                DispatchQueue.main.async {
                    reparseTotal = entries.count
                }

                for (index, entry) in entries.enumerated() {
                    if entry.contentType != .image && entry.contentType != .screenshot {
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

                    if index.isMultiple(of: 50) || index + 1 == entries.count {
                        let current = index + 1
                        DispatchQueue.main.async {
                            reparseCurrent = current
                        }
                    }
                }

                let result = try database.applyReclassification(
                    updates: updates,
                    extractedEntries: extractedEntries
                )

                DispatchQueue.main.async {
                    reparseSummary = "Reparsed \(entries.count) entries, updated \(result.updatedEntries), removed \(result.removedExtractedEntries), rebuilt \(result.insertedExtractedEntries) extracted entries."
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
}

private struct ImportAppRow: View {
    let app: ClipboardApp
    let result: ImportResult?
    let isImporting: Bool
    let isDisabled: Bool
    let progress: ImportProgress?
    let onImport: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: app.iconName)
                    .font(.title2)
                    .foregroundStyle(app.isAvailable ? .primary : .tertiary)
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.rawValue)
                        .font(.headline)
                        .foregroundStyle(app.isAvailable ? .primary : .secondary)
                    
                    Text(app.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    if let result, !isImporting {
                        Text(result.summary)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                
                Spacer()
                
                if isImporting {
                    if progress == nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else if app.isAvailable {
                    Button("Import") {
                        onImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isDisabled)
                } else {
                    Text("Not installed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            
            // Progress bar section
            if isImporting, let progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction) {
                        HStack {
                            Text("Processing \(progress.current) of \(progress.total)")
                            Spacer()
                            Text("\(Int(progress.fraction * 100))%")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .progressViewStyle(.linear)
                    
                    HStack(spacing: 12) {
                        Label("\(progress.imported)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Label("\(progress.skipped)", systemImage: "arrow.right.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
                .padding(.leading, 40)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - About Settings Tab

private struct AboutSettingsTab: View {
    let checkForUpdates: (() -> Void)?
    let automaticallyChecksForUpdates: Binding<Bool>?
    
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }
    
    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }
    
    private var commitRef: String? {
        Bundle.main.object(forInfoDictionaryKey: "GitCommitSHA") as? String
    }
    
    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    if let appIcon = NSImage(named: "AppIcon") {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        Image(systemName: "doc.on.clipboard.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(PastaTheme.accent)
                            .frame(width: 64, height: 64)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pasta")
                            .font(.title2.bold())
                        Text("Clipboard history for macOS")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Built by Chris Mitchelmore")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
            
            Section {
                LabeledContent("Version") {
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Build") {
                    Text(buildNumber)
                        .foregroundStyle(.secondary)
                }
                if let commit = commitRef, !commit.isEmpty {
                    LabeledContent("Commit") {
                        Text(String(commit.prefix(7)))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Version Info", systemImage: "tag")
            }
            
            Section {
                if let checkForUpdates {
                    HStack {
                        Text("Check for Updates")
                        Spacer()
                        Button("Check Now") {
                            checkForUpdates()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                
                if let binding = automaticallyChecksForUpdates {
                    Toggle("Check automatically", isOn: binding)
                }
            } header: {
                Label("Updates", systemImage: "arrow.triangle.2.circlepath")
            }
            
            Section {
                Text("Have a bug to report or feature to request?")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                
                HStack(spacing: 12) {
                    Link(destination: URL(string: "https://github.com/crmitchelmore/pasta/issues")!) {
                        Label("Report Issue", systemImage: "ladybug")
                    }
                    .buttonStyle(.bordered)
                    
                    Link(destination: URL(string: "https://github.com/crmitchelmore/pasta/issues/new")!) {
                        Label("Request Feature", systemImage: "lightbulb")
                    }
                    .buttonStyle(.bordered)
                    
                    Link(destination: URL(string: "https://github.com/crmitchelmore/pasta")!) {
                        Label("GitHub", systemImage: "link")
                    }
                    .buttonStyle(.bordered)
                }
            } header: {
                Label("Feedback & Support", systemImage: "bubble.left.and.bubble.right")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Built with:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    
                    DependencyRow(name: "Sparkle", version: "2.6.0+", url: "https://sparkle-project.org", description: "Auto-update framework")
                    DependencyRow(name: "GRDB", version: "6.24+", url: "https://github.com/groue/GRDB.swift", description: "SQLite toolkit")
                }
            } header: {
                Label("Dependencies", systemImage: "shippingbox")
            }
            
            Section {
                Text("© 2024-2026 Chris Mitchelmore. All rights reserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Link(destination: URL(string: "https://github.com/crmitchelmore/pasta/blob/main/LICENSE")!) {
                    Label("View License (MIT)", systemImage: "doc.plaintext")
                }
                .buttonStyle(.bordered)
            } header: {
                Label("Legal", systemImage: "doc.text")
            }
        }
        .formStyle(.grouped)
    }
}

private struct DependencyRow: View {
    let name: String
    let version: String
    let url: String
    let description: String
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.callout.bold())
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(version)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1), in: Capsule())
            Link(destination: URL(string: url)!) {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
    }
}

// MARK: - Notification Name Extension

extension Notification.Name {
    static let entriesDidChange = Notification.Name("pasta.entriesDidChange")
}
