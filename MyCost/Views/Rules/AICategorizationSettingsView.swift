import SwiftUI

/// Optional: lets the end user connect their *own* AI account for fallback
/// categorization. The app has no built-in key — if this is left unconnected
/// the feature simply stays off and categorization is fully manual/rule-based.
struct AICategorizationSettingsView: View {
    @EnvironmentObject private var aiController: AICategorizationController
    @Environment(\.dismiss) private var dismiss

    @State private var endpointText = "https://api.openai.com/v1/chat/completions"
    @State private var apiKey = ""
    @State private var model = "gpt-4o-mini"
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                if aiController.isConnected {
                    LabeledContent("Status", value: "Connected")
                        .foregroundStyle(.green)
                    if let summary = aiController.connectionSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("Status", value: "Not connected")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("When merchant rules can't categorize a transaction, MyCost can ask a connected AI service for a suggestion. Only the merchant description and amount are sent — no dates, accounts, notes, or balances. You review every suggestion before it is applied.")
            }

            Section("Connect your account") {
                TextField("Endpoint URL", text: $endpointText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("aiSettings.endpoint")

                SecureField("API key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("aiSettings.apiKey")

                TextField("Model", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("aiSettings.model")

                Button("Save Connection", action: save)
                    .accessibilityIdentifier("aiSettings.save")
            }

            if aiController.isConnected {
                Section {
                    Button("Disconnect", role: .destructive, action: disconnect)
                        .accessibilityIdentifier("aiSettings.disconnect")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("AI Categorization")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func save() {
        errorMessage = nil
        let trimmedEndpoint = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: trimmedEndpoint), url.scheme?.hasPrefix("http") == true else {
            errorMessage = "Enter a valid https endpoint URL."
            return
        }
        guard !trimmedKey.isEmpty else {
            errorMessage = "Enter your API key."
            return
        }
        guard !trimmedModel.isEmpty else {
            errorMessage = "Enter a model name."
            return
        }

        do {
            try aiController.connect(endpointURL: url, apiKey: trimmedKey, model: trimmedModel)
            apiKey = ""
            dismiss()
        } catch {
            errorMessage = "Could not save connection: \(error.localizedDescription)"
        }
    }

    private func disconnect() {
        errorMessage = nil
        do {
            try aiController.disconnect()
        } catch {
            errorMessage = "Could not disconnect: \(error.localizedDescription)"
        }
    }
}
