import OnAirCore
import SwiftUI

/// A TV guide: channels down the side, the day across the top in half hours, a bar for each programme and a line for now.
struct TVGuide: View {
    struct Event: Decodable, Identifiable {
        var id: Int64 { start }
        let start: Int64
        let duration: Int
        let title, text, extended: String
        var end: Int64 { start + Int64(duration) }
    }

    private struct Chosen: Identifiable {
        var id: Int64 { event.start }
        let event: Event
        let service: TVState.Service
    }

    let state: TVState
    @State private var events: [Int: [Event]] = [:]
    @State private var day = 0
    @State private var now = Date()
    @State private var scroll = CGPoint.zero
    @State private var chosen: Chosen?
    @State private var tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private static let perMinute: CGFloat = 4     // 30 minutes are 120 points
    private static let rowHeight: CGFloat = 54
    private static let channelWidth: CGFloat = 92
    private static let headerHeight: CGFloat = 26
    private static var dayWidth: CGFloat { 24 * 60 * perMinute }
    private static let calendar = Calendar.current

    private var dayStart: Date { Self.calendar.date(byAdding: .day, value: day, to: Self.calendar.startOfDay(for: now)) ?? now }

    private var lastDay: Int {
        let today = Self.calendar.startOfDay(for: now)
        let last = events.values.flatMap { $0 }.map(\.end).max() ?? 0
        let span = Self.calendar.dateComponents([.day], from: today, to: Date(timeIntervalSince1970: TimeInterval(last))).day ?? 0
        return min(max(span, 0), 7)
    }

