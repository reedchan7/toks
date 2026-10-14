import Foundation

struct StatsFile: Codable {
    let version: Int
    let updatedAt: Int64 // epoch ms
    let agents: [String: AgentStats]
}

struct AgentStats: Codable {
    enum State: String, Codable {
        case active, recent, stale
    }

    let label: String
    let state: State
    let model: String?
    let last: Sample?
    let avg: AvgStats?
    let recent: [RecentPoint]? // ascending by at, up to 30
    let today: TodayUsage? // nil when the collector is older than this field
}

struct TodayUsage: Codable {
    let date: String // YYYY-MM-DD, local
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheCreation: Int
    let total: Int
}

struct Sample: Codable {
    let ttftMs: Double?
    let tokPerSec: Double?
    let outputTokens: Int?
    let at: Int64 // epoch ms
    let approx: Bool
}

struct AvgStats: Codable {
    let ttftMs: Double?
    let tokPerSec: Double?
    let samples: Int
}

struct RecentPoint: Codable {
    let at: Int64 // epoch ms
    let ttftMs: Double?
    let tokPerSec: Double?
}

struct ToksSettings: Codable {
    var order: [String]
    var hidden: [String]
    var refreshSec: Int

    static let `default` = ToksSettings(order: agentOrder, hidden: [], refreshSec: 2)
}

let agentOrder = ["kimi", "claude", "codex", "dsh", "zcode", "pi"]

// Menu bar short names.
let shortNames = ["kimi": "Kimi", "claude": "Claude", "codex": "Codex",
                  "dsh": "DSH", "zcode": "ZCode", "pi": "Pi"]

let statsURL = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".local/share/toks/stats.json")
let settingsURL = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".local/share/toks/settings.json")

func formatTtft(_ ms: Double?) -> String {
    guard let ms else { return "—" }
    if ms < 1000 {
        return String(format: "%.0fms", ms)
    }
    return String(format: "%.1fs", ms / 1000)
}

func formatTps(_ tps: Double?) -> String {
    guard let tps else { return "—" }
    return String(format: "%.0f", tps)
}

func formatAge(msAgo: Double) -> String {
    let s = max(0, Int(msAgo / 1000))
    if s < 60 { return "\(s)s" }
    let m = s / 60
    if m < 60 { return "\(m)m" }
    let h = m / 60
    if h < 24 { return "\(h)h" }
    return "\(h / 24)d"
}

func formatTokens(_ n: Int) -> String {
    if n < 1_000 { return "\(n)" }
    if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    if n < 1_000_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    return String(format: "%.2fB", Double(n) / 1_000_000_000)
}

// Drag reorder: swap when the dragged row's center crosses a neighbor's center.
// Returns the working order plus the visual offset that keeps the dragged row
// under the pointer.
func reorderTarget(startOrder: [String], key: String, translation: CGFloat,
                   heights: [String: CGFloat], defaultHeight: CGFloat = 30) -> (order: [String], offset: CGFloat) {
    guard let origIdx = startOrder.firstIndex(of: key) else { return (startOrder, 0) }
    let own = heights[key] ?? defaultHeight
    var acc: CGFloat = 0
    var target = origIdx
    if translation > 0 {
        for j in (origIdx + 1)..<startOrder.count {
            let h = heights[startOrder[j]] ?? defaultHeight
            if translation > acc + own / 2 + h / 2 { target = j; acc += h } else { break }
        }
    } else if translation < 0 {
        for j in stride(from: origIdx - 1, through: 0, by: -1) {
            let h = heights[startOrder[j]] ?? defaultHeight
            if -translation > acc + own / 2 + h / 2 { target = j; acc += h } else { break }
        }
    }
    var order = startOrder
    if target != origIdx {
        let el = order.remove(at: origIdx)
        order.insert(el, at: target)
    }
    let offset = translation - (target > origIdx ? acc : target < origIdx ? -acc : 0)
    return (order, offset)
}

// Writes a reordered subset back into the full order, leaving keys outside the
// subset (hidden or data-less agents) pinned to their slots.
func mergedOrder(order: [String], visible: [String]) -> [String] {
    let set = Set(visible)
    var it = visible.makeIterator()
    return order.map { set.contains($0) ? (it.next() ?? $0) : $0 }
}
