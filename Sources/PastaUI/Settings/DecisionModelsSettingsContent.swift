import PastaCore
import SwiftUI

struct DecisionModelsSettingsContent: View {
    let isOnboarding: Bool
    private let readAPIKey: (() throws -> String?)?
    @State private var provider: RemoteClassificationProvider

    init(isOnboarding: Bool = false, provider: RemoteClassificationProvider = DecisionModelSelection.provider(),
         readAPIKey: (() throws -> String?)? = nil) {
        self.isOnboarding = isOnboarding
        self.readAPIKey = readAPIKey
        _provider = State(initialValue: provider)
    }

    var body: some View {
        Section {
            if !isOnboarding {
                Text("Decision models are recommended for better classification: Jev and Microsoft Decision-1 use the context of a whole clip rather than just legacy pattern matching. Compare them on your history to judge your results.")
                    .font(.callout)
            }
            Picker("Preferred decision model", selection: $provider) {
                ForEach(RemoteClassificationProvider.allCases, id: \.self) {
                    Text($0.title).tag($0)
                }
            }
            .onChange(of: provider) { _, selected in DecisionModelSelection.select(selected) }
            Text(isOnboarding
                 ? "Test your key, then explicitly allow sending text to this model. A key is optional; provider usage may incur charges."
                 : "Only the preferred model handles new clips, and only after you test its key and explicitly allow sending text. Without an enabled model, Pasta stays local. Provider usage may incur charges.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Decision models")
        }

        RemoteClassificationSettingsSection(provider: provider, showHistoryActions: !isOnboarding, readAPIKey: readAPIKey)
            .id(provider)

        if !isOnboarding {
            DecisionClassifierSettingsSection()
            Section {
                DisclosureGroup("Other classification APIs") {
                    Link("Hugging Face zero-shot classification", destination: URL(string: "https://huggingface.co/docs/inference-providers/tasks/zero-shot-classification")!)
                    Text("Supports user-defined labels, but uses a different inference schema and model-specific availability. Not integrated in this Alpha.")
                    Link("Cohere Classify", destination: URL(string: "https://docs.cohere.com/v2/reference/classify")!)
                    Text("Requires labeled examples (at least two per label) or a fine-tuned classifier. Not a drop-in decision model; not integrated.")
                }
                .font(.caption)
            }
        }
    }
}

public struct DecisionModelSetupView: View {
    public init() {}

    public var body: some View {
        Form {
            DecisionModelsSettingsContent(isOnboarding: true)
        }
        .formStyle(.grouped)
    }
}

struct DecisionClassifierSettingsSection: View {
    @State private var rules = DecisionClassificationRules.load()
    @State private var expanded = false
    @State private var editing: DecisionClassifierDefinition?
    @State private var errorMessage: String?
    @State private var message: String?

    var body: some View {
        Section {
            DisclosureGroup("Shared classifier types", isExpanded: $expanded) {
                Text("Both decision models use these descriptions and custom labels. Describe when a label should win; no regex is needed. Custom labels map to existing types for compatible previews, filters and sync.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Saving a change disables both providers. Test and enable each again before sending clips with the new rules.")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(rules.customClassifiers) { classifier in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(classifier.name).fontWeight(.medium)
                            Text("Maps to \(classifier.contentType.displayTitle)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editing = classifier }
                        Button("Remove", role: .destructive) {
                            var updated = rules
                            updated.customClassifiers.removeAll { $0.id == classifier.id }
                            save(updated)
                        }
                    }
                }
                Button("Add Classifier Type…") {
                    editing = DecisionClassifierDefinition(name: "", description: "")
                }
                .disabled(rules.customClassifiers.count >= DecisionClassificationRules.maxCustomClassifiers)

                DisclosureGroup("Built-in type descriptions") {
                    ForEach(JevSystemOneRequest.options, id: \.category) { option in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.category.displayTitle).font(.callout.weight(.medium))
                            TextField("When to choose this type", text: Binding(
                                get: { rules.descriptions[option.category.rawValue] ?? option.description },
                                set: { rules.descriptions[option.category.rawValue] = $0 }
                            ), axis: .vertical)
                            .lineLimit(2...5)
                        }
                    }
                    Button("Save Type Descriptions") { save(rules) }
                    Button("Restore Built-in Descriptions") {
                        var updated = rules
                        updated.descriptions = [:]
                        save(updated)
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Shared configuration")
        }
        .sheet(item: $editing) { classifier in
            DecisionClassifierEditor(classifier: classifier) { edited in
                var updated = rules
                if let index = updated.customClassifiers.firstIndex(where: { $0.id == edited.id }) {
                    updated.customClassifiers[index] = edited
                } else {
                    updated.customClassifiers.append(edited)
                }
                if save(updated) {
                    editing = nil
                    return nil
                }
                let failure = errorMessage
                errorMessage = nil
                return failure
            }
        }
        .alert("Could not save classifier rules", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @discardableResult
    private func save(_ updated: DecisionClassificationRules) -> Bool {
        do {
            let validated = try updated.validated()
            let changed = validated != DecisionClassificationRules.load()
            try validated.save()
            rules = validated
            message = "Saved. Test and enable your providers again if the rules changed."
            if changed { NotificationCenter.default.post(name: .decisionClassifierRulesChanged, object: nil) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

private struct DecisionClassifierEditor: View {
    @State var classifier: DecisionClassifierDefinition
    let onSave: (DecisionClassifierDefinition) -> String?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom classifier type").font(.headline)
            Form {
                TextField("Name (e.g. Customer ID)", text: $classifier.name)
                TextField("When to choose this type", text: $classifier.description, axis: .vertical)
                    .lineLimit(3...6)
                Picker("Pasta type", selection: $classifier.contentType) {
                    ForEach(JevSystemOneRequest.options.filter { $0.category != .unknown }, id: \.category) {
                        Text($0.category.displayTitle).tag($0.category)
                    }
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
                Text("The custom name appears in the preview and comparison. The mapped type controls existing filters and previews.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Classifier") { errorMessage = onSave(classifier) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(classifier.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              classifier.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
