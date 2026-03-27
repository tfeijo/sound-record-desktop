import Foundation

/// Exports meeting data as Obsidian-compatible Markdown with YAML frontmatter,
/// [[wikilinks]], and checkbox action items.
enum ObsidianExporter {

    /// Export a meeting to an Obsidian vault. Returns the file path on success.
    static func export(meeting: Meeting, vaultPath: String) throws -> String {
        let meetNotesDir = URL(fileURLWithPath: vaultPath)
            .appendingPathComponent("MeetNotes", isDirectory: true)

        // Create directory if needed
        if !FileManager.default.fileExists(atPath: meetNotesDir.path) {
            try FileManager.default.createDirectory(
                at: meetNotesDir,
                withIntermediateDirectories: true
            )
        }

        let filename = sanitizeFilename(meeting.title) + ".md"
        let fileURL = meetNotesDir.appendingPathComponent(filename)

        let markdown = renderMarkdown(meeting: meeting)
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)

        return fileURL.path
    }

    /// Render full Obsidian-compatible Markdown for a meeting.
    static func renderMarkdown(meeting: Meeting) -> String {
        var lines = [String]()

        // YAML frontmatter
        lines.append("---")
        lines.append("title: \"\(meeting.title)\"")
        lines.append("date: \(isoDate(meeting.date))")
        if let startTime = meeting.startTime {
            lines.append("start_time: \(isoDateTime(startTime))")
        }
        if let endTime = meeting.endTime {
            lines.append("end_time: \(isoDateTime(endTime))")
        }
        lines.append("duration: \(formatDuration(meeting.durationSeconds))")
        lines.append("speakers: \(meeting.speakerCount)")
        lines.append("status: \(meeting.status.rawValue)")
        if let meetUrl = meeting.meetUrl, !meetUrl.isEmpty {
            lines.append("meet_url: \"\(meetUrl)\"")
        }
        lines.append("tags:")
        lines.append("  - meeting-notes")
        lines.append("---")
        lines.append("")

        // Title
        lines.append("# \(meeting.title)")
        lines.append("")

        // Summary
        if let summary = meeting.summary {
            lines.append("## Summary")
            lines.append("")
            lines.append(summary.summary)
            lines.append("")

            if !summary.decisions.isEmpty {
                lines.append("### Decisions")
                lines.append("")
                for decision in summary.decisions {
                    lines.append("- \(decision)")
                }
                lines.append("")
            }

            if !summary.actionItems.isEmpty {
                lines.append("### Action Items")
                lines.append("")
                for item in summary.actionItems {
                    let assignee = item.assignee.map { " @\($0)" } ?? ""
                    lines.append("- [ ] \(item.description)\(assignee)")
                }
                lines.append("")
            }

            if !summary.topics.isEmpty {
                lines.append("### Topics")
                lines.append("")
                for topic in summary.topics {
                    lines.append("- **\(topic.title)**")
                    if let topicSummary = topic.summary, !topicSummary.isEmpty {
                        lines.append("  \(topicSummary)")
                    }
                }
                lines.append("")
            }
        }

        // AI Notes
        if let aiNotes = meeting.aiNotes {
            lines.append("## AI Notes")
            lines.append("")

            if !aiNotes.topics.isEmpty {
                lines.append("### Topics")
                lines.append("")
                for topic in aiNotes.topics {
                    // Topics may already contain [[wikilinks]]
                    lines.append("- \(topic)")
                }
                lines.append("")
            }

            if !aiNotes.decisions.isEmpty {
                lines.append("### Decisions")
                lines.append("")
                for decision in aiNotes.decisions {
                    lines.append("- \(decision)")
                }
                lines.append("")
            }

            if !aiNotes.actionItems.isEmpty {
                lines.append("### Action Items")
                lines.append("")
                for item in aiNotes.actionItems {
                    let assignee = item.assignee.map { " @\($0)" } ?? ""
                    lines.append("- [ ] \(item.description)\(assignee)")
                }
                lines.append("")
            }
        }

        // Personal Notes
        if !meeting.personalNotes.isEmpty {
            lines.append("## Personal Notes")
            lines.append("")
            for note in meeting.personalNotes.sorted(by: { $0.timestamp < $1.timestamp }) {
                let ts = formatTimestamp(note.timestamp)
                lines.append("- **[\(ts)]** \(note.text)")
            }
            lines.append("")
        }

        // Comparison
        if let comparison = meeting.comparison {
            lines.append("## Note Comparison")
            lines.append("")

            if !comparison.aligned.isEmpty {
                lines.append("### Aligned")
                for item in comparison.aligned {
                    lines.append("- \(item.description)")
                }
                lines.append("")
            }

            if !comparison.userOnly.isEmpty {
                lines.append("### My Insights (AI missed)")
                for item in comparison.userOnly {
                    lines.append("- \(item.description)")
                }
                lines.append("")
            }

            if !comparison.aiOnly.isEmpty {
                lines.append("### AI Insights (I missed)")
                for item in comparison.aiOnly {
                    lines.append("- \(item.description)")
                }
                lines.append("")
            }

            if !comparison.conflicts.isEmpty {
                lines.append("### Conflicts")
                for item in comparison.conflicts {
                    lines.append("- \(item.description)")
                }
                lines.append("")
            }
        }

        // Transcript
        if !meeting.transcript.isEmpty {
            lines.append("## Transcript")
            lines.append("")
            for segment in meeting.transcript {
                let ts = formatTimestamp(segment.start)
                lines.append("**[\(ts)] \(segment.speaker):** \(segment.text)")
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = name
            .components(separatedBy: invalidChars)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return sanitized.isEmpty ? "Untitled Meeting" : String(sanitized.prefix(100))
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private static func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let isoDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private static func isoDate(_ date: Date) -> String {
        isoDateFormatter.string(from: date)
    }

    private static func isoDateTime(_ date: Date) -> String {
        isoDateTimeFormatter.string(from: date)
    }
}
