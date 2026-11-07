import MetalKit
import OnAirCore
import SwiftUI

/// The colours of the television screens: a modern dark interface rather than the radio's metal.
enum TV {
    static let background = Color(red: 0.04, green: 0.05, blue: 0.08)
    static let card = Color(red: 0.1, green: 0.12, blue: 0.17)
    static let accent = Color(red: 0.32, green: 0.62, blue: 1.0)
}

/// A frequency a scan found, kept on the phone with the channels it carries.
struct ScannedMux: Identifiable, Codable {
    struct Channel: Codable {
        let name: String
        let lcn: Int
        var radio: Bool?
    }

    var id: Double { mhz }
    let mhz: Double
    let label: String
    let bandwidth: Double
    let names: [String]
    var channels: [Channel]?   // scans before this was kept have the names only

    /// Stations send the same programme under one name several times (SD and HD, spares): each name once, with the lowest number.
    var allChannels: [Channel] {
        var seen = Set<String>()
        let all = channels ?? names.map { Channel(name: $0, lcn: 0) }
        return all.sorted { ($0.lcn == 0 ? 9999 : $0.lcn) < ($1.lcn == 0 ? 9999 : $1.lcn) }.filter { seen.insert($0.name).inserted }
    }
    static func saved(_ text: String) -> [ScannedMux] { (try? JSONDecoder().decode([ScannedMux].self, from: Data(text.utf8))) ?? [] }
}

struct TVState: Decodable {
    struct Service: Decodable, Identifiable {
        let id: Int
        let name, provider, type, now, next: String
        let lcn: Int
        let scrambled: Bool
        var isRadio: Bool { type.localizedCaseInsensitiveContains("radio") }
    }

    var selected = -1
    var network = ""
    var muxKbps = 0.0
    var status = ""
    var video = ""
    var audio = ""
    var width = 0
    var height = 0
    var fps = 0.0
    var hardware = false
    var services: [Service] = []

    /// Each name once, lowest number first: see ScannedMux.allChannels.
    var uniqueServices: [Service] {
        var seen = Set<String>()
        let ordered = services.sorted { ($0.lcn == 0 ? 9999 : $0.lcn) < ($1.lcn == 0 ? 9999 : $1.lcn) }
        return ordered.filter { seen.insert($0.name.isEmpty ? "\($0.id)" : $0.name).inserted }
    }
}

func tvDecode<T: Decodable>(_ type: T.Type, _ text: UnsafePointer<CChar>?) -> T? {
    guard let text else { return nil }
    return try? JSONDecoder().decode(type, from: Data(String(cString: text).utf8))
}

/// Shows decoded pictures as they arrive, on the GPU.
final class VideoRenderer: NSObject, MTKViewDelegate {
    private struct Uniforms { var scale: SIMD2<Float>, bt709: Float, fullRange: Float }

    let device = MTLCreateSystemDefaultDevice()!
    private let queue: MTLCommandQueue
    private let nv12, rgba: MTLRenderPipelineState
    private var luma, chroma, picture: MTLTexture?
    private var uniforms = Uniforms(scale: .one, bt709: 1, fullRange: 0)
    private var pictureAspect = 16.0 / 9
    private var usingRgba = false
    var zoomed = false   // fills the view and crops the edges, instead of showing the whole picture