    private func dayName(_ offset: Int) -> String {
        if offset == 0 { return "Today" }
        if offset == 1 { return "Tomorrow" }
        let date = Self.calendar.date(byAdding: .day, value: offset, to: now) ?? now
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(0...lastDay, id: \.self) { offset in
                        Button(dayName(offset)) { day = offset }
                            .font(.footnote.weight(day == offset ? .semibold : .regular))
                            .foregroundStyle(day == offset ? Color.white : Color.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(day == offset ? TV.accent.opacity(0.5) : TV.card, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            if state.services.isEmpty {
                message("Waiting for channels…")
            } else if events.values.allSatisfy(\.isEmpty) {
                message("Waiting for the guide. Stations send it every few seconds to a few minutes.")
            } else {
                grid
            }
        }
        .onAppear(perform: load)
        .onChange(of: state.services.count) { load() }
        .onReceive(tick) { _ in now = Date(); load() }
        .sheet(item: $chosen) { detail($0) }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        let height = Self.headerHeight + CGFloat(state.services.count) * Self.rowHeight
        return ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    // half an hour of the past stays in view
                    ScrollerJump(x: nowX - 30 * Self.perMinute - Self.channelWidth, token: day) { scroll = $0 }.frame(width: 1, height: 1)
                    rows.offset(x: Self.channelWidth, y: Self.headerHeight)
                    if day == 0 {
                        Rectangle().fill(Color.red).frame(width: 2, height: height).offset(x: nowX).allowsHitTesting(false)
                    }
                    timeline.offset(x: Self.channelWidth, y: max(scroll.y, 0)).zIndex(2)
                    channels.offset(x: max(scroll.x, 0), y: Self.headerHeight).zIndex(3)
                    Text(dayName(day))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: Self.channelWidth, height: Self.headerHeight)
                        .background(TV.background)
                        .offset(x: max(scroll.x, 0), y: max(scroll.y, 0))
                        .zIndex(4)
                }
                .frame(width: Self.channelWidth + Self.dayWidth, height: height, alignment: .topLeading)
            }
    }

    private var nowX: CGFloat {
        guard day == 0 else { return Self.channelWidth + 6 * 60 * Self.perMinute }   // another day opens at 6 in the morning
        return Self.channelWidth + CGFloat(now.timeIntervalSince(dayStart) / 60) * Self.perMinute
    }

    private var timeline: some View {
        HStack(spacing: 0) {
            ForEach(0..<48, id: \.self) { slot in
                HStack(spacing: 4) {
                    Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1)
                    Text((Self.calendar.date(byAdding: .minute, value: slot * 30, to: dayStart) ?? now).formatted(date: .omitted, time: .shortened))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(width: 30 * Self.perMinute, height: Self.headerHeight)
            }
        }
        .background(TV.background)
    }

    private var channels: some View {
        VStack(spacing: 0) {
            ForEach(state.services) { service in
                Button {
                    onair_tv_play(Int32(service.id))
                } label: {
                    Text(service.name)
                        .font(.caption.weight(service.id == state.selected ? .bold : .medium))
                        .foregroundStyle(service.id == state.selected ? TV.accent : .white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 8)
                        .frame(width: Self.channelWidth, height: Self.rowHeight, alignment: .leading)
                        .background(TV.background)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
                }
            }
        }
    }

    private var rows: some View {
        let start = Int64(dayStart.timeIntervalSince1970), end = start + 86400
        return VStack(spacing: 0) {
            ForEach(state.services) { service in
                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach((events[service.id] ?? []).filter { $0.end > start && $0.start < end }) { event in
                        bar(event, service, start: start, end: end)
                    }
                }
                .frame(width: Self.dayWidth, height: Self.rowHeight)
            }
        }
    }

    private func bar(_ event: Event, _ service: TVState.Service, start: Int64, end: Int64) -> some View {
        let from = max(event.start, start), to = min(event.end, end)
        let width = CGFloat(to - from) / 60 * Self.perMinute
        let time = Int64(now.timeIntervalSince1970)
        let playing = time >= event.start && time < event.end
        let progress = playing ? CGFloat(time - event.start) / CGFloat(max(event.duration, 1)) : 0
        return Button {
            chosen = Chosen(event: event, service: service)
        } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(event.end <= time ? TV.card.opacity(0.5) : TV.card)
                if playing {   // the programme so far, growing to the right
                    RoundedRectangle(cornerRadius: 5).fill(TV.accent.opacity(0.4)).frame(width: width * progress)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title).font(.caption.weight(.semibold)).foregroundStyle(event.end <= time ? Color.secondary : Color.white)
                    Text(clock(event.start)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(width: max(width - 2, 0), alignment: .leading)
                .clipped()
            }
            .frame(width: max(width - 2, 1), height: Self.rowHeight - 4)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(playing ? TV.accent : Color.white.opacity(0.1), lineWidth: 1))
        }
        .offset(x: CGFloat(from - start) / 60 * Self.perMinute, y: 2)
    }

    private func clock(_ seconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .omitted, time: .shortened)
    }

    private func detail(_ item: Chosen) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.service.name).font(.footnote).foregroundStyle(TV.accent)
                Text(item.event.title).font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text("\(clock(item.event.start)) to \(clock(item.event.end)), \(item.event.duration / 60) min").font(.footnote).foregroundStyle(.secondary)
                let about = item.event.extended.isEmpty ? item.event.text : item.event.extended
                if !about.isEmpty { Text(about).font(.body).foregroundStyle(.white) }
                Button("Watch \(item.service.name)") {
                    onair_tv_play(Int32(item.service.id))
                    chosen = nil
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(TV.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }

    private func load() {
        var loaded: [Int: [Event]] = [:]
        for service in state.services { loaded[service.id] = tvDecode([Event].self, onair_epg_json(Int32(service.id))) ?? [] }
        events = loaded
    }
}

/// Moves the scroll view around it once for each token, and reports where it is. SwiftUI's scrollTo does not move a view that scrolls both ways.
private struct ScrollerJump: UIViewRepresentable {
    let x: CGFloat
    let token: Int
    let moved: (CGPoint) -> Void

    final class Coordinator {
        var done: Int?
        var watching: NSKeyValueObservation?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ view: UIView, context: Context) {
        guard context.coordinator.done != token else { return }
        context.coordinator.done = token
        jump(view, attempts: 10, context.coordinator)
    }

    private func jump(_ view: UIView, attempts: Int, _ coordinator: Coordinator) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            var parent = view.superview
            while let current = parent, !(current is UIScrollView) { parent = current.superview }
            guard let scroller = parent as? UIScrollView, scroller.contentSize.width > scroller.bounds.width else {
                if attempts > 0 { jump(view, attempts: attempts - 1, coordinator) }
                return
            }
            if coordinator.watching == nil {
                let moved = moved
                coordinator.watching = scroller.observe(\.contentOffset, options: [.initial, .new]) { scroller, _ in
                    let offset = scroller.contentOffset
                    DispatchQueue.main.async { moved(offset) }
                }
            }
            let most = scroller.contentSize.width - scroller.bounds.width
            scroller.setContentOffset(CGPoint(x: min(max(x, 0), most), y: scroller.contentOffset.y), animated: false)
        }
    }
}
