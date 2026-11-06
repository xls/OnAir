import OnAirCore
import SwiftUI
import UIKit

/// The band each broadcast mode tunes across.
private struct Band {
    let low, high, step: Double
    var pointsPerMhz = 34.0
    var tick = 0.2
    var majorEvery = 5
    var usesKnownChannels = false

    static func of(mode: String) -> Band {
        switch mode {
        case "AM broadcast", "AM stereo (C-QUAM)": return Band(low: 0.531, high: 1.71, step: 0.009, pointsPerMhz: 900, tick: 0.01, majorEvery: 10)
        case "Shortwave", "DRM": return Band(low: 2.3, high: 26.1, step: 0.005, pointsPerMhz: 34, tick: 0.5, majorEvery: 2)
        case "DAB / DAB+": return Band(low: 174, high: 240, step: 1.712, pointsPerMhz: 12, tick: 1, majorEvery: 5, usesKnownChannels: true)
        default: return Band(low: 87.5, high: 108, step: 0.1)
        }
    }
}

/// A radio for digital and AM broadcasting: the lit window, the services of the multiplex, the slideshow, and a tuning scale.
struct BroadcastPage: View {
    let receiver: Receiver
    @State private var results = Results()
    @State private var slide: UIImage?
    @State private var channels = ChannelPlan()
    @State private var tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var band: Band { Band.of(mode: receiver.status.mode) }
    private var services: Results.Table? { results.table("Services") }
    private var signal: Double {
        let snr = Double(results.card("SNR").split(separator: " ").first ?? "") ?? 0
        return min(max(snr / 40, 0), 1)
    }

    var body: some View {
        FacePlate {
            VStack(spacing: 10) {
                display
                HStack(spacing: 8) {
                    NeedleMeter(title: "SIGNAL", value: receiver.status.running ? signal : 0, scale: ["0", "10", "20", "30", "40"])
                    if let slide {
                        GlassWindow(corner: 6) {
                            Image(uiImage: slide).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(height: 96)
                BandScale(mhz: receiver.status.mhz, lowMhz: band.low, highMhz: band.high, stepMhz: band.step, pointsPerMhz: band.pointsPerMhz, tickMhz: band.tick,
                          majorEvery: band.majorEvery, tune: receiver.tune(mhz:))
                    .frame(height: 56)
                if let services, !services.rows.isEmpty {
                    serviceList(services)
                } else {
                    HStack {
                        Spacer()
                        VStack(spacing: 3) {
                            TuningKnob(stepsPerTurn: 40, turned: turn)
                            EngravedLabel(text: "TUNING")
                        }
                        Spacer()
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .onAppear {
            channels = ChannelPlan.current()
            load()
        }
        .onReceive(tick) { _ in load() }
    }

    /// DAB moves between its numbered channels; everything else moves by the band's step.
    private func turn(_ steps: Int) {
        if band.usesKnownChannels, !channels.known.isEmpty {
            let list = channels.known.map(\.mhz).sorted()
            let here = list.firstIndex { $0 >= receiver.status.mhz - 0.01 } ?? 0
            receiver.tune(mhz: list[min(max(here + steps, 0), list.count - 1)])
        } else {
            receiver.tune(mhz: min(max(receiver.status.mhz + Double(steps) * band.step, band.low), band.high))
        }
    }

    private var display: some View {
        GlassWindow(corner: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(results.card("Ensemble").isEmpty ? receiver.status.mode : results.card("Ensemble"))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Text(String(format: band.step < 0.05 ? "%.3f" : "%.1f", receiver.status.mhz) + " MHz")
                    .font(.system(size: 36, weight: .light, design: .monospaced))
                Text(results.summary ?? (receiver.status.running ? "Searching…" : "Press power"))
                    .font(.system(size: 12, design: .monospaced))
                    .opacity(0.75)
                    .lineLimit(2, reservesSpace: true)
            }
            .foregroundStyle(RadioTheme.amber)
            .shadow(color: RadioTheme.amber.opacity(0.7), radius: 7)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func serviceList(_ table: Results.Table) -> some View {
        GlassWindow(corner: 6) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                        Button {
                            if let index = Int32(table.value(row, "Subch")) { onair_broadcast_select(index) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(table.value(row, "Service")).font(.system(size: 14, weight: .medium, design: .monospaced))
                                    let now = table.value(row, "Now playing")
                                    if !now.isEmpty { Text(now).font(.system(size: 10, design: .monospaced)).opacity(0.7).lineLimit(1) }
                                }
                                Spacer()
                                Text("\(table.value(row, "Type")) \(table.value(row, "kbit/s"))").font(.system(size: 10, design: .monospaced)).opacity(0.7)
                            }
                            .foregroundStyle(RadioTheme.amber)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func load() {
        if let new = Results.current() { results = new }
        var pixels: UnsafePointer<UInt8>?
        var width: Int32 = 0, height: Int32 = 0
        if onair_slide_latest(&pixels, &width, &height), let pixels {
            let data = Data(bytes: pixels, count: Int(width) * Int(height) * 4)
            if let provider = CGDataProvider(data: data as CFData),
               let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                slide = UIImage(cgImage: image)
            }
        }
    }
}
