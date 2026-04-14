import Foundation

struct MarkdownWriter {

    static func save(
        title: String,
        transcript: String,
        recordingID: String,
        duration: TimeInterval,
        speakers: [String] = [],
        notes: String? = nil
    ) throws -> String {
        let prefs = Preferences.shared
        let dir = URL(fileURLWithPath: prefs.meetingsPath)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let slug = slugify(title.isEmpty ? recordingID : title)
        let filename = "\(recordingID)-\(slug).md"
        let filepath = dir.appendingPathComponent(filename)

        // On rename + re-save, delete old file whose prefix matches the recordingID
        if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let prefix = recordingID + "-"
            for file in contents where file.pathExtension == "md"
                && file.lastPathComponent.hasPrefix(prefix)
                && file.lastPathComponent != filename {
                try? fm.removeItem(at: file)
            }
        }

        // Resolve which speakers have a people page (for wikilinks)
        let linkedSpeakers = resolveLinkedSpeakers(speakers)

        // Apply wikilinks in transcript body
        // Transcript format: [Speaker Name] [MM:SS]
        // Replace [Speaker Name] with [[slug|Speaker Name]] (Obsidian alias syntax)
        var linkedTranscript = transcript
        for (name, slugName) in linkedSpeakers {
            linkedTranscript = linkedTranscript.replacingOccurrences(
                of: "[\(name)]",
                with: "[[\(slugName)|\(name)]]"
            )
        }

        let durationStr = duration > 0 ? "\(Int(duration / 60)) min" : ""
        let audioFile = recordingID.isEmpty ? "" : "\(recordingID).wav"
        let safeTitle = title.replacingOccurrences(of: "\"", with: "'")

        // Build quoted speaker list with wikilinks where applicable
        let speakerEntries: [String] = speakers.map { name in
            if let (_, slugName) = linkedSpeakers.first(where: { $0.0 == name }) {
                return "\"[[\(slugName)|\(name)]]\""
            }
            return "\"\(name)\""
        }

        var lines: [String] = []
        lines.append("---")
        lines.append("date: \(todayISO())")
        lines.append("title: \"\(safeTitle)\"")
        lines.append("duration: \"\(durationStr)\"")
        if !speakerEntries.isEmpty {
            lines.append("speakers: [\(speakerEntries.joined(separator: ", "))]")
        }
        lines.append("audio_file: \"\(audioFile)\"")
        lines.append("tags: [meeting]")
        lines.append("---")
        lines.append("")

        if let notes = notes, !notes.isEmpty {
            lines.append("## Notes")
            lines.append("")
            lines.append(notes)
            lines.append("")
        }

        lines.append("## Transcript")
        lines.append("")
        lines.append(linkedTranscript)
        lines.append("")

        let content = lines.joined(separator: "\n")
        try content.write(to: filepath, atomically: true, encoding: .utf8)
        return filepath.path
    }

    /// For each speaker name, check if a people page exists under peoplePagesPath.
    /// Returns array of (originalName, slug) for speakers that have a matching page.
    private static func resolveLinkedSpeakers(_ speakers: [String]) -> [(String, String)] {
        let pagesPath = Preferences.shared.peoplePagesPath
        guard !pagesPath.isEmpty else { return [] }

        let fm = FileManager.default
        let baseURL = URL(fileURLWithPath: pagesPath)
        guard fm.fileExists(atPath: baseURL.path) else { return [] }

        // Build a set of all .md file stems found recursively under peoplePagesPath
        let knownSlugs = collectPageSlugs(under: baseURL)

        var result: [(String, String)] = []
        for name in speakers {
            let slug = speakerSlug(name)
            if knownSlugs.contains(slug) {
                result.append((name, slug))
            }
        }
        return result
    }

    /// Recursively collect all .md file stems (without extension) under a directory.
    private static func collectPageSlugs(under dir: URL) -> Set<String> {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var slugs = Set<String>()
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "md" {
                slugs.insert(fileURL.deletingPathExtension().lastPathComponent)
            }
        }
        return slugs
    }

    /// Slug for matching speaker names to people page filenames:
    /// lowercase, spaces to dashes, strip non-alphanumeric except dashes.
    static func speakerSlug(_ name: String) -> String {
        name
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\s-]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Extract unique speaker names from transcript text
    static func extractSpeakers(from transcript: String) -> [String] {
        // Transcript format: [Speaker Name] [MM:SS]\nText
        let pattern = #"^\[(.+?)\] \[\d+:\d+\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
            return []
        }
        let range = NSRange(transcript.startIndex..., in: transcript)
        var names = Set<String>()
        regex.enumerateMatches(in: transcript, range: range) { match, _, _ in
            if let nameRange = match.flatMap({ Range($0.range(at: 1), in: transcript) }) {
                let name = String(transcript[nameRange])
                // Skip generic speaker labels
                if !name.hasPrefix("Speaker ") && name != "Speaker" {
                    names.insert(name)
                }
            }
        }
        return names.sorted()
    }

    // MARK: - Helpers

    private static func todayISO() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func slugify(_ text: String) -> String {
        text
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\w\s-]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[-\s]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
