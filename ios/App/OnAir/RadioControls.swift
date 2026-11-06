import CoreMotion
import SwiftUI
import UIKit

/// The look shared by the custom radio controls: dark metal, OnAir's teal, warm amber for anything that glows.
enum RadioTheme {
    static let amber = Color(red: 1.0, green: 0.71, blue: 0.28)
    static let teal = Color(red: 0.45, green: 0.72, blue: 0.82)
    static let panel = LinearGradient(colors: [Color(white: 0.17), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
    static let glass = Color(red: 0.05, green: 0.045, blue: 0.03)
}

/// A clicking feel for dials: one light tick for each step.
@MainActor final class DetentHaptics {
    private let generator = UISelectionFeedbackGenerator()
    func tick() {
        generator.selectionChanged()
        generator.prepare()
    }
}

/// A status lamp that lights up with a soft glow.
struct RadioLamp: View {
    let label: String
    let lit: Bool
    var colour = RadioTheme.amber

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(lit ? colour : Color(white: 0.2))
                .frame(width: 7, height: 7)
                .shadow(color: lit ? colour : .clear, radius: 5)
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1)
                .foregroundStyle(lit ? colour : Color(white: 0.35))
        }
        .animation(.easeOut(duration: 0.25), value: lit)
    }
}

/// The sliding band scale of an old receiver: drag it and the band moves under a fixed needle.
struct BandScale: View {
    let mhz: Double
    let lowMhz: Double
    let highMhz: Double
    let stepMhz: Double
    let tune: (Double) -> Void
    private let pointsPerMhz = 34.0
    @State private var dragStart: Double?
    @State private var haptics = DetentHaptics()

    var body: some View {
        Canvas { context, size in
            let middle = size.width / 2
            let firstTick = Int(((mhz - Double(size.width) / 2 / pointsPerMhz) * 5).rounded(.down))
            let lastTick = Int(((mhz + Double(size.width) / 2 / pointsPerMhz) * 5).rounded(.up))
            for tick in firstTick...lastTick {
                let value = Double(tick) / 5
                guard value >= lowMhz, value <= highMhz else { continue }
                let x = middle + (value - mhz) * pointsPerMhz
                let major = tick % 5 == 0
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height - 8))
                line.addLine(to: CGPoint(x: x, y: size.height - (major ? 24 : 16)))
                context.stroke(line, with: .color(RadioTheme.amber.opacity(major ? 0.95 : 0.45)), lineWidth: major ? 1.5 : 1)
                if major {
                    context.draw(Text(String(format: "%.0f", value)).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(RadioTheme.amber),
                                 at: CGPoint(x: x, y: 14))
                }
            }
        }
        .background(LinearGradient(colors: [Color(red: 0.2, green: 0.11, blue: 0.03), RadioTheme.glass], startPoint: .bottom, endPoint: .top))
        .overlay {
            Rectangle().fill(Color.red).frame(width: 2).shadow(color: .red, radius: 5)
        }
        .overlay {
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .clear, location: 0.18), .init(color: .clear, location: 0.82), .init(color: .black, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(LinearGradient(colors: [.black, .white.opacity(0.4)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1).onChanged { value in
                let start = dragStart ?? mhz
                dragStart = start
                let wanted = start - value.translation.width / pointsPerMhz
                let snapped = min(max((wanted / stepMhz).rounded() * stepMhz, lowMhz), highMhz)
                if abs(snapped - mhz) >= stepMhz / 2 {
                    haptics.tick()
                    tune(snapped)
                }
            }
            .onEnded { _ in dragStart = nil }
        )
    }
}

/// Where the light is. It follows the tilt of the phone, so metal highlights move as they would on a real object.
@MainActor @Observable final class TiltLight {
    static let shared = TiltLight()
    private(set) var offset = CGPoint.zero
    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            MainActor.assumeIsolated {
            guard let self, let gravity = data?.gravity else { return }
            self.offset = CGPoint(x: min(max(gravity.x, -1), 1), y: min(max(gravity.y + 0.6, -1), 1))
            }
        }
    }

    var vector: Shader.Argument { .float2(Float(offset.x), Float(offset.y)) }
}

