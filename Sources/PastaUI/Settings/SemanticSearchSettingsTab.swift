import PastaCore
import SwiftUI

/// Settings → Search: opt-in semantic ("search by meaning") search backed by
/// an embeddings provider.
struct SemanticSearchSettingsTab: View {
    let service: SemanticSearchService?

    @State private var configuration = SemanticSearchConfiguration.load()
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var isValidated = false
    @State private var isTesting = false
    @State private var message: String?
    @State private var testSucceeded = false
    @State private var validationTask: Task<Void, Never>?
    @State private var status = SemanticSearchService.Status()
    @State private var isConfirmingRebuild = false
    @State private var hasDetectionOpenAIKey = false

    var body: some View {
        Form {
            overviewSection
            providerSection
            indexSection
            privacySection
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadConfiguration)
        .onDisappear {
            validationTask?.cancel()
            validationTask = nil
            isTesting = false
            apiKey = ""
        }
        .task { await pollStatus() }
        .confirmationDialog("Rebuild the semantic index?", isPresented: $isConfirmingRebuild, titleVisibility: .visible) {
            Button("Rebuild Index") {
                guard let service else { return }
                Task { await service.rebuildIndex() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every eligible clip is sent to \(configuration.endpointURL?.host ?? "the provider") again. This may take a while and incurs provider usage.")
        }
    }

    // MARK: Sections

    private var overviewSection: some View {
        Section {
            Text("Find clips by what they are, not only by the words they contain. Try “apple watch serial number”, “wifi password” or “tracking number” when you can't remember any of the text.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Search by meaning", isOn: Binding(
                get: { configuration.isEnabled && isValidated },
                set: { newValue in
                    configuration.isEnabled = newValue && isValidated
                    persist()
                }
            ))
            .disabled(!isValidated)
            if !isValidated {
                Text("Save and test a provider below to turn this on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Label("Semantic Search", systemImage: "sparkle.magnifyingglass")
        }
    }

    private var providerSection: some View {
        Section("Embeddings Provider") {
            Picker("Provider", selection: Binding(
                get: { configuration.provider },
                set: { switchProvider(to: $0) }
            )) {
                ForEach(EmbeddingProviderKind.allCases) { Text($0.displayName).tag($0) }
            }

            TextField("Endpoint", text: Binding(
                get: { configuration.endpoint },
                set: { configuration.endpoint = $0; configurationEdited() }
            ))
            TextField(configuration.provider == .azureOpenAI ? "Deployment name" : "Model", text: Binding(
                get: { configuration.model },
                set: { configuration.model = $0; configurationEdited() }
            ))
            if configuration.endpoint != configuration.provider.defaultEndpoint || configuration.model != configuration.provider.defaultModel {
                Button("Reset Endpoint and Model") {
                    configuration.endpoint = configuration.provider.defaultEndpoint
                    configuration.model = configuration.provider.defaultModel
                    configurationEdited()
                }
            }
            providerHelp

            SecureField(keyPlaceholder, text: $apiKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save and Test") { saveAndTest() }
                    .disabled(isTesting || configuration.endpointURL == nil || (configuration.provider.requiresAPIKey && !hasKey && trimmedKey.isEmpty))
                if configuration.provider == .openAI, hasDetectionOpenAIKey, !hasKey {
                    Button("Use OpenAI Key from Detection") { useDetectionOpenAIKey() }
                        .disabled(isTesting)
                }
                if hasKey {
                    Button("Remove Key", role: .destructive) { removeKey() }
                        .disabled(isTesting)
                }
                if isTesting { ProgressView().controlSize(.small) }
            }
            if configuration.endpointURL == nil {
                Label(SemanticSearchError.invalidEndpoint.errorDescription ?? "Invalid endpoint", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let message {
                Label(message, systemImage: testSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(testSucceeded ? Color.green : Color.red)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var providerHelp: some View {
        switch configuration.provider {
        case .openAI:
            Link("Get an OpenAI API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
            Text("text-embedding-3-small is fast and inexpensive; indexing 10,000 clips typically costs a few cents.")
                .font(.caption).foregroundStyle(.secondary)
        case .azureOpenAI:
            Link("Deploy an embeddings model in Azure AI Foundry", destination: URL(string: "https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/embeddings")!)
            Text("Use your resource's v1 endpoint (https://<resource>.openai.azure.com/openai/v1/embeddings) and the deployment name of an embeddings model such as text-embedding-3-small. Uses key authentication.")
                .font(.caption).foregroundStyle(.secondary)
        case .openAICompatible:
            Text("Any server with an OpenAI-style /v1/embeddings endpoint. With Ollama: run `ollama pull nomic-embed-text`. A localhost endpoint keeps everything on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var indexSection: some View {
        Section("Index") {
            HStack(spacing: 8) {
                if status.isIndexing { ProgressView().controlSize(.small) }
                Text(statusSummary)
            }
            if status.isActive, status.counts.skipped > 0 {
                Text("\(status.counts.skipped.formatted()) clips are left out of the index (images, private or sensitive clips).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = status.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .textSelection(.enabled)
                if let retryAt = status.retryAt {
                    Text("Retrying \(retryAt.formatted(.relative(presentation: .named))).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Rebuild Index…") { isConfirmingRebuild = true }
                .disabled(!status.isActive || service == nil)
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            Text("Semantic search is off until you enable it. When it is on, the start of each clip's text (up to 2,000 characters), its type and the app it came from are sent to \(configuration.endpointURL?.host ?? "the provider") once, and only the resulting vectors are stored on this Mac. Queries you type are sent too.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Images, file paths, clips received over Tailnet and sensitive clips (API keys, tokens, passwords, cards, IBANs) are never sent to a remote provider. A localhost endpoint indexes everything, because nothing leaves this Mac. Keys are stored only in Keychain.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Derived state

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var keyPlaceholder: String {
        if hasKey { return "Replace API key" }
        return configuration.provider.requiresAPIKey ? "API key" : "API key (optional)"
    }

    private var statusSummary: String {
        guard service != nil else { return "Unavailable" }
        guard status.isActive else { return "Off" }
        let counts = status.counts
        let eligible = max(counts.total - counts.skipped, 0)
        if counts.pending > 0 {
            return "Indexing… \(counts.indexed.formatted()) of \(eligible.formatted()) clips ready"
        }
        return "\(counts.indexed.formatted()) clips searchable by meaning"
    }

    // MARK: Actions

    private func reloadConfiguration() {
        configuration = .load()
        refreshKeyState()
        hasDetectionOpenAIKey = ((try? JevKeychain.read(provider: .openAI)) ?? nil)?.isEmpty == false
    }

    private func refreshKeyState() {
        do {
            let key = try SemanticSearchKeychain.read(provider: configuration.provider) ?? ""
            hasKey = !key.isEmpty
            isValidated = configuration.isValidated(apiKey: key)
        } catch {
            hasKey = false
            isValidated = false
            show(error)
        }
        if !isValidated { configuration.isEnabled = false }
    }

    private func switchProvider(to provider: EmbeddingProviderKind) {
        guard provider != configuration.provider else { return }
        validationTask?.cancel()
        isTesting = false
        apiKey = ""
        message = nil
        configuration = .load(provider: provider)
        SemanticSearchConfiguration.invalidateValidation()
        persist()
        refreshKeyState()
    }

    private func configurationEdited() {
        validationTask?.cancel()
        isTesting = false
        isValidated = false
        configuration.isEnabled = false
        SemanticSearchConfiguration.invalidateValidation()
        persist()
    }

    private func persist() {
        configuration.save()
        NotificationCenter.default.post(name: .semanticSearchConfigurationDidChange, object: nil)
    }

    private func saveAndTest() {
        if !trimmedKey.isEmpty {
            do {
                try SemanticSearchKeychain.save(trimmedKey, provider: configuration.provider)
                apiKey = ""
                hasKey = true
            } catch {
                show(error)
                return
            }
        }
        testConnection()
    }

    private func useDetectionOpenAIKey() {
        do {
            guard let key = try JevKeychain.read(provider: .openAI), !key.isEmpty else { return }
            try SemanticSearchKeychain.save(key, provider: .openAI)
            hasKey = true
            testConnection()
        } catch {
            show(error)
        }
    }

    private func removeKey() {
        do {
            try SemanticSearchKeychain.remove(provider: configuration.provider)
            hasKey = false
            configurationEdited()
            testSucceeded = true
            message = "API key removed; semantic search turned off."
        } catch {
            show(error)
        }
    }

    private func testConnection() {
        configurationEdited()
        let snapshot = configuration
        let key: String?
        do {
            key = try SemanticSearchKeychain.read(provider: snapshot.provider)
        } catch {
            show(error)
            return
        }
        isTesting = true
        message = nil
        validationTask = Task { @MainActor in
            do {
                let dimensions = try await SemanticSearchService.testConnection(configuration: snapshot, apiKey: key)
                guard !Task.isCancelled, configuration == snapshot else { return }
                snapshot.recordSuccessfulValidation(apiKey: key)
                isValidated = true
                configuration.isEnabled = true
                persist()
                testSucceeded = true
                message = "Connected: \(snapshot.effectiveModel) returns \(dimensions)-dimension vectors. Semantic search is on."
            } catch {
                guard !Task.isCancelled else { return }
                show(error)
            }
            isTesting = false
        }
    }

    private func show(_ error: Error) {
        testSucceeded = false
        message = error.localizedDescription
    }

    private func pollStatus() async {
        guard let service else { return }
        while !Task.isCancelled {
            status = await service.currentStatus()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
