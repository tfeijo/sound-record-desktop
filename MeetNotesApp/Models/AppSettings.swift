import Foundation
import SwiftData

@Model
final class AppSettings {
    var userName: String
    var whisperModelSize: String
    var language: String
    var autoRecord: Bool
    var summaryProvider: SummaryProvider
    var ollamaModel: String?
    var obsidianVaultPath: String?

    init(
        userName: String = "",
        whisperModelSize: String = "base",
        language: String = "en",
        autoRecord: Bool = false,
        summaryProvider: SummaryProvider = .claude,
        ollamaModel: String? = nil,
        obsidianVaultPath: String? = nil
    ) {
        self.userName = userName
        self.whisperModelSize = whisperModelSize
        self.language = language
        self.autoRecord = autoRecord
        self.summaryProvider = summaryProvider
        self.ollamaModel = ollamaModel
        self.obsidianVaultPath = obsidianVaultPath
    }

    static func current(in context: ModelContext) -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let settings = AppSettings()
        context.insert(settings)
        return settings
    }
}
