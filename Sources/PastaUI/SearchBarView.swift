import PastaCore
import SwiftUI

public struct SearchBarView: View {
    @Binding private var query: String
    @Binding private var isFuzzy: Bool
    @Binding private var contentType: ContentType?

    private let resultCount: Int

    @FocusState private var isFocused: Bool

    public init(
        query: Binding<String>,
        isFuzzy: Binding<Bool>,
        contentType: Binding<ContentType?>,
        resultCount: Int
    ) {
        _query = query
        _isFuzzy = isFuzzy
        _contentType = contentType
        self.resultCount = resultCount
    }

    public var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isFocused)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Toggle("Fuzzy", isOn: $isFuzzy)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(isFuzzy ? "Fuzzy search" : "Exact search")

            Picker("Type", selection: $contentType) {
                Text("All").tag(ContentType?.none)
                ForEach(ContentType.allCases, id: \.self) { type in
                    Text(type.pickerTitle).tag(Optional(type))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Text("\(resultCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Result count")
        }
        .onAppear {
            DispatchQueue.main.async {
                isFocused = true
            }
        }
    }
}

private extension ContentType {
    var pickerTitle: String {
        switch self {
        case .envVar: return "ENV"
        case .envVarBlock: return "ENV BLOCK"
        default: return rawValue.uppercased()
        }
    }
}
