import AppKit
import PastaCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings tab for managing user snippets (CRUD + import/export + preview).
struct SnippetsSettingsTab: View {
    @StateObject private var model = SnippetsSettingsModel()

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 220)

            editor
                .frame(minWidth: 360)
        }
        .onAppear { model.load() }
        .alert("Snippets Error", isPresented: $model.showError, presenting: model.errorMessage) { _ in
            Button("OK") { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Snippets")
                    .font(.headline)
                Spacer()
                Button {
                    model.createNew()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Snippet")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            List(selection: $model.selectedID) {
                ForEach(model.snippets) { snippet in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(snippet.name.isEmpty ? "(untitled)" : snippet.name)
                                .font(.body.weight(.medium))
                            if let keyword = snippet.keyword, !keyword.isEmpty {
                                Text(keyword)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(snippet.previewLine())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(snippet.id)
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 8) {
                Button("Import…") {
                    model.importJSON()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Export…") {
                    model.exportJSON()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.snippets.isEmpty)

                Spacer()

                if let summary = model.lastImportExportSummary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let id = model.selectedID, let index = model.snippets.firstIndex(where: { $0.id == id }) {
            SnippetEditorView(
                draft: $model.snippets[index],
                preview: model.previewText(for: model.snippets[index]),
                onSave: { model.save(at: index) },
                onDelete: { model.delete(id: id) }
            )
            .padding(16)
        } else {
            VStack {
                Spacer()
                Text("Select or create a snippet to edit.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SnippetEditorView: View {
    @Binding var draft: Snippet
    let preview: String
    let onSave: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                TextField("Keyword (optional)", text: Binding(
                    get: { draft.keyword ?? "" },
                    set: { draft.keyword = $0.isEmpty ? nil : $0 }
                ))
            }

            Section("Content") {
                TextEditor(text: $draft.content)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("Placeholders: {date} {time} {datetime} {clipboard} {clipboard:N} {uuid} {cursor}. Add a format like {date:yyyy-MM-dd}.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Test placeholders") {
                ScrollView {
                    Text(preview.isEmpty ? "(empty)" : preview)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 80, maxHeight: 140)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("Live preview using current clipboard and the moment now.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                Button {
                    onSave()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: [.command])
            }
        }
        .onChange(of: draft) { _, _ in
            // Persist on every edit. Simpler than a "dirty" indicator and
            // matches what users expect from settings.
            onSave()
        }
    }
}

@MainActor
final class SnippetsSettingsModel: ObservableObject {
    @Published var snippets: [Snippet] = []
    @Published var selectedID: UUID? = nil
    @Published var errorMessage: String? = nil
    @Published var showError: Bool = false
    @Published var lastImportExportSummary: String? = nil

    private var store: SnippetStore? {
        do {
            let database = try DatabaseManager()
            return SnippetStore(database: database)
        } catch {
            report(error: error)
            return nil
        }
    }

    func load() {
        guard let store else { return }
        do {
            snippets = try store.list()
            if selectedID == nil {
                selectedID = snippets.first?.id
            }
        } catch {
            report(error: error)
        }
    }

    func createNew() {
        guard let store else { return }
        let snippet = Snippet(name: "Untitled", content: "", keyword: nil)
        do {
            _ = try store.create(snippet)
            snippets.insert(snippet, at: 0)
            selectedID = snippet.id
        } catch {
            report(error: error)
        }
    }

    func save(at index: Int) {
        guard let store, snippets.indices.contains(index) else { return }
        do {
            let saved = try store.update(snippets[index])
            snippets[index] = saved
        } catch {
            report(error: error)
        }
    }

    func delete(id: UUID) {
        guard let store else { return }
        do {
            _ = try store.delete(id: id)
            snippets.removeAll { $0.id == id }
            if selectedID == id {
                selectedID = snippets.first?.id
            }
        } catch {
            report(error: error)
        }
    }

    func previewText(for snippet: Snippet) -> String {
        let evaluator = SnippetPlaceholderEvaluator(
            clipboardText: { NSPasteboard.general.string(forType: .string) }
        )
        return evaluator.evaluate(snippet.content).text
    }

    func exportJSON() {
        let panel = NSSavePanel()
        panel.title = "Export Snippets"
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "pasta-snippets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try SnippetJSONIO.encode(snippets)
            try data.write(to: url)
            lastImportExportSummary = "Exported \(snippets.count) snippet(s)"
        } catch {
            report(error: error)
        }
    }

    func importJSON() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Snippets"
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let incoming = try SnippetJSONIO.decode(data)
            let summary = try SnippetJSONIO.importSnippets(incoming, into: store)
            lastImportExportSummary = "Imported \(summary.inserted) new, updated \(summary.updated)"
            load()
        } catch {
            report(error: error)
        }
    }

    private func report(error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}
