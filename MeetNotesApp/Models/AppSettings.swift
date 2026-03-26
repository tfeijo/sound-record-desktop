import Foundation
import SwiftData

@Model
final class AppSettings {
    var userName: String
    var whisperModelSize: String
    var language: String
    var autoRecord: Bool
    var summaryProvider: SummaryProvider
    var anthropicApiKey: String?
    var googleApiKey: String?
    var ollamaModel: String?
    var obsidianVaultPath: String?

    init(
        userName: String = "",
        whisperModelSize: String = "base",
        language: String = "en",
        autoRecord: Bool = false,
        summaryProvider: SummaryProvider = .claude,
        anthropicApiKey: String? = nil,
        googleApiKey: String? = nil,
        ollamaModel: String? = nil,
        obsidianVaultPath: String? = nil
    ) {
        self.userName = userName
        self.whisperModelSize = whisperModelSize
        self.language = language
        self.autoRecord = autoRecord
        self.summaryProvider = summaryProvider
        self.anthropicApiKey = anthropicApiKey
        self.googleApiKey = googleApiKey
        self.ollamaModel = ollamaModel
        self.obsidianVaultPath = obsidianVaultPath
    }
}