/// A sheet of brushed aluminium.
struct BrushedMetal: View {
    var tone: Float = 0.5
    var body: some View {
        GeometryReader { geometry in
            Rectangle().colorEffect(ShaderLibrary.brushedMetal(.float2(geometry.size), TiltLight.shared.vector, .float(tone)))
        }
    }
}

/// A slotted screw, sunk into the plate.
struct PanelScrew: View {
    let slot: Double
    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.75)).padding(-1.5)
            GeometryReader { geometry in
                Rectangle().colorEffect(ShaderLibrary.spunMetal(.float2(geometry.size), .float(0), TiltLight.shared.vector, .float(0.55)))
            }
            Capsule().fill(Color.black.opacity(0.85)).frame(height: 2).padding(.horizontal, 1).rotationEffect(.degrees(slot))
        }
        .frame(width: 12, height: 12)
    }
}

/// A plate with a screw in each corner: the body of the radio.
struct FacePlate<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            BrushedMetal(tone: 0.46)
            content
            VStack {
                HStack { PanelScrew(slot: 25); Spacer(); PanelScrew(slot: 110) }
                Spacer()
                HStack { PanelScrew(slot: 70); Spacer(); PanelScrew(slot: 160) }
            }
            .padding(5)
            .allowsHitTesting(false)
        }
    }
}

