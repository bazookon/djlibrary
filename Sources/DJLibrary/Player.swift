import AVFoundation
import Observation
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

    func scrubbing(_ active: Bool) {
        isScrubbing = active
        if !active { seek(to: currentTime) }
    }
}

struct PlayerBar: View {
    @Environment(Player.self) private var player
    @Environment(LibraryModel.self) private var model

    var body: some View {
        @Bindable var player = player
        HStack(spacing: 12) {
            Button { playSelectionOrToggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help("Reproducir / pausar (espacio)")
            .disabled(player.url == nil && model.selection.isEmpty)

            Button { player.skip(-10) } label: { Image(systemName: "gobackward.10") }
                .buttonStyle(.borderless)
                .disabled(player.url == nil)
            Button { player.skip(10) } label: { Image(systemName: "goforward.10") }
                .buttonStyle(.borderless)
                .disabled(player.url == nil)

            Text(nowPlaying)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 260, alignment: .leading)
                .foregroundStyle(player.url == nil ? .secondary : .primary)

            Text(format(player.currentTime)).monospacedDigit().foregroundStyle(.secondary)
            if let url = player.url, let w = model.waveform(for: url), player.duration > 0 {
                // Onda con cabezal; clic o arrastre para moverse.
                GeometryReader { geo in
                    WaveformView(waveform: w, progress: player.currentTime / player.duration)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                player.scrubbing(true)
                                player.currentTime = max(0, min(1, v.location.x / geo.size.width)) * player.duration
                            }
                            .onEnded { _ in player.scrubbing(false) })
                }
                .frame(height: 32)
            } else {
                Slider(value: $player.currentTime, in: 0...max(player.duration, 1)) { editing in
                    player.scrubbing(editing)
                }
                .disabled(player.url == nil)
            }
            Text(format(player.duration)).monospacedDigit().foregroundStyle(.secondary)

            Button { player.stop() } label: { Image(systemName: "stop.fill") }
                .buttonStyle(.borderless)
                .disabled(player.url == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var nowPlaying: String {
        guard let url = player.url else { return "Doble clic o espacio para escuchar" }
        let item = model.visible.first { $0.id == url }
        if let item, !item.edited.title.isEmpty {
            return item.edited.artist.isEmpty ? item.edited.title : "\(item.edited.artist) – \(item.edited.title)"
        }
        return url.lastPathComponent
    }

    /// Si la selección es otra pista, la reproduce; si no, pausa/reanuda.
    func playSelectionOrToggle() {
        if let url = model.playTarget, url != player.url {
            player.play(url)
        } else {
            player.toggle()
        }
    }

    private func format(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let total = Int(s)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
