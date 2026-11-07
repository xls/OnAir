import OnAirCore
import SwiftUI
import UIKit

/// Weather satellites and picture modes: the image as it builds up, then what the decoder knows.
struct PicturePage: View {
    let receiver: Receiver
    @State private var results = Results()
    @State private var image: UIImage?
    @State private var seq: UInt64 = 0
    @State private var jpegSize: Int32 = 0
    @State private var tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var zoomed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.05, green: 0.06, blue: 0.1))
                    if let image {
                        Image(uiImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14))
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "globe.asia.australia.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                            Text(receiver.status.running ? "Waiting for a picture" : "Press power to start").font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(50)
                    }
                }
                .onTapGesture { if image != nil { zoomed = true } }
                if receiver.status.running { InstrumentGrid(results: results) }   // stopped, the core still reports the TV defaults
                InstrumentTables(results: results)
            }
            .padding(12)
        }
        .background(Color(red: 0.02, green: 0.03, blue: 0.06).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $zoomed) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: .fit) }
                Button { zoomed = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.8)).padding()
                }
            }
        }
        .onAppear(perform: load)
        .onReceive(tick) { _ in load() }
    }

    private func load() {
        if let new = Results.current() { results = new }
        var jpeg: UnsafePointer<UInt8>?
        var size: Int32 = 0
        if onair_jpeg_latest(&jpeg, &size), let jpeg, size != jpegSize {
            jpegSize = size
            image = UIImage(data: Data(bytes: jpeg, count: Int(size)))
            return
        }
        var pixels: UnsafePointer<UInt8>?
        var width: Int32 = 0, height: Int32 = 0
        var newSeq: UInt64 = 0
        guard onair_image_latest(&pixels, &width, &height, &newSeq), let pixels, newSeq != seq else { return }
        seq = newSeq
        let data = Data(bytes: pixels, count: Int(width) * Int(height) * 4)
        if let provider = CGDataProvider(data: data as CFData),
           let cg = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            image = UIImage(cgImage: cg)
        }
    }
}