/// A window cut into the plate: dark glass, a shadow from the plate edge, and a reflection across the top.
struct GlassWindow<Content: View>: View {
    var corner: CGFloat = 8
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(RadioTheme.glass)
            .overlay {
                LinearGradient(colors: [.white.opacity(0.1), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .overlay {
                RoundedRectangle(cornerRadius: corner).strokeBorder(LinearGradient(colors: [.black, .black.opacity(0.7), .white.opacity(0.4)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
            }
    }
}

/// Text cut into the metal.
struct EngravedLabel: View {
    let text: String
    var size: CGFloat = 9
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .tracking(1.6)
            .foregroundStyle(Color(white: 0.09))
            .shadow(color: .white.opacity(0.45), radius: 0, y: 0.8)
    }
}

/// A machined push button with an LED above its label. It really moves when pressed.
struct HardwareKey<Label: View>: View {
    var lit = false
    var led = RadioTheme.amber
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 4) {
            Capsule()
                .fill(lit ? led : Color(white: 0.11))
                .frame(width: 18, height: 3)
                .shadow(color: lit ? led : .clear, radius: 5)
                .overlay(Capsule().stroke(Color.black.opacity(0.6), lineWidth: 0.5))
            label
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            GeometryReader { geometry in
                Rectangle().colorEffect(ShaderLibrary.brushedMetal(.float2(geometry.size), TiltLight.shared.vector, .float(pressed ? 0.45 : 0.62)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(LinearGradient(colors: [.white.opacity(pressed ? 0.15 : 0.6), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .shadow(color: .black.opacity(pressed ? 0.35 : 0.75), radius: pressed ? 1 : 4, y: pressed ? 1 : 4)
        .offset(y: pressed ? 2 : 0)
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55)))
        .animation(.easeOut(duration: 0.07), value: pressed)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
                    pressed = true
                }
                .onEnded { value in
                    pressed = false
                    if abs(value.translation.width) < 30, abs(value.translation.height) < 30 { action() }
                }
        )
    }
}

/// A backlit analog meter on warm paper, with a red needle that swings on a spring.
struct NeedleMeter: View {
    let title: String
    let value: Double   // 0...1
    let scale: [String]

    var body: some View {
        GlassWindow {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack {
                    Rectangle().colorEffect(ShaderLibrary.meterFace(.float2(size), .float(1)))
                    Canvas { context, size in
                        let centre = CGPoint(x: size.width / 2, y: size.height * 1.12)
                        let radius = size.height * 0.92
                        let start = Angle.degrees(-140).radians, end = Angle.degrees(-40).radians
                        func point(_ fraction: Double, _ length: Double) -> CGPoint {
                            let a = start + (end - start) * fraction
                            return CGPoint(x: centre.x + cos(a) * length, y: centre.y + sin(a) * length)
                        }
                        let ink = Color(red: 0.13, green: 0.08, blue: 0.04)
                        for tick in 0...20 {
                            let fraction = Double(tick) / 20
                            var line = Path()
                            line.move(to: point(fraction, radius))
                            line.addLine(to: point(fraction, radius - (tick % 5 == 0 ? 11 : 6)))
                            context.stroke(line, with: .color(fraction > 0.75 ? Color(red: 0.7, green: 0.1, blue: 0.06) : ink), lineWidth: tick % 5 == 0 ? 1.6 : 0.9)
                        }
                        for (index, text) in scale.enumerated() {
                            context.draw(Text(text).font(.system(size: 10, weight: .semibold, design: .serif)).foregroundStyle(ink),
                                         at: point(Double(index) / Double(max(scale.count - 1, 1)), radius - 21))
                        }
                        context.draw(Text(title).font(.system(size: 9, weight: .bold, design: .serif)).foregroundStyle(ink.opacity(0.8)), at: CGPoint(x: size.width / 2, y: size.height * 0.72))
                    }
                    Rectangle()
                        .fill(LinearGradient(colors: [Color(red: 0.86, green: 0.1, blue: 0.05), Color(red: 0.5, green: 0.04, blue: 0.02)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 1.6, height: size.height * 0.98)
                        .shadow(color: .black.opacity(0.45), radius: 1.5, x: 2, y: 1)
                        .position(x: size.width / 2, y: size.height * 1.12 - size.height * 0.49)
                        .rotationEffect(.degrees(-50 + 100 * value), anchor: UnitPoint(x: 0.5, y: 1.12))
                        .animation(.interpolatingSpring(stiffness: 70, damping: 9), value: value)
                }
            }
        }
    }
}

/// A heavy tuning knob: a ridged skirt under a spun metal cap. Turn it with one finger and it clicks at every step.
struct TuningKnob: View {
    let stepsPerTurn: Double
    let turned: (Int) -> Void
    @State private var angle = 0.0
    @State private var lastTouchAngle: Double?
    @State private var remainder = 0.0
    @State private var haptics = DetentHaptics()

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let radians = Float(angle * .pi / 180)
            ZStack {
                Circle().fill(Color.black.opacity(0.75)).blur(radius: 14).offset(y: 12).padding(-2)
                Circle().fill(Color.black).padding(-4)
                Rectangle()
                    .colorEffect(ShaderLibrary.knurledMetal(.float2(size, size), .float(radians), TiltLight.shared.vector))
                Circle().fill(Color.black.opacity(0.55)).padding(size * 0.095).blur(radius: 3)
                Rectangle()
                    .frame(width: size * 0.8, height: size * 0.8)
                    .colorEffect(ShaderLibrary.spunMetal(.float2(size * 0.8, size * 0.8), .float(radians), TiltLight.shared.vector, .float(0.72)))
                Capsule()
                    .fill(Color.white)
                    .frame(width: 3, height: size * 0.11)
                    .overlay(Capsule().stroke(Color.black.opacity(0.5), lineWidth: 0.5))
                    .offset(y: -size * 0.31)
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: size, height: size)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let dx = value.location.x - geometry.size.width / 2, dy = value.location.y - geometry.size.height / 2
                    let touch = atan2(dy, dx) * 180 / .pi
                    defer { lastTouchAngle = touch }
                    guard let last = lastTouchAngle else { return }
                    var delta = touch - last
                    if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                    angle += delta
                    remainder += delta
                    let perStep = 360 / stepsPerTurn
                    let steps = Int((remainder / perStep).rounded(.towardZero))
                    if steps != 0 {
                        remainder -= Double(steps) * perStep
                        haptics.tick()
                        turned(steps)
                    }
                }
                .onEnded { _ in lastTouchAngle = nil }
            )
        }
    }
}