    override init() {
        queue = device.makeCommandQueue()!
        let library = device.makeDefaultLibrary()!
        let make = { [device] (fragment: String) -> MTLRenderPipelineState in
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "videoVertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        nv12 = make("videoFragment")
        rgba = make("videoRgbaFragment")
        super.init()
    }

    private func texture(_ current: MTLTexture?, _ format: MTLPixelFormat, _ width: Int, _ height: Int) -> MTLTexture? {
        if let current, current.width == width, current.height == height { return current }
        return device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false))
    }

    private func upload() {
        var f = OnAirVideoFrame()
        guard onair_is_started(), onair_video_latest(&f), f.width > 0, f.height > 0 else { return }
        let w = Int(f.width), h = Int(f.height)
        pictureAspect = f.displayAspect > 0 ? f.displayAspect : Double(w) / Double(h)
        uniforms.bt709 = f.bt709 ? 1 : 0
        uniforms.fullRange = f.fullRange ? 1 : 0
        if let pixels = f.rgba {
            picture = texture(picture, .rgba8Unorm, w, h)
            picture?.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * 4)
            usingRgba = true
        } else if let y = f.y, let uv = f.uv {
            luma = texture(luma, .r8Unorm, w, h)
            chroma = texture(chroma, .rg8Unorm, w / 2, h / 2)
            luma?.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: y, bytesPerRow: w)
            chroma?.replace(region: MTLRegionMake2D(0, 0, w / 2, h / 2), mipmapLevel: 0, withBytes: uv, bytesPerRow: w & ~1)
            usingRgba = false
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        upload()
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable, let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let viewAspect = view.drawableSize.width / max(view.drawableSize.height, 1)
        let fit = pictureAspect > viewAspect ? SIMD2<Float>(1, Float(viewAspect / pictureAspect)) : SIMD2<Float>(Float(pictureAspect / viewAspect), 1)
        uniforms.scale = zoomed ? fit / min(fit.x, fit.y) : fit
        if usingRgba ? picture != nil : luma != nil {
            encoder.setRenderPipelineState(usingRgba ? rgba : nv12)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(usingRgba ? picture : luma, index: 0)
            encoder.setFragmentTexture(chroma, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

private struct VideoView: UIViewRepresentable {
    let renderer: VideoRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.delegate = renderer
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}

private enum TVSection: String, CaseIterable, Identifiable {
    case channels = "Channels", guide = "Guide", teletext = "Teletext", scan = "Scan"
    var id: Self { self }
}

/// Television: the picture on top, and channels, guide, teletext and scanning under it.
struct TVPage: View {
    let receiver: Receiver
    @State private var renderer = VideoRenderer()
    @State private var state = TVState()
    @State private var section = ProcessInfo.processInfo.arguments.contains("--guide") ? TVSection.guide : .channels
    @State private var tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    @State private var autoMessage = ""
    @AppStorage("tvZoomed") private var zoomed = false
    private static let cornerInset: CGFloat = 60   // full screen runs under the rounded corners and the Dynamic Island
    @State private var controlsShown = true
    @State private var lastTap = Date.distantPast
    @State private var hideTimer: DispatchWorkItem?

    private var playing: TVState.Service? { state.services.first { $0.id == state.selected } }
    private var isInternet: Bool { receiver.status.family == OnAirFamily.internetTV }

    var body: some View {
        GeometryReader { geometry in page(geometry) }
            .ignoresSafeArea(edges: receiver.videoFullscreen ? .all : [])
    }

    private func page(_ geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                VideoView(renderer: renderer)
                overlay
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 10) {
                    if receiver.videoFullscreen {
                        Button { zoomed.toggle(); showControls() } label: {
                            Text(zoomed ? "FIT" : "ZOOM")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 44)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .accessibilityLabel(zoomed ? "Show the whole picture" : "Fill the screen")
                    }
                    Button {
                        setFullscreen(!receiver.videoFullscreen, rotate: true)
                    } label: {
                        Image(systemName: receiver.videoFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .padding(.horizontal, receiver.videoFullscreen ? Self.cornerInset : 10)
                .padding(.vertical, receiver.videoFullscreen ? 16 : 10)
                .opacity(controlsShown ? 1 : 0)
                .allowsHitTesting(controlsShown)
            }
            .overlay(alignment: .topLeading) {
                if receiver.videoFullscreen, controlsShown, let name = playing?.name {
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.horizontal, Self.cornerInset)
                        .padding(.vertical, 16)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { tapped() }
            .gesture(MagnificationGesture().onEnded { scale in
                if receiver.videoFullscreen { zoomed = scale > 1 }
            })
            .frame(height: receiver.videoFullscreen ? geometry.size.height : geometry.size.width * 9 / 16)
            if !receiver.videoFullscreen {
                if isInternet {
                    InternetTVPanel().frame(maxHeight: .infinity)
                } else {
                    if !autoMessage.isEmpty && state.width == 0 {
                        Label(autoMessage, systemImage: "waveform.badge.magnifyingglass")
                            .font(.footnote)
                            .foregroundStyle(TV.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    }
                    sectionBar
                    Group {
                        switch section {
                        case .channels: ChannelList(receiver: receiver, state: state)
                        case .guide: TVGuide(state: state)
                        case .teletext: TeletextView()
                        case .scan: ScanView(receiver: receiver, state: state) { section = .channels }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .background(receiver.videoFullscreen ? Color.black.ignoresSafeArea() : TV.background.ignoresSafeArea())
        .ignoresSafeArea(edges: receiver.videoFullscreen ? .all : [])
        .preferredColorScheme(.dark)
        .onAppear {
            load()
            if ProcessInfo.processInfo.arguments.contains("--tv-full") { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { setFullscreen(true, rotate: true) } }
        }
        .onChange(of: zoomed) { renderer.zoomed = zoomed && receiver.videoFullscreen }
        .onChange(of: receiver.videoFullscreen) {
            renderer.zoomed = zoomed && receiver.videoFullscreen
            showControls()
        }
        .onDisappear { setFullscreen(false, rotate: true) }
        .onReceive(tick) { _ in load() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // turning the phone follows the picture: sideways fills the screen, upright goes back
            let orientation = UIDevice.current.orientation
            if orientation.isLandscape && state.selected >= 0 { setFullscreen(true, rotate: false) }
            if orientation == .portrait { setFullscreen(false, rotate: false) }
        }
    }

    /// As in any video player: in full screen the controls come with a tap and go by themselves. Upright they stay.
    private func showControls() {
        withAnimation(.easeOut(duration: 0.15)) { controlsShown = true }
        hideTimer?.cancel()
        guard receiver.videoFullscreen else { return }
        let hide = DispatchWorkItem { hideControls() }
        hideTimer = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: hide)
    }

    /// One tap acts at once, so it has to be told from a double tap by hand: iOS would wait to see if a second one comes.
    private func tapped() {
        let now = Date()
        let second = now.timeIntervalSince(lastTap) < 0.3
        lastTap = second ? .distantPast : now
        if second && receiver.videoFullscreen {
            zoomed.toggle()
            return
        }
        if controlsShown && receiver.videoFullscreen { hideControls() } else { showControls() }
    }

    private func hideControls() {
        hideTimer?.cancel()
        withAnimation(.easeOut(duration: 0.3)) { controlsShown = false }
    }

    private func setFullscreen(_ on: Bool, rotate: Bool) {
        guard on != receiver.videoFullscreen else { return }
        receiver.videoFullscreen = on
        guard rotate, let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: on ? .landscapeRight : .portrait))
    }

    @ViewBuilder private var overlay: some View {
        if state.selected >= 0 {
            if !receiver.videoFullscreen {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playing?.name ?? "").font(.headline)
                    Text(state.width > 0 ? "\(state.video) \(state.width)×\(state.height) · \(state.audio)\(state.hardware ? " · hardware" : "")" : state.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(8)
            }
        } else if !isInternet {
            VStack(spacing: 6) {
                Image(systemName: "tv").font(.largeTitle)
                Text(receiver.status.running ? (state.services.isEmpty ? "Searching for channels…" : "Choose a channel") : "Press power to start")
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sectionBar: some View {
        HStack(spacing: 0) {
            ForEach(TVSection.allCases) { item in
                Button {
                    section = item
                } label: {
                    VStack(spacing: 6) {
                        Text(item.rawValue)
                            .font(.subheadline.weight(item == section ? .semibold : .regular))
                            .foregroundStyle(item == section ? .white : .secondary)
                        Capsule().fill(item == section ? TV.accent : .clear).frame(height: 3).padding(.horizontal, 14)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                }
            }
        }
    }

    private func load() {
        if let new = tvDecode(TVState.self, onair_tv_json()) { state = new }
        autoMessage = String(cString: onair_auto_message())
    }
}

/// Internet TV has no radio to tune: an address, then the channels of a playlist.
private struct InternetTVPanel: View {
    private struct State: Decodable {
        struct Channel: Decodable, Identifiable {
            let id: Int
            let name, group: String
            let drm: Bool
        }
        var busy = false
        var state = "", kind = "", message = "", playing = ""
        var mbps = 0.0, buffered = 0.0
        var channels: [Channel] = []
    }

    @AppStorage("iptvAddress") private var address = ""
    @SwiftUI.State private var state = State()
    @SwiftUI.State private var search = ""
    @SwiftUI.State private var tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @FocusState private var typing: Bool

    private var shown: [State.Channel] {
        search.isEmpty ? state.channels : state.channels.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Stream or playlist address", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($typing)
                    .submitLabel(.go)
                    .onSubmit(open)
                    .padding(10)
                    .background(TV.card, in: RoundedRectangle(cornerRadius: 10))
                Button(action: open) {
                    Image(systemName: state.busy ? "hourglass" : "play.fill").frame(width: 44, height: 44)
                }
                .disabled(address.isEmpty || state.busy)
                .background(TV.card, in: RoundedRectangle(cornerRadius: 10))
                if !state.playing.isEmpty {
                    Button {
                        onair_iptv_stop()
                    } label: {
                        Image(systemName: "stop.fill").frame(width: 44, height: 44)
                    }
                    .background(TV.card, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            if !state.playing.isEmpty || !state.message.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !state.playing.isEmpty {
                        Text(state.playing).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text([state.kind, state.state, state.mbps > 0 ? String(format: "%.1f Mbit/s", state.mbps) : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !state.message.isEmpty { Text(state.message).font(.caption).foregroundStyle(.orange) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if state.channels.count > 8 {
                TextField("Search channels", text: $search)
                    .textInputAutocapitalization(.never)
                    .padding(10)
                    .background(TV.card, in: RoundedRectangle(cornerRadius: 10))
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(shown) { channel in
                        Button {
                            onair_iptv_play(Int32(channel.id))
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(channel.name).foregroundStyle(.white)
                                    if !channel.group.isEmpty { Text(channel.group).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if channel.drm { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                                if channel.name == state.playing { Image(systemName: "speaker.wave.2.fill").foregroundStyle(TV.accent) }
                            }
                            .padding(12)
                            .background(TV.card, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    if state.channels.isEmpty && state.playing.isEmpty {
                        Text("Tuneit ships no channels. Enter the address of an HLS, HTTP, UDP or RTP stream, or an M3U playlist.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 20)
                    }
                }
            }
        }
        .padding(12)
        .onAppear(perform: load)
        .onReceive(tick) { _ in load() }
    }

    private func open() {
        typing = false
        onair_iptv_open(address)
    }

    private func load() {
        if let new = tvDecode(State.self, onair_iptv_json()) { state = new }
    }
}

private struct ChannelList: View {
    /// A channel of the frequency being received, or one kept from a scan that needs a retune first.
    private struct Row: Identifiable {
        let id: String
        let name: String
        let lcn: Int
        var service: TVState.Service?
        var mux: ScannedMux?
        var radio = false
    }

    private struct Group: Identifiable {
        var id: String { title }
        let title: String
        let tuned: Bool
        let rows: [Row]
    }

    let receiver: Receiver
    let state: TVState
    @AppStorage("tvFound") private var foundText = "[]"
    @State private var tuning: String?
    @State private var tuningName = ""
    @State private var problem = ""

    private func name(_ service: TVState.Service) -> String { service.name.isEmpty ? "Service \(service.id)" : service.name }

    private func ordered(_ rows: [Row]) -> [Row] {
        rows.sorted { ($0.lcn == 0 ? 9999 : $0.lcn, $0.name) < ($1.lcn == 0 ? 9999 : $1.lcn, $1.name) }
    }

    /// One group for each frequency. Channels of the frequency being received show what is on.
    private var groups: [Group] {
        var left = state.uniqueServices
        var out: [Group] = []
        func liveRow(_ service: TVState.Service) -> Row { Row(id: "live\(service.id)", name: name(service), lcn: service.lcn, service: service, radio: service.isRadio) }
        for mux in ScannedMux.saved(foundText).sorted(by: { $0.mhz < $1.mhz }) {
            let tuned = abs(mux.mhz - receiver.status.mhz) < 0.1
            var rows: [Row] = mux.allChannels.map { channel in
                let index = tuned ? left.firstIndex { name($0) == channel.name } : nil
                let service = index.map { left.remove(at: $0) }
                return Row(id: "\(mux.mhz)-\(channel.name)", name: channel.name, lcn: service?.lcn ?? channel.lcn, service: service, mux: mux, radio: service?.isRadio ?? channel.radio ?? false)
            }
            if tuned {   // on the air now but not there when it was scanned
                rows += left.map(liveRow)
                left = []
            }
            let label = Int(mux.label) == nil ? mux.label : "Channel \(mux.label)"
            out.append(Group(title: String(format: "%@ · %.3f MHz", label, mux.mhz), tuned: tuned, rows: ordered(rows)))
        }
        if !left.isEmpty {
            out.insert(Group(title: String(format: "%.3f MHz", receiver.status.mhz), tuned: true, rows: ordered(left.map(liveRow))), at: 0)
        }
        return out
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !problem.isEmpty {
                    Text(problem).font(.footnote).foregroundStyle(.orange)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(group.tuned ? TV.accent : Color.secondary)
                            if group.tuned { Text("TUNED").font(.system(size: 9, weight: .bold)).foregroundStyle(TV.accent) }
                        }
                        .padding(.bottom, 4)
                        ForEach(group.rows) { row in
                            Button { pick(row) } label: { label(row) }
                        }
                    }
                }
                if groups.isEmpty {
                    Text("No channels yet. Scan to find them.").font(.footnote).foregroundStyle(.secondary).padding(.top, 20)
                }
            }
            .padding(12)
        }
        .onChange(of: state.services.map(\.id)) { playWhenFound() }
    }

    private func label(_ row: Row) -> some View {
        let selected = row.service?.id == state.selected && row.service != nil
        return HStack(spacing: 12) {
            if row.radio {
                Image(systemName: "radio").foregroundStyle(.secondary).frame(width: 34)
            } else if row.lcn > 0 {
                Text(String(row.lcn))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .frame(width: 34)
                    .foregroundStyle(TV.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.body.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                detail(row).frame(height: 15, alignment: .leading)   // always there, so a row never changes height as its details arrive
            }
            Spacer()
            if tuning == row.id { ProgressView().controlSize(.small) }
            if row.service?.scrambled == true { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
            if selected { Image(systemName: "play.fill").foregroundStyle(TV.accent) }
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(selected ? TV.accent.opacity(0.16) : TV.card, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private func detail(_ row: Row) -> some View {
        if tuning == row.id {
            Text("Tuning…").font(.caption).foregroundStyle(.secondary)
        } else if let service = row.service {
            if service.now.isEmpty {
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.1)).frame(width: 130, height: 8)
            } else {
                Text(service.next.isEmpty ? service.now : "\(service.now) · Next: \(service.next)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            Text("Tap to tune").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func pick(_ row: Row) {
        problem = ""
        if let service = row.service {
            onair_tv_play(Int32(service.id))
            return
        }
        guard let mux = row.mux else { return }
        tuning = row.id
        tuningName = row.name
        onair_channel_pick(mux.mhz, mux.bandwidth)
        if !receiver.status.running { receiver.startStop() }
        receiver.refresh()
        playWhenFound()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            guard tuning == row.id else { return }
            tuning = nil
            problem = "\(row.name) did not appear on \(mux.label). The signal may be too weak."
        }
    }

    /// The new frequency's channels take a few seconds to arrive.
    private func playWhenFound() {
        guard tuning != nil, let service = state.uniqueServices.first(where: { name($0) == tuningName }) else { return }
        tuning = nil
        onair_tv_play(Int32(service.id))
    }
}

/// Teletext on a real 40 by 25 grid, with mosaics and the four coloured links.
private struct TeletextView: View {
    @AppStorage("teletextPage") private var page = 100
    @State private var cells = [UInt32](repeating: 0, count: 1000)
    @State private var links = [Int32](repeating: 0, count: 4)
    @State private var have = false
    @State private var typed = ""
    @State private var tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let palette: [Color] = [.black, .red, .green, .yellow, .blue, Color(red: 1, green: 0, blue: 1), .cyan, .white]
    private static let linkColours: [Color] = [.red, .green, .yellow, .cyan]

    var body: some View {
        VStack(spacing: 8) {
            Canvas { context, size in
                let w = size.width / 40, h = size.height / 25
                for row in 0..<25 {
                    for column in 0..<40 {
                        let cell = cells[row * 40 + column]
                        let rect = CGRect(x: CGFloat(column) * w, y: CGFloat(row) * h, width: w + 0.5, height: h + 0.5)
                        let background = Int(cell >> 24 & 7), foreground = Int(cell >> 21 & 7)
                        if background != 0 { context.fill(Path(rect), with: .color(Self.palette[background])) }
                        let body = cell & 0x1FFFFF
                        if cell >> 27 & 1 == 1 {
                            for bit in 0..<6 where body >> UInt32(bit) & 1 == 1 {
                                let cw = w / 2, ch = h / 3
                                let dot = CGRect(x: rect.minX + CGFloat(bit % 2) * cw, y: rect.minY + CGFloat(bit / 2) * ch, width: cw + 0.3, height: ch + 0.3)
                                context.fill(Path(dot), with: .color(Self.palette[foreground]))
                            }
                        } else if body > 32, let scalar = UnicodeScalar(body) {
                            context.draw(Text(String(Character(scalar))).font(.system(size: h * 0.95, design: .monospaced)).foregroundStyle(Self.palette[foreground]),
                                         at: CGPoint(x: rect.midX, y: rect.midY))
                        }
                    }
                }
            }
            .aspectRatio(1.25, contentMode: .fit)
            .background(Color.black)
            .overlay {
                if !have {
                    Text("Page \(page) has not arrived. Teletext comes from the playing channel.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { index in
                    Button {
                        if links[index] >= 100 { go(Int(links[index])) }
                    } label: {
                        RoundedRectangle(cornerRadius: 6).fill(Self.linkColours[index].opacity(links[index] >= 100 ? 0.9 : 0.2)).frame(height: 26)
                    }
                }
            }
            HStack {
                Button { go(page - 1) } label: { Image(systemName: "chevron.left") }
                TextField("Page", text: $typed)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.body.monospacedDigit())
                    .onChange(of: typed) { _, new in
                        if new.count == 3, let number = Int(new) {
                            go(number)
                            typed = ""
                        }
                    }
                Button { go(page + 1) } label: { Image(systemName: "chevron.right") }
            }
            .padding(.horizontal)
        }
        .padding(10)
        .onAppear(perform: load)
        .onReceive(tick) { _ in load() }
    }

    private func go(_ number: Int) {
        page = min(max(number, 100), 899)
        load()
    }

    private func load() {
        var grid = [UInt32](repeating: 0, count: 1000)
        var next = [Int32](repeating: 0, count: 4)
        have = onair_teletext_page(Int32(page), &grid, &next)
        if have {
            cells = grid
            links = next
        }
    }
}

/// Steps through the channels of the region plan, at each channel's own width, and keeps what it finds.
private struct ScanView: View {
    private enum Reception: String, CaseIterable, Identifiable {
        case antenna = "Antenna", cable = "Cable", atsc = "ATSC"
        var id: Self { self }
        var modeName: String { self == .antenna ? "DVB" : self == .cable ? "DVB-C" : "ATSC" }
    }

    let receiver: Receiver
    let state: TVState
    let picked: () -> Void
    @AppStorage("tvReception") private var reception = Reception.antenna
    @AppStorage("tvFound") private var foundText = "[]"
    @State private var plan = ChannelPlan()
    @State private var index: Int?
    @State private var dwell = 0
    @State private var tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let settleSeconds = 12
    private static let dwellSeconds = 6

    private var found: [ScannedMux] { ScannedMux.saved(foundText) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Picker("Reception", selection: $reception) {
                    ForEach(Reception.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: reception) { _, new in
                    _ = onair_mode_select_named(new.modeName)
                    receiver.refresh()
                    reload()
                }
                Menu {
                    ForEach(plan.plans) { item in
                        Button(item.name) {
                            onair_channel_plan_set(item.id)
                            reload()
                        }
                    }
                } label: {
                    HStack {
                        Text("Region").foregroundStyle(.secondary)
                        Spacer()
                        Text(plan.planName).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .padding(10)
                    .background(TV.card, in: RoundedRectangle(cornerRadius: 12))
                }
                Button(index == nil ? "Scan \(plan.channels.count) channels" : "Stop", action: toggle)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(11)
                    .background(TV.accent, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                    .disabled(plan.channels.isEmpty)
                if let index, plan.channels.indices.contains(index) {
                    ProgressView(value: Double(index), total: Double(plan.channels.count))
                    Text(String(format: "Channel %@, %.1f MHz", plan.channels[index].label, plan.channels[index].mhz)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                ForEach(found) { mux in
                    Button {
                        onair_channel_pick(mux.mhz, mux.bandwidth)
                        picked()
                        receiver.refresh()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(format: "Channel %@, %.1f MHz", mux.label, mux.mhz)).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(TV.accent)
                            Text(mux.names.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(TV.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding(12)
        }
        .onAppear(perform: reload)
        .onReceive(tick) { _ in step() }
    }

    private func reload() { plan = ChannelPlan.current() }

    private func tune(_ channel: ChannelPlan.Channel) {
        onair_channel_pick(channel.mhz, channel.bandwidth)
        receiver.refresh()
    }

    private func toggle() {
        if index != nil {
            index = nil
            return
        }
        if !receiver.status.running { receiver.startStop() }
        foundText = "[]"
        dwell = 0
        index = 0
        tune(plan.channels[0])
    }

    /// Waits on each channel for its service list, keeps it if there is one, then moves on.
    private func step() {
        guard let current = index, plan.channels.indices.contains(current) else { return }
        dwell += 1
        let channel = plan.channels[current]
        // names come first, the channel numbers later: stay until they are in, or give up and keep what there is
        let named = !state.services.isEmpty && state.services.allSatisfy { !$0.name.isEmpty }
        let numbered = state.services.contains { $0.lcn > 0 }
        if !state.services.isEmpty && ((named && numbered && dwell >= 3) || dwell >= Self.settleSeconds) {
            var list = found
            list.removeAll { $0.mhz == channel.mhz }
            list.append(ScannedMux(mhz: channel.mhz, label: channel.label, bandwidth: channel.bandwidth, names: state.services.map { $0.name.isEmpty ? "Service \($0.id)" : $0.name }, channels: state.services.map { ScannedMux.Channel(name: $0.name.isEmpty ? "Service \($0.id)" : $0.name, lcn: $0.lcn, radio: $0.isRadio) }))
            if let data = try? JSONEncoder().encode(list) { foundText = String(decoding: data, as: UTF8.self) }
            advance(from: current)
        } else if state.services.isEmpty && dwell >= Self.dwellSeconds {
            advance(from: current)
        }
    }

    private func advance(from current: Int) {
        dwell = 0
        guard current + 1 < plan.channels.count else {
            index = nil
            return
        }
        index = current + 1
        tune(plan.channels[current + 1])
    }
}
