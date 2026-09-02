import SwiftData
import SwiftUI

// (Filename kept for project stability; this is the AI Provider settings screen.)

/// Choose an AI provider and connect it — or stay on "No AI", the default.
/// Categorization works without any of this: user rules → local categorizer →
/// (this, if connected) → manual / Uncategorized.
struct AIProviderSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var connections: [AIProviderConnection]

    @State private var selection: ProviderSelection = .none
    @State private var apiKey = ""
    @State private var model = ""
    @State private var statusMessage: String?
    @State private var isBusy = false

    private let service = AIProviderService()

    private enum ProviderSelection: Hashable {
        case none
        case provider(AIProviderKind)
    }

    private var activeConnection: AIProviderConnection? {
        service.activeConnection(in: connections)
    }

    var body: some View {
        Form {
            Section {
                Picker("AI Provider", selection: $selection) {
                    Text("No AI — categorize manually").tag(ProviderSelection.none)
                    ForEach(AIProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(ProviderSelection.provider(kind))
                    }
                }
                .accessibilityIdentifier("aiSettings.provider")
                .onChange(of: selection) { _, _ in
                    statusMessage = nil
                    if case .provider(let kind) = selection, activeConnection?.provider != kind {
                        model = kind.defaultModel
                    }
                }
            } footer: {
                Text("Default is No AI. Connecting a provider is optional and uses your own account.")
            }

            switch selection {
            case .none:
                Section {
                    Label("Unknown transactions go to Uncategorized for you to categorize.",
                          systemImage: "hand.point.up.left")
                        .font(.callout)
                }
            case .provider(let kind):
                providerSection(for: kind)
            }

            privacySection

            if let statusMessage {
                Section { Text(statusMessage).foregroundStyle(statusMessage.hasPrefix("Connected") ? .green : .red) }
            }
        }
        .navigationTitle("AI Provider")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear(perform: syncFromStore)
    }

    @ViewBuilder
    private func providerSection(for kind: AIProviderKind) -> some View {
        let isConnected = activeConnection?.provider == kind && activeConnection?.isConnected == true

        Section("\(kind.displayName) — Access") {
            if isConnected, let connection = activeConnection {
                LabeledContent("Status") {
                    Label("Connected", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                LabeledContent("Model", value: connection.model)
                if let validated = connection.lastValidatedAt {
                    LabeledContent("Last verified", value: validated.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Test Connection") { Task { await testConnection(connection) } }
                    .disabled(isBusy)
                    .accessibilityIdentifier("aiSettings.test")
                Button("Disconnect", role: .destructive) { disconnect(connection) }
                    .disabled(isBusy)
                    .accessibilityIdentifier("aiSettings.disconnect")
            } else {
                Text(unsupportedOAuthNote(for: kind))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link("Create an API key", destination: kind.consoleURL)

                SecureField("API key (advanced)", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("aiSettings.apiKey")
                TextField("Model", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("aiSettings.model")

                Button("Connect") { Task { await connect(kind) } }
                    .disabled(isBusy || apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("aiSettings.connect")
            }
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            Text("When AI categorization runs, MyCost sends only the merchant description from a single transaction and, optionally, its amount, plus your category names. It never sends screenshots, account numbers, other transactions, or full statements. Suggestions are shown for your review; nothing is classified silently.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func unsupportedOAuthNote(for kind: AIProviderKind) -> String {
        "\(kind.displayName) does not offer a sign-in that grants API access to third-party apps — a \(kind == .openAI ? "ChatGPT Plus" : "Claude Pro") subscription is separate from API billing. Connect with your own API key, or leave AI off."
    }

    // MARK: Actions

    private func syncFromStore() {
        if let connection = activeConnection {
            selection = .provider(connection.provider)
            model = connection.model
        } else {
            selection = .none
        }
    }

    private func connect(_ kind: AIProviderKind) async {
        isBusy = true
        statusMessage = nil
        let endpoint = kind.defaultEndpoint
        let chosenModel = model.trimmingCharacters(in: .whitespaces).isEmpty ? kind.defaultModel : model
        do {
            try await service.connectWithAPIKey(
                kind, apiKey: apiKey, model: chosenModel, endpoint: endpoint,
                existing: connections, modelContext: modelContext
            )
            apiKey = ""
            statusMessage = "Connected to \(kind.displayName)."
        } catch {
            statusMessage = message(for: error)
        }
        isBusy = false
    }

    private func testConnection(_ connection: AIProviderConnection) async {
        isBusy = true
        statusMessage = nil
        do {
            try await service.testConnection(connection, modelContext: modelContext)
            statusMessage = "Connected — credentials verified."
        } catch {
            statusMessage = message(for: error)
        }
        isBusy = false
    }

    private func disconnect(_ connection: AIProviderConnection) {
        do {
            try service.disconnect(connection, existing: connections, modelContext: modelContext)
            statusMessage = "Disconnected. To fully revoke access, delete the key in your \(connection.provider.displayName) account."
        } catch {
            statusMessage = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        switch error as? AIClassificationError {
        case .credentialsExpired: "That key was rejected. Check it and try again."
        case .providerUnavailable: "Enter a valid API key."
        case .network(let detail): "Couldn't reach the provider (\(detail))."
        case .invalidResponse: "The provider responded in an unexpected format."
        default: "Connection failed: \(error.localizedDescription)"
        }
    }
}
