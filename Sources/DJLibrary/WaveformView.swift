import DJCore
import SwiftUI

/// Dibuja la onda como Engine: altura = intensidad, color = mezcla graves (rojo), medios (verde), agudos (azul).
struct WaveformView: View {
    let waveform: Waveform
    /// 0…1; si se indica, lo ya reproducido se ve atenuado y se marca el cabezal.
    var progress: Double?
    /// Si se pasan, se pintan los hot cues (línea de su color) y el cue principal (triángulo naranja).
    var perf: TrackPerformance?
    /// Duración en segundos para situar los cues; por defecto la que da la onda de Engine.
    var duration: Double?

    var body: some View {
        Canvas { ctx, size in
            let cols = waveform.columns
            guard !cols.isEmpty, size.width > 0 else { return }
            let bars = Int(size.width)
            for x in 0..<bars {
                let lo = x * cols.count / bars
                let hi = max(lo + 1, (x + 1) * cols.count / bars)
                var l = 0.0, m = 0.0, h = 0.0
                for c in cols[lo..<min(hi, cols.count)] {
                    l = max(l, c.low); m = max(m, c.mid); h = max(h, c.high)
                }
                let amp = max(l, m, h)
                guard amp > 0.01 else { continue }
                let color = Color(red: l / amp, green: m / amp, blue: h / amp)
                    .opacity(progress.map { Double(x) / Double(bars) < $0 ? 0.45 : 1 } ?? 1)
                let barH = size.height * amp
                ctx.fill(Path(CGRect(x: CGFloat(x), y: size.height - barH, width: 1, height: barH)), with: .color(color))
            }
            if let perf, let total = duration ?? waveform.duration(sampleRate: perf.sampleRate), total > 0 {
                let compact = size.height < 30
                func cx(_ t: Double) -> CGFloat { CGFloat(t / total) * size.width }
                if let main = perf.mainCue {
                    var tri = Path()
                    let s: CGFloat = compact ? 4 : 6
                    tri.move(to: CGPoint(x: cx(main) - s, y: size.height))
                    tri.addLine(to: CGPoint(x: cx(main) + s, y: size.height))
                    tri.addLine(to: CGPoint(x: cx(main), y: size.height - s * 1.4))
                    ctx.fill(tri, with: .color(.orange))
                }
                for cue in perf.hotCues {
                    let x = cx(cue.seconds)
                    ctx.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(cue.color.swiftUI))
                    if compact {
                        ctx.fill(Path(CGRect(x: x - 0.75, y: 0, width: 5, height: 4)), with: .color(cue.color.swiftUI))
                    } else {
                        ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: 12, height: 11), cornerRadius: 2),
                                 with: .color(cue.color.swiftUI))
                        ctx.draw(Text(DeckView.letters[min(cue.index, 7)]).font(.system(size: 8, weight: .bold)).foregroundColor(.black),
                                 at: CGPoint(x: x + 6, y: 5.5))
                    }
                }
            }
            if let progress {
                let px = size.width * progress
                ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
            }
        }
    }
}
