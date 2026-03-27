import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var settings: AppSettings?

    // MARK: - Local State (bound to AppSettings)

    @State private var userName: String = ""
    @State private var whisperModelSize: String = "base"
    @State private var language: String = "auto"
    @State private var autoRecord: Bool = false
    @State private var summaryProvider: SummaryProvider = .claude
    @State private var ollamaModel: String = ""
    @State private var obsidianVaultPath: String = ""

    // MARK: - API Keys (Keychain-backed)

    @State private var anthropicApiKey: String = ""
    @State private var googleApiKey: String = ""

    // MARK: - Folder Picker

    @State private var showFolderPicker: Bool = false

    // MARK: - Whisper Model Sizes

    private let whisperModels: [(id: String, label: String, size: String)] = [
        ("tiny", "Tiny", "~75 MB"),
        ("base", "Base", "~142 MB"),
        ("small", "Small", "~466 MB"),
    ]

    // MARK: - Language Options

    private let languages: [(id: String, label: String)] = [
        ("auto", "Auto-detect"),
        ("en", "English"),
        ("es", "Spanish"),
        ("pt", "Portuguese"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("ru", "Russian"),
        ("ar", "Arabic"),
    ]

    var body: some View {
        Form {
            // MARK: - General Section

            Section("General") {
                TextField("Your Name", text: $userName)
                    .textFieldStyle(.roundedBorder)

                Toggle("Auto-record Google Meet", isOn: $autoRecord)
            }

            // MARK: - Transcription Section

            Section("Transcription") {
                Picker("Whisper Model", selection: $whisperModelSize) {
                    ForEach(whisperModels, id: \.id) { model in
                        HStack {
                            Text(model.label)
                            Spacer()
                            Text(model.size)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .tag(model.id)
                    }
                }

                Picker("Language", selection: $language) {
                    ForEach(languages, id: \.id) { lang in
                        Text(lang.label).tag(lang.id)
                    }
                }
            }

            // MARK: - LLM Provider Section

            Section("LLM Provider") {
                Picker("Summary Provider", selection: $summaryProvider) {
                    Text("Claude (Anthropic)").tag(SummaryProvider.claude)
                    Text("Gemini (Google)").tag(SummaryProvider.gemini)
                    Text("Local LLM (Ollama)").tag(SummaryProvider.local)
                }

                switch summaryProvider {
                case .claude:
                    SecureField("Anthropic API Key", text: $anthropicApiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: anthropicApiKey) { _, newValue in
                            saveApiKey(.anthropicApiKey, value: newValue)
                        }

                case .gemini:
                    SecureField("Google API Key", text: $googleApiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: googleApiKey) { _, newValue in
                            saveApiKey(.googleApiKey, value: newValue)
                        }

                case .local:
                    TextField("Ollama Model Name", text: $ollamaModel)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // MARK: - Obsidian Section

            Section("Obsidian Integration") {
                HStack {
                    TextField("Vault Path", text: $obsidianVaultPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)

                    Button("Browse...") {
                        chooseFolder()
                    }
                }

                if !obsidianVaultPath.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text(obsidianVaultPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            // MARK: - Speaker Profiles Section

            Section("Speaker Profiles") {
                NavigationLink(destination: SpeakerManagerView()) {
                    Label("Manage Speaker Profiles", systemImage: "person.2")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 480, minHeight: 500)
        .onAppear { loadSettings() }
        .onChange(of: userName) { _, _ in saveSettings() }
        .onChange(of: whisperModelSize) { _, _ in saveSettings() }
        .onChange(of: language) { _, _ in saveSettings() }
        .onChange(of: autoRecord) { _, _ in saveSettings() }
        .onChange(of: summaryProvider) { _, _ in saveSettings() }
        .onChange(of: ollamaModel) { _, _ in saveSettings() }
        .onChange(of: obsidianVaultPath) { _, _ in saveSettings() }
    }

    // MARK: - Load / Save

    private func loadSettings() {
        let s = AppSettings.current(in: modelContext)
        settings = s

        userName = s.userName
        whisperModelSize = s.whisperModelSize
        language = s.language
        autoRecord = s.autoRecord
        summaryProvider = s.summaryProvider
        ollamaModel = s.ollamaModel ?? ""
        obsidianVaultPath = s.obsidianVaultPath ?? ""

        // Load API keys from Keychain
        anthropicApiKey = KeychainService.read(key: .anthropicApiKey) ?? ""
        googleApiKey = KeychainService.read(key: .googleApiKey) ?? ""
    }

    private func saveSettings() {
        guard let s = settings else { return }

        s.userName = userName
        s.whisperModelSize = whisperModelSize
        s.language = language
        s.autoRecord = autoRecord
        s.summaryProvider = summaryProvider
        s.ollamaModel = ollamaModel.isEmpty ? nil : ollamaModel
        s.obsidianVaultPath = obsidianVaultPath.isEmpty ? nil : obsidianVaultPath

        try? modelContext.save()
    }

    private func saveApiKey(_ key: KeychainService.Key, value: String) {
        if value.isEmpty {
            KeychainService.delete(key: key)
        } else {
            _ = KeychainService.save(key: key, value: value)
        }
    }

    // MARK: - Folder Picker (NSOpenPanel)

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Obsidian Vault Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            obsidianVaultPath = url.path
        }
    }
}

