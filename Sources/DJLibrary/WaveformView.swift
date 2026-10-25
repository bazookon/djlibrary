import DJCore
import SwiftUI

/// Dibuja la onda como Engine: altura = intensidad, color = mezcla graves (rojo), medios (verde), agudos (azul).
struct WaveformView: View {
    let waveform: Waveform
    /// 0…1; si se indica, lo ya reproducido se ve atenuado y se marca el cabezal.
    var progress: Double?

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
            if let progress {
                let px = size.width * progress
                ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
            }
        }
    }
}
