import Foundation
import AppKit

/// Loads and plays the bundled `.aiff` cues. Single shared instance — NSSound
/// caches its decoded buffer per object, so we keep one preloaded NSSound per
/// cue and replay it. Honours the `Heidrun.soundsEnabled` UserDefaults flag
/// (set via @AppStorage in Settings); when disabled, `play(_:)` is a no-op.
@MainActor
public final class SoundPlayer {
    public static let shared = SoundPlayer()

    public static let enabledDefaultsKey = "Heidrun.soundsEnabled"

    private var cache: [SoundCue: NSSound] = [:]

    private init() {}

    /// Whether sounds are currently allowed to play. Reads UserDefaults so
    /// the toggle in Settings takes effect immediately without us having to
    /// observe.
    public var isEnabled: Bool {
        // Default to on. UserDefaults returns false for an unset Bool, so
        // we check for explicit registration via `object(forKey:)`.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.enabledDefaultsKey) == nil {
            return true
        }
        return defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    public func play(_ cue: SoundCue) {
        guard isEnabled else { return }
        guard let sound = loadIfNeeded(cue) else { return }
        // NSSound.play() returns false if the sound is already playing.
        // Stop+rewind so rapid repeats (multiple chat lines) sound right.
        if sound.isPlaying { sound.stop() }
        sound.currentTime = 0
        sound.play()
    }

    private func loadIfNeeded(_ cue: SoundCue) -> NSSound? {
        if let cached = cache[cue] { return cached }
        guard let url = Bundle.module.url(
            forResource: cue.resourceName,
            withExtension: "aiff"
        ) else {
            FileHandle.standardError.write(Data(
                "[SoundPlayer] missing resource \(cue.resourceName).aiff\n".utf8
            ))
            return nil
        }
        guard let sound = NSSound(contentsOf: url, byReference: false) else {
            FileHandle.standardError.write(Data(
                "[SoundPlayer] could not initialise NSSound for \(cue.resourceName)\n".utf8
            ))
            return nil
        }
        cache[cue] = sound
        return sound
    }
}
