import AVFoundation
import Foundation

@MainActor
class AudioPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var totalDuration: TimeInterval = 0
    @Published var progress: Double = 0

    private var player: AVAudioPlayer?
    private var timerTask: Task<Void, Never>?

    @Published var errorMessage = ""

    func play(url: URL) {
        stop()
        errorMessage = ""
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "File not found: \(url.lastPathComponent)"
            return
        }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            totalDuration = player?.duration ?? 0
            let ok = player?.play() ?? false
            isPlaying = ok
            if ok { startTimer() }
            else { errorMessage = "AVAudioPlayer.play() returned false" }
        } catch {
            errorMessage = "Playback error: \(error.localizedDescription)"
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func resume() {
        player?.play()
        isPlaying = true
        startTimer()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        totalDuration = 0
        progress = 0
        stopTimer()
    }

    func seek(to fraction: Double) {
        guard let player = player else { return }
        let time = fraction * player.duration
        player.currentTime = time
        currentTime = time
        progress = fraction
    }

    func load(url: URL) {
        stop()
        errorMessage = ""
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "File not found: \(url.lastPathComponent)"
            return
        }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            totalDuration = player?.duration ?? 0
        } catch {
            errorMessage = "Load error: \(error.localizedDescription)"
        }
    }

    var currentTimeFormatted: String { formatTime(currentTime) }
    var totalDurationFormatted: String { formatTime(totalDuration) }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func startTimer() {
        stopTimer()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self = self, let p = self.player else { break }
                self.currentTime = p.currentTime
                self.totalDuration = p.duration
                self.progress = p.duration > 0 ? p.currentTime / p.duration : 0
                if !p.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    break
                }
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}
