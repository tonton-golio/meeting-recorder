import AppKit
import Foundation

class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    // MARK: - Transcription

    var whisperModel: String {
        get { defaults.string(forKey: "whisperModel") ?? "" }
        set { defaults.set(newValue, forKey: "whisperModel") }
    }

    var meetingLanguage: String {
        get { defaults.string(forKey: "meetingLanguage") ?? "" }
        set { defaults.set(newValue, forKey: "meetingLanguage") }
    }

    var domainTerms: String {
        get { defaults.string(forKey: "domainTerms") ?? "" }
        set { defaults.set(newValue, forKey: "domainTerms") }
    }

    // MARK: - Automation

    var autoTranscribe: Bool {
        get { defaults.object(forKey: "autoTranscribe") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoTranscribe") }
    }

    var autoSave: Bool {
        get { defaults.object(forKey: "autoSave") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoSave") }
    }

    /// Capture system audio output (other participants in video calls) alongside the mic.
    /// Requires Screen Recording permission. On first use macOS will prompt.
    var captureSystemAudio: Bool {
        get { defaults.object(forKey: "captureSystemAudio") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "captureSystemAudio") }
    }

    // MARK: - Speaker matching thresholds

    /// Cosine similarity required to auto-match a diarized speaker to a known
    /// person. Default tuned for max-over-samples matching.
    var autoMatchThreshold: Float {
        get {
            let v = defaults.double(forKey: "autoMatchThreshold")
            return v > 0 ? Float(v) : Float(PeopleStore.defaultAutoMatchThreshold)
        }
        set { defaults.set(Double(newValue), forKey: "autoMatchThreshold") }
    }

    /// Minimum cosine to show a person as a recommendation (below auto).
    var recommendThreshold: Float {
        get {
            let v = defaults.double(forKey: "recommendThreshold")
            return v > 0 ? Float(v) : 0.30
        }
        set { defaults.set(Double(newValue), forKey: "recommendThreshold") }
    }

    // MARK: - Global Hotkey

    /// Hardware key code for the global toggle-recording hotkey (default: 15 = 'R').
    var hotkeyKeyCode: UInt16 {
        get {
            let v = defaults.integer(forKey: "hotkeyKeyCode")
            return v > 0 ? UInt16(v) : 15
        }
        set { defaults.set(Int(newValue), forKey: "hotkeyKeyCode") }
    }

    /// Raw modifier flags for the global hotkey (default: Ctrl + Opt).
    var hotkeyModifiers: UInt {
        get {
            let v = defaults.object(forKey: "hotkeyModifiers") as? UInt
            return v ?? (NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.option.rawValue)
        }
        set { defaults.set(newValue, forKey: "hotkeyModifiers") }
    }

    // MARK: - Paths

    var meetingsPath: String {
        get { defaults.string(forKey: "meetingsPath") ?? defaultMeetingsPath }
        set { defaults.set(newValue, forKey: "meetingsPath") }
    }

    var recordingsPath: String {
        get { defaults.string(forKey: "recordingsPath") ?? defaultRecordingsPath }
        set { defaults.set(newValue, forKey: "recordingsPath") }
    }

    /// Path to Obsidian vault directory containing people pages (e.g. wiki/people/).
    /// If empty, wikilink generation for speakers is disabled.
    var peoplePagesPath: String {
        get { defaults.string(forKey: "peoplePagesPath") ?? "" }
        set { defaults.set(newValue, forKey: "peoplePagesPath") }
    }

    // MARK: - Retention

    var retentionEnabled: Bool {
        get { retentionDays > 0 }
        set { retentionDays = newValue ? 30 : 0 }
    }

    var retentionDays: Int {
        get { defaults.integer(forKey: "retentionDays") }
        set { defaults.set(newValue, forKey: "retentionDays") }
    }

    var retentionMode: String {
        get { defaults.string(forKey: "retentionMode") ?? "audio" }
        set { defaults.set(newValue, forKey: "retentionMode") }
    }

    // MARK: - Defaults

    static let basePath = NSHomeDirectory() + "/.meeting-recorder"
    private var defaultMeetingsPath: String { Self.basePath + "/meetings" }
    private var defaultRecordingsPath: String { Self.basePath + "/recordings" }
    static var peoplePath: String { basePath + "/people" }

    // Legacy path for migration
    static var legacyVoicesPath: String { basePath + "/voices" }
}
