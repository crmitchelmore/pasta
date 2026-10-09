import PastaCore
import SwiftUI

struct RemoteClassificationSettingsSection: View {
    let provider: RemoteClassificationProvider
    @State private var configuration: JevConfiguration
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var isValidated = false
    @State private var isTesting = false
    @State private var message: String?
    @State private var testSucceeded = false
    @State private var validationTask: Task<Void, Never>?
    @State private var validationID: UUID?

    init(provider: RemoteClassificationProvider) {
        self.provider = provider
        _configuration = State(initialValue: .load(provider: provider))
    }

    var body: some View {
        Section {
            Toggle(provider == .jev ? "Enable Jev" : "Include Microsoft Decision-1 in comparisons", isOn: Binding(
                get: { configuration.isEnabled },
                set: {
                    configuration.isEnabled = $0 && isValidated
                    configuration.save()
                }
            ))
            .disabled(!isValidated && !configuration.isEnabled)

            if provider == .jev {
                Picker("New clipboard entries", selection: $configuration.mode) {
                    ForEach(JevClassificationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: configuration.mode) { _, _ in configuration.save() }
                .disabled(!configuration.isEnabled)
                if configuration.mode == .fallback {
                    HStack {
                        Text("Local confidence below \(Int((configuration.fallbackThreshold * 100).rounded()))%")
                        Slider(value: $configuration.fallbackThreshold, in: 0...1, step: 0.01)
                            .accessibilityLabel("Low confidence threshold")
                            .accessibilityValue("\(Int((configuration.fallbackThreshold * 100).rounded())) percent")
                    }
                    .onChange(of: configuration.fallbackThreshold) { _, _ in configuration.save() }
                    Text("Local confidence is a detector score, not a calibrated probability. Exactly the threshold keeps the local result.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            SecureField(hasKey ? "Replace API key" : "API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save API Key") {
                    do {
                        try JevKeychain.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider)
                        apiKey = ""
                        hasKey = true
                        testConnection()
                    } catch { showFailure(error) }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Test Connection") { testConnection() }
                    .disabled(!hasKey || isTesting || configuration.endpointURL == nil)
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
                if isTesting { ProgressView().controlSize(.small) }
            }

            TextField("Full HTTPS endpoint", text: Binding(
                get: { configuration.endpoint },
                set: {
                    invalidateValidation()
                    configuration.endpoint = $0
                    configuration.save()
                }
            ))
            TextField("Model", text: Binding(
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
            Toggle("Include sensitive entries (API keys, tokens, env vars, cards, IBANs)", isOn: $configuration.includeSensitiveContent)
                .onChange(of: configuration.includeSensitiveContent) { _, _ in configuration.save() }

            if provider == .jev {
                Text("Compare only sends history only after you confirm a comparison. Default and fallback modes send eligible new clipboard text to \(configuration.endpointHost ?? "the configured endpoint"): they save locally first, then update the classification. Errors and Unknown keep the local result. Images and file pastes are never sent.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Compare Classifiers…") {
                        NotificationCenter.default.post(name: .compareRemoteClassifiers, object: nil)
                    }
                    Button("Reclassify History with Jev…") {
                        NotificationCenter.default.post(name: .reclassifyHistoryWithJev, object: nil)
                    }
                }
                .disabled(!configuration.isEnabled || !isValidated)
            } else {
                Text("Comparison only: clipboard text is sent to your deployment only after confirming a history comparison. Configure its full System One-compatible HTTPS endpoint and a separate key. No endpoint is guessed, and your TypeSafe key is never reused. The served model must identify itself as Microsoft-Decision-1.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Microsoft Decision-1 in Foundry", destination: URL(string: "https://ai.azure.com/catalog/models/Microsoft-Decision-1")!)
                Button("Compare Classifiers…") {
                    NotificationCenter.default.post(name: .compareRemoteClassifiers, object: nil)
                }
                .disabled(!configuration.isEnabled || !isValidated)
            }
            Text("Text is truncated to \(JevSystemOneRequest.maxContentCharacters) characters. Sensitive entries are excluded unless opted in separately for this provider. Keys are stored only in Keychain. Test the connection before enabling; changing the key, endpoint or model disables it.")
                .font(.caption).foregroundStyle(.secondary)
            if let message {
                Label(message, systemImage: testSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(testSucceeded ? Color.green : Color.red)
                    .textSelection(.enabled)
            }
        } header: {
            Label(provider == .jev ? "Jev Classification" : "Microsoft Decision-1 Comparison", systemImage: "sparkles")
        }
        .onAppear {
            configuration = .load(provider: provider)
            do {
                let key = try JevKeychain.read(provider: provider) ?? ""
                hasKey = !key.isEmpty
                isValidated = configuration.isValidated(apiKey: key)
                if !isValidated {
                    configuration.isEnabled = false
                    configuration.save()
                }
            } catch { showFailure(error) }
        }
        .onDisappear {
            validationTask?.cancel()
            validationID = nil
            isTesting = false
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
                guard let key = try JevKeychain.read(provider: provider), !key.isEmpty else {
                    throw JevConfigurationError.missingAPIKey
                }
                let result = try await JevClassifier().validate(configuration: snapshot, apiKey: key)
                guard !Task.isCancelled, validationID == id,
                      JevConfiguration.load(provider: provider).endpoint == snapshot.endpoint,
                      JevConfiguration.load(provider: provider).effectiveModel == snapshot.effectiveModel,
                      try JevKeychain.read(provider: provider) == key else { return }
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
}
