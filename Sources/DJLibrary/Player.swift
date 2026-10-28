import AVFoundation
import Observation
import DJCore
import SwiftUI

/// Reproductor de preview de la pista seleccionada.
@MainActor
@Observable
final class Player {
    private(set) var url: URL?
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    var currentTime: Double = 0

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var isScrubbing = false

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.currentTime = t.seconds.isFinite ? t.seconds : 0
            }
        }
    }

    func play(_ url: URL) {
        if url == self.url {
            toggle()
            return
        }
        self.url = url
        currentTime = 0
        duration = 0
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        Task {
            let d = (try? await item.asset.load(.duration))?.seconds ?? 0
            if self.url == url { duration = d.isFinite ? d : 0 }
        }
        player.play()
        isPlaying = true
    }

    func toggle() {
        guard url != nil else { return }
        if isPlaying {
            player.pause()
        } else {
            if duration > 0 && currentTime >= duration - 0.1 { seek(to: 0) }
            player.play()
        }
        isPlaying.toggle()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        url = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func seek(to seconds: Double) {
        let t = max(0, min(seconds, duration))
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ delta: Double) { seek(to: currentTime + delta) }

    /// Posición exacta en este instante (para animar la onda a 60 fps sin esperar al observador).
    var now: Double {
        if isScrubbing { return currentTime }
        let t = player.currentTime().seconds
        return t.isFinite ? t : currentTime
    }

    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        currentTime = now
    }

    /// Salta a un cue y reproduce, como al pulsar un pad en el deck.
    func jump(to seconds: Double) {
        guard url != nil else { return }
        seek(to: seconds)
        if !isPlaying {
            player.play()
            isPlaying = true
        }
    }

    func scrubbing(_ active: Bool) {
        isScrubbing = active
        if !active { seek(to: currentTime) }
    }
}
