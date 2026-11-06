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

/// An analog meter: the needle swings on a spring as the value changes.
struct NeedleMeter: View {
    let title: String
    let value: Double   // 0...1
    let scale: [String]

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height * 1.05)
            let radius = size.height * 0.92
            let start = Angle.degrees(-145), end = Angle.degrees(-35)
            func point(_ fraction: Double, _ length: Double) -> CGPoint {
                let a = start.radians + (end.radians - start.radians) * fraction
                return CGPoint(x: centre.x + cos(a) * length, y: centre.y + sin(a) * length)
            }
            var arc = Path()
            arc.addArc(center: centre, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            context.stroke(arc, with: .color(RadioTheme.amber.opacity(0.75)), lineWidth: 1.5)
            for tick in 0...20 {
                let fraction = Double(tick) / 20
                var line = Path()
                line.move(to: point(fraction, radius))
                line.addLine(to: point(fraction, radius - (tick % 5 == 0 ? 11 : 5)))
                context.stroke(line, with: .color(RadioTheme.amber.opacity(tick % 5 == 0 ? 0.95 : 0.5)), lineWidth: tick % 5 == 0 ? 1.5 : 1)
            }
            for (index, text) in scale.enumerated() {
                let fraction = Double(index) / Double(max(scale.count - 1, 1))
                context.draw(Text(text).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(RadioTheme.amber.opacity(0.85)), at: point(fraction, radius - 22))
            }
        }
        .overlay {
            GeometryReader { geometry in
                let height = geometry.size.height
                Capsule()
                    .fill(Color.white)
                    .frame(width: 2, height: height * 0.9)
                    .shadow(color: .black.opacity(0.7), radius: 2, x: 1)
                    .position(x: geometry.size.width / 2, y: height * 1.05 - height * 0.45)
                    .rotationEffect(.degrees(-55 + 110 * value), anchor: UnitPoint(x: 0.5, y: 1.05))
                    .animation(.interpolatingSpring(stiffness: 70, damping: 9), value: value)
            }
        }
        .overlay(alignment: .bottom) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(RadioTheme.amber.opacity(0.7))
                .padding(.bottom, 4)
        }
        .background(RadioTheme.glass)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.25), lineWidth: 1))
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
        .background(RadioTheme.glass)
        .overlay {
            Rectangle().fill(Color.red).frame(width: 2).shadow(color: .red, radius: 5)
        }
        .overlay {
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .clear, location: 0.18), .init(color: .clear, location: 0.82), .init(color: .black, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.25), lineWidth: 1))
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

/// A heavy tuning knob: turn it with one finger, it clicks at every step.
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
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: [Color(white: 0.34), Color(white: 0.13), Color(white: 0.3), Color(white: 0.11), Color(white: 0.34)], center: .center))
                    .shadow(color: .black, radius: 12, y: 8)
                Circle()
                    .stroke(Color(white: 0.45), lineWidth: 1)
                ForEach(0..<40, id: \.self) { tooth in
                    Capsule()
                        .fill(Color(white: 0.04))
                        .frame(width: 3, height: 8)
                        .offset(y: -size / 2 + 6)
                        .rotationEffect(.degrees(Double(tooth) * 9))
                }
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.27), Color(white: 0.13)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 2, endRadius: size / 2))
                    .padding(size * 0.14)
                Circle()
                    .fill(RadioTheme.amber)
                    .frame(width: 11, height: 11)
                    .shadow(color: RadioTheme.amber, radius: 6)
                    .offset(y: -size * 0.27)
            }
            .rotationEffect(.degrees(angle))
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
