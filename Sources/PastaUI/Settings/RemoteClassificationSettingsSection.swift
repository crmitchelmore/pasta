import PastaCore
import SwiftUI

struct RemoteClassificationSettingsSection: View {
    let provider: RemoteClassificationProvider
    let showHistoryActions: Bool
    private let readAPIKey: () throws -> String?
    @State private var configuration: JevConfiguration
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var isValidated = false
    @State private var isTesting = false
    @State private var message: String?
    @State private var testSucceeded = false
    @State private var validationTask: Task<Void, Never>?
    @State private var validationID: UUID?
    @State private var showAdvanced = false

    init(provider: RemoteClassificationProvider, showHistoryActions: Bool = true, readAPIKey: (() throws -> String?)? = nil) {
        self.provider = provider
        self.showHistoryActions = showHistoryActions
        self.readAPIKey = readAPIKey ?? { try JevKeychain.read(provider: provider) }
        _configuration = State(initialValue: .load(provider: provider))
    }

    var body: some View {
        Section {
            if provider == .microsoftDecision { connectionFields }
            credentialFields
            Toggle("Allow eligible clipboard text to be sent to \(provider.title)", isOn: Binding(
                get: { configuration.isEnabled },
                set: {
                    configuration.isEnabled = $0 && isValidated
                    configuration.save()
                }
            ))
            .disabled(!isValidated && !configuration.isEnabled)

            if showHistoryActions || configuration.isEnabled {
                Picker("New clipboard entries", selection: $configuration.mode) {
                    ForEach(JevClassificationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: configuration.mode) { _, _ in configuration.save() }
                .disabled(!configuration.isEnabled)
                if configuration.mode == .fallback {
                    HStack {
                        Text("Legacy confidence below \(Int((configuration.fallbackThreshold * 100).rounded()))%")
                        Slider(value: $configuration.fallbackThreshold, in: 0...1, step: 0.01)
                            .accessibilityLabel("Low confidence threshold")
                            .accessibilityValue("\(Int((configuration.fallbackThreshold * 100).rounded())) percent")
                    }
                    .onChange(of: configuration.fallbackThreshold) { _, _ in configuration.save() }
                    Text("Legacy confidence is a detector score, not a calibrated probability. Exactly the threshold keeps the local result.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if provider == .microsoftDecision {
                Link("Set up Microsoft Decision-1 in Foundry", destination: URL(string: "https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/use-foundry-models-microsoft-decision")!)
                Text("Use the full resource endpoint followed by /providers/microsoft/v1/systemone and your deployment name. Requires key authentication; Microsoft Entra sign-in is not supported.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Link("Get a Jev API key", destination: URL(string: "https://console.typesafe.ai/keys")!)
                DisclosureGroup("Advanced connection", isExpanded: $showAdvanced) {
                    connectionFields
                }
            }
            Toggle("Include sensitive entries (API keys, tokens, env vars, cards, IBANs)", isOn: $configuration.includeSensitiveContent)
                .onChange(of: configuration.includeSensitiveContent) { _, _ in configuration.save() }

            Text("Compare-only mode sends history after confirmation. Default and fallback modes send eligible new clipboard text to \(configuration.endpointHost ?? "the configured endpoint") only when this is the preferred model. Clips are saved locally first; errors and Unknown keep the legacy result. Images and file pastes are never sent.")
                .font(.caption).foregroundStyle(.secondary)
            if showHistoryActions {
                HStack {
                    Button("Compare Classifiers…") {
                        NotificationCenter.default.post(name: .compareRemoteClassifiers, object: nil)
                    }
                    Button("Reclassify History with \(provider.title)…") {
                        NotificationCenter.default.post(name: .reclassifyHistoryWithDecisionModel, object: provider.rawValue)
                    }
                }
                .disabled(!configuration.isEnabled || !isValidated)
            }
            Text("Text is truncated to \(JevSystemOneRequest.maxContentCharacters) characters. Sensitive entries are excluded unless opted in separately for this provider. Keys are stored only in Keychain. Test before enabling; changing the key, endpoint, model or shared classifiers disables the provider.")
                .font(.caption).foregroundStyle(.secondary)
            if let message {
                Label(message, systemImage: testSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(testSucceeded ? Color.green : Color.red)
                    .textSelection(.enabled)
            }
        } header: {
            Label(provider.title, systemImage: "sparkles")
        }
        .onAppear {
            reloadConfiguration()
        }
        .onReceive(NotificationCenter.default.publisher(for: .decisionClassifierRulesChanged)) { _ in
            invalidateValidation()
            reloadConfiguration()
        }
        .onDisappear {
            validationTask?.cancel()
            validationID = nil
            isTesting = false
            apiKey = ""
        }
    }

    private var credentialFields: some View {
        Group {
            SecureField(hasKey ? "Replace API key" : "API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save and Test Key") {
                    do {
                        try JevKeychain.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider)
                        apiKey = ""
                        hasKey = true
                        testConnection()
                    } catch { showFailure(error) }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting || configuration.endpointURL == nil)
                Button("Test Connection") { testConnection() }
                    .disabled(!hasKey || isTesting || configuration.endpointURL == nil)
                if showHistoryActions {
                    Button("Remove Key", role: .destructive) {
                        do {
                            try JevKeychain.remove(provider: provider)
                            invalidateValidation()
                            hasKey = false
                            testSucceeded = true
                            message = "API key removed; \(provider.title) disabled."
                        } catch { showFailure(error) }
                    }
                    .disabled(!hasKey)
                }
                if isTesting { ProgressView().controlSize(.small) }
            }
        }
    }

    private var connectionFields: some View {
        Group {
            TextField("Full HTTPS endpoint", text: Binding(
                get: { configuration.endpoint },
                set: {
                    invalidateValidation()
                    configuration.endpoint = $0
                    configuration.save()
                }
            ))
            TextField(provider == .jev ? "Model" : "Deployment name", text: Binding(
                get: { configuration.model },
                set: {
                    invalidateValidation()
                    configuration.model = $0
                    configuration.save()
                }
            ))
            if configuration.endpoint != provider.defaultEndpoint || configuration.model != provider.defaultModel {
                Button("Reset Endpoint and Model") {
                    invalidateValidation()
                    configuration.endpoint = provider.defaultEndpoint
                    configuration.model = provider.defaultModel
                    configuration.save()
                }
            }
        }
    }

    private func reloadConfiguration() {
        configuration = .load(provider: provider)
        if !configuration.isEnabled,
           UserDefaults.standard.object(forKey: "\(provider == .jev ? "pasta.jev" : "pasta.microsoftDecision").mode") == nil {
            configuration.mode = .primary
        }
        do {
            let key = try readAPIKey() ?? ""
            hasKey = !key.isEmpty
            isValidated = configuration.isValidated(apiKey: key)
            if !isValidated { configuration.isEnabled = false }
        } catch {
            isValidated = false
            configuration.isEnabled = false
            showFailure(error)
        }
    }

    private func testConnection() {
        invalidateValidation()
        let snapshot = configuration
        let id = UUID()
        validationID = id
        isTesting = true
        validationTask = Task { @MainActor in
            defer { if validationID == id { isTesting = false } }
            do {
                guard let key = try readAPIKey(), !key.isEmpty else {
                    throw JevConfigurationError.missingAPIKey
                }
                let result = try await JevClassifier().validate(configuration: snapshot, apiKey: key)
                guard !Task.isCancelled, validationID == id,
                      JevConfiguration.load(provider: provider).endpoint == snapshot.endpoint,
                      JevConfiguration.load(provider: provider).effectiveModel == snapshot.effectiveModel,
                      JevConfiguration.load(provider: provider).rules == snapshot.rules,
                      try readAPIKey() == key else { return }
                snapshot.recordSuccessfulValidation(apiKey: key)
                isValidated = true
                testSucceeded = true
                message = "Connected to \(result.modelVersion ?? snapshot.effectiveModel): \(result.rawChoice) in \(Int((result.latency * 1000).rounded())) ms."
            } catch {
                guard !Task.isCancelled, validationID == id else { return }
                showFailure(error)
            }
        }
    }

    private func invalidateValidation() {
        validationTask?.cancel()
        validationID = nil
        isTesting = false
        isValidated = false
        message = nil
        JevConfiguration.invalidateValidation(provider: provider)
        configuration.isEnabled = false
        configuration.save()
    }

    private func showFailure(_ error: Error) {
        testSucceeded = false
        message = "\(provider.title): \(error.localizedDescription)"
    }
}

public extension Notification.Name {
    static let compareRemoteClassifiers = Notification.Name("pasta.compareRemoteClassifiers")
    static let reclassifyHistoryWithJev = Notification.Name("pasta.reclassifyHistoryWithJev")
    static let reclassifyHistoryWithDecisionModel = Notification.Name("pasta.reclassifyHistoryWithDecisionModel")
    static let decisionClassifierRulesChanged = Notification.Name("pasta.decisionClassifierRulesChanged")
}
