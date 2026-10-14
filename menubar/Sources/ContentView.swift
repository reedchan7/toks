import SwiftUI

struct ContentView: View {
    @ObservedObject var store: StatsStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var uiState: UIState
    @State private var showSettings = false

    var body: some View {
        Group {
            if showSettings {
                SettingsView(settings: settings) { showSettings = false }
            } else {
                mainView
            }
        }
        .onReceive(uiState.$showSettingsRequested) { requested in
            if requested {
                showSettings = true
                uiState.showSettingsRequested = false
            }
        }
    }

    private var mainView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Hide agents with no data entirely; settings-hidden are already excluded.
            let keys = settings.visibleOrder.filter { Self.hasData(store.stats?.agents[$0]) }
            if keys.isEmpty {
                Text("No data yet")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ReorderableList(keys: keys, showsDividers: true,
                                onCommit: settings.applyVisibleOrder) { key in
                    AgentRow(key: key, agent: store.stats?.agents[key], now: store.now)
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }

            if store.paused {
                HStack(spacing: 6) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 11))
                    Text("Paused")
                        .font(.system(size: 11))
                    Spacer()
                    Button { store.refreshNow() } label: {
                        Label("Refresh Now", systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    Button { store.setPaused(false) } label: {
                        Label("Resume", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                }
                .foregroundStyle(.secondary)
            }

            if store.readFailed {
                warning("cannot read stats.json — is the collector installed?")
            } else if store.collectorStale {
                warning("collector not running — run: bun collector/src/main.ts")
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    static func hasData(_ agent: AgentStats?) -> Bool {
        guard let agent else { return false }
        return agent.last != nil || agent.avg != nil
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.orange)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AgentRow: View {
    let key: String
    let agent: AgentStats?
    let now: Date

    var body: some View {
        if let agent {
            // Same layout for every state; staleness is conveyed by dimming and
            // an age suffix, never by collapsing the row.
            let stale = agent.state == .stale
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Inner center-aligned pair keeps the status dot on the
                    // label's vertical center regardless of the big number's
                    // baseline.
                    HStack(alignment: .center, spacing: 6) {
                        Circle()
                            .fill(accent)
                            .frame(width: 7, height: 7)
                        Text(agent.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(stale ? .secondary : .primary)
                            .fixedSize() // never wrap; names stay on one line
                    }
                    Spacer(minLength: 4)
                    let approx = agent.last?.approx == true
                    Text("\(approx && agent.last?.tokPerSec != nil ? "~" : "")\(formatTps(agent.last?.tokPerSec))")
                        .font(.title2.bold())
                        .monospacedDigit()
                        .foregroundStyle(stale ? .secondary : .primary)
                    Text(" tok/s")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Sparkline(points: agent.recent ?? [], color: accent, now: now)
                    .frame(height: 22)
                    .padding(.leading, 13)
                    .opacity(stale ? 0.45 : 1)
                let mark = agent.last?.approx == true && agent.last?.ttftMs != nil ? "~" : ""
                Text("Avg \(formatTps(agent.avg?.tokPerSec)) tok/s · TTFT \(mark)\(formatTtft(agent.last?.ttftMs)) · Avg \(formatTtft(agent.avg?.ttftMs))" + ageSuffix(agent, stale: stale))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(stale ? .tertiary : .secondary)
                    .padding(.leading, 13)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func ageSuffix(_ agent: AgentStats, stale: Bool) -> String {
        guard stale, let at = agent.last?.at else { return "" }
        return " · \(formatAge(msAgo: now.timeIntervalSince1970 * 1000 - Double(at))) ago"
    }

    private var accent: Color {
        switch agent?.state {
        case .active: .green
        case .recent: .orange // yellow is illegible on light backgrounds
        case .stale, nil: .gray
        }
    }
}

private struct Sparkline: View {
    let points: [RecentPoint]
    let color: Color
    let now: Date

    @State private var hover: (value: Double, at: Int64, pos: CGPoint)?

    private var valid: [(Int64, Double)] {
        // Sort defensively: the collector keeps windows time-ordered, but a
        // stale stats.json written before that fix may not be.
        points.compactMap { p in p.tokPerSec.map { (p.at, $0) } }.sorted { $0.0 < $1.0 }
    }

    private func mapper(_ size: CGSize) -> ((Int64, Double)) -> CGPoint? {
        let valid = self.valid
        guard valid.count >= 2,
              let minX = valid.map(\.0).min(), let maxX = valid.map(\.0).max(), maxX > minX,
              let minY = valid.map(\.1).min(), let maxY = valid.map(\.1).max() else { return { _ in nil } }
        let rangeY = max(maxY - minY, 0.001)
        return { p in
            CGPoint(
                x: Double(p.0 - minX) / Double(maxX - minX) * size.width,
                y: size.height - (p.1 - minY) / rangeY * (size.height - 3) - 1.5
            )
        }
    }

    var body: some View {
        GeometryReader { geo in
            let toPoint = mapper(geo.size)
            Canvas { context, size in
                let valid = self.valid
                guard valid.count >= 2 else { return }
                var line = Path()
                var started = false
                for p in valid {
                    guard let pt = toPoint(p) else { continue }
                    if started { line.addLine(to: pt) } else { line.move(to: pt); started = true }
                }
                guard started else { return }
                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.15), color.opacity(0.02)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(color.opacity(0.9)), lineWidth: 1.5)
                if let hover {
                    let dot = Path(ellipseIn: CGRect(x: hover.pos.x - 3, y: hover.pos.y - 3, width: 6, height: 6))
                    context.fill(dot, with: .color(color))
                    context.stroke(dot, with: .color(.white.opacity(0.9)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    // Snap to the nearest sample by x.
                    var best: (Double, Int64, CGPoint)? = nil
                    for p in valid {
                        guard let pt = toPoint(p) else { continue }
                        let d = abs(pt.x - location.x)
                        if best == nil || d < abs(best!.2.x - location.x) { best = (p.1, p.0, pt) }
                    }
                    hover = best.map { (value: $0.0, at: $0.1, pos: $0.2) }
                case .ended:
                    hover = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let hover {
                    let age = formatAge(msAgo: now.timeIntervalSince1970 * 1000 - Double(hover.at))
                    Text("\(Int(hover.value.rounded())) tok/s · \(age) ago")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.regularMaterial))
                        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                        .fixedSize()
                        .offset(x: min(max(hover.pos.x - 40, 0), max(geo.size.width - 80, 0)), y: 0)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

// Vertically draggable row list; order commits only on drop.
private struct ReorderableList<Content: View>: View {
    let keys: [String]
    let showsDividers: Bool
    let onCommit: ([String]) -> Void
    @ViewBuilder let row: (String) -> Content

    @State private var heights: [String: CGFloat] = [:]
    @State private var dragKey: String?
    @State private var dragStartOrder: [String] = []
    @State private var dragOrder: [String]?
    @State private var dragOffsetY: CGFloat = 0

    private var displayOrder: [String] { dragOrder ?? keys }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(displayOrder.enumerated()), id: \.element) { i, key in
                row(key)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: RowHeightKey.self, value: [key: geo.size.height])
                    })
                    .background {
                        if dragKey == key {
                            // Opaque lifted card: a translucent fill lets the rows
                            // underneath bleed through while dragging.
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
                        }
                    }
                    .offset(y: dragKey == key ? dragOffsetY : 0)
                    .zIndex(dragKey == key ? 2 : 0)
                    .scaleEffect(dragKey == key ? 1.03 : 1)
                    .gesture(drag(key))
                if showsDividers, dragKey == nil, i < displayOrder.count - 1 {
                    Divider().padding(.leading, 23) // hairline aligned to text
                }
            }
        }
        .onPreferenceChange(RowHeightKey.self) { heights = $0 }
    }

    private func drag(_ key: String) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if dragKey == nil {
                    dragKey = key
                    dragStartOrder = displayOrder
                    dragOrder = displayOrder
                }
                guard dragKey == key else { return }
                let (order, offset) = reorderTarget(startOrder: dragStartOrder, key: key,
                                                    translation: v.translation.height,
                                                    heights: heights)
                dragOffsetY = offset
                if order != dragOrder {
                    withAnimation(.easeInOut(duration: 0.15)) { dragOrder = order }
                }
            }
            .onEnded { _ in
                if let order = dragOrder, order != keys { onCommit(order) }
                withAnimation(.easeInOut(duration: 0.15)) {
                    dragKey = nil
                    dragOrder = nil
                    dragOffsetY = 0
                }
            }
    }
}

private struct RowHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: onDone) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Text("Settings").font(.headline)
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Text("Refresh interval")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Picker("", selection: $settings.settings.refreshSec) {
                Text("1s").tag(1)
                Text("2s").tag(2)
                Text("5s").tag(5)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text("Agents")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ReorderableList(keys: settings.settings.order, showsDividers: false,
                            onCommit: { settings.settings.order = $0 }) { key in
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(shortNames[key] ?? key)
                        .font(.system(size: 13))
                    Spacer()
                    Button { move(key, -1) } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(settings.settings.order.first == key)
                    Button { move(key, 1) } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(settings.settings.order.last == key)
                    Button { settings.toggleHidden(key) } label: {
                        Image(systemName: settings.settings.hidden.contains(key) ? "eye.slash" : "eye")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(settings.settings.hidden.contains(key) ? .tertiary : .secondary)
                    .help(settings.settings.hidden.contains(key) ? "Show" : "Hide")
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func move(_ key: String, _ delta: Int) {
        guard let i = settings.settings.order.firstIndex(of: key) else { return }
        let j = i + delta
        guard settings.settings.order.indices.contains(j) else { return }
        settings.settings.order.swapAt(i, j)
    }
}
