import SwiftUI

/// Settings window for ContextD configuration.
struct SettingsView: View {
    // API Settings
    @State private var apiKey: String = ""
    @State private var hasApiKey: Bool = false
    @State private var summarizationModel: String = "claude-haiku-4-5"
    @State private var enrichmentPass1Model: String = "claude-haiku-4-5"
    @State private var enrichmentPass2Model: String = "claude-sonnet-4-6"

    // Capture Settings
    @AppStorage("captureInterval") private var captureInterval: Double = 2.0
    @AppStorage("maxKeyframeInterval") private var maxKeyframeInterval: Double = 60
    @AppStorage("keyframeChangeThreshold") private var keyframeChangeThreshold: Double = 0.50

    // Summarization Settings
    @AppStorage("summarizationChunkDuration") private var chunkDuration: Double = 300
    @AppStorage("summarizationPollInterval") private var pollInterval: Double = 60
    @AppStorage("summarizationMinAge") private var minAge: Double = 300

    // Storage Settings
    @AppStorage("retentionDays") private var retentionDays: Int = 7

    // Prompt Templates
    @AppStorage(PromptTemplates.SettingsKey.summarizationSystem.rawValue)
    private var customSummarizationSystem: String = ""
    @AppStorage(PromptTemplates.SettingsKey.summarizationUser.rawValue)
    private var customSummarizationUser: String = ""
    @AppStorage(PromptTemplates.SettingsKey.enrichmentPass1System.rawValue)
    private var customPass1System: String = ""
    @AppStorage(PromptTemplates.SettingsKey.enrichmentPass2System.rawValue)
    private var customPass2System: String = ""

    @State private var showApiKeySaved: Bool = false
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case models = "Models"
        case prompts = "Prompts"
        case storage = "Storage"

        var id: String { rawValue }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)

            modelsTab
                .tabItem { Label("Models", systemImage: "cpu") }
                .tag(SettingsTab.models)

            promptsTab
                .tabItem { Label("Prompts", systemImage: "text.bubble") }
                .tag(SettingsTab.prompts)

            storageTab
                .tabItem { Label("Storage", systemImage: "internaldrive") }
                .tag(SettingsTab.storage)
        }
        .padding(20)
        .frame(width: 550, height: 450)
        .onAppear {
            hasApiKey = AnthropicClient.hasAPIKey()
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("API Key") {
                HStack {
                    SecureField("Anthropic API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    Button(action: saveApiKey) {
                        Text(showApiKeySaved ? "Saved!" : "Save")
                    }
                    .disabled(apiKey.isEmpty)
                }

                if hasApiKey {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("API key is configured")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Capture") {
                HStack {
                    Text("Capture interval:")
                    Slider(value: $captureInterval, in: 1...10, step: 0.5)
                    Text("\(String(format: "%.1f", captureInterval))s")
                        .monospacedDigit()
                        .frame(width: 40)
                }

                HStack {
                    Text("Keyframe interval:")
                    Slider(value: $maxKeyframeInterval, in: 30...300, step: 10)
                    Text("\(Int(maxKeyframeInterval))s")
                        .monospacedDigit()
                        .frame(width: 40)
                }
                Text("Maximum time between full-screen OCR captures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Keyframe threshold:")
                    Slider(value: $keyframeChangeThreshold, in: 0.20...0.80, step: 0.05)
                    Text("\(Int(keyframeChangeThreshold * 100))%")
                        .monospacedDigit()
                        .frame(width: 40)
                }
                Text("Percentage of screen tiles that must change to trigger a full-screen OCR.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Models Tab

    private var modelsTab: some View {
        Form {
            Section("Summarization") {
                TextField("Model:", text: $summarizationModel)
                    .textFieldStyle(.roundedBorder)
                Text("Used for progressive summarization of screen activity. Recommend a cheap/fast model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Enrichment Pass 1 (Relevance Judging)") {
                TextField("Model:", text: $enrichmentPass1Model)
                    .textFieldStyle(.roundedBorder)
                Text("Judges which summaries are relevant to your prompt. Cheap/fast recommended.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Enrichment Pass 2 (Context Synthesis)") {
                TextField("Model:", text: $enrichmentPass2Model)
                    .textFieldStyle(.roundedBorder)
                Text("Synthesizes detailed context into footnotes. Can use a more capable model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Prompts Tab

    private var promptsTab: some View {
        Form {
            Section("Summarization System Prompt") {
                TextEditor(text: $customSummarizationSystem)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 120)

                if customSummarizationSystem.isEmpty {
                    Text("Using default prompt. Enter custom text to override.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Reset to Default") {
                    customSummarizationSystem = ""
                }
                .controlSize(.small)
            }

            Section("Enrichment Pass 1 System Prompt") {
                TextEditor(text: $customPass1System)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 120)

                Button("Reset to Default") {
                    customPass1System = ""
                }
                .controlSize(.small)
            }

            Section("Enrichment Pass 2 System Prompt") {
                TextEditor(text: $customPass2System)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 120)

                Button("Reset to Default") {
                    customPass2System = ""
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Storage Tab

    private var storageTab: some View {
        Form {
            Section("Retention") {
                Stepper("Keep data for \(retentionDays) days", value: $retentionDays, in: 1...90)
            }

            Section("Summarization Timing") {
                HStack {
                    Text("Chunk duration:")
                    Slider(value: $chunkDuration, in: 60...900, step: 60)
                    Text("\(Int(chunkDuration / 60))m")
                        .monospacedDigit()
                        .frame(width: 40)
                }

                HStack {
                    Text("Poll interval:")
                    Slider(value: $pollInterval, in: 10...300, step: 10)
                    Text("\(Int(pollInterval))s")
                        .monospacedDigit()
                        .frame(width: 40)
                }

                HStack {
                    Text("Min age before summarizing:")
                    Slider(value: $minAge, in: 60...600, step: 30)
                    Text("\(Int(minAge / 60))m")
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }
        }
    }

    // MARK: - Actions

    private func saveApiKey() {
        do {
            try AnthropicClient.saveAPIKey(apiKey)
            hasApiKey = true
            showApiKeySaved = true
            apiKey = "" // Clear from memory
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showApiKeySaved = false
            }
        } catch {
            // Show error - TODO: proper error handling
        }
    }
}
