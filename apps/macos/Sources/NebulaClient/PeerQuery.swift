import Foundation

public enum PeerFilter: String, CaseIterable, Identifiable, Sendable {
    case all, active, pending
    public var id: String { rawValue }
    public var title: String {
        switch self { case .all: return "全部"; case .active: return "活动"; case .pending: return "待握手" }
    }
}
public enum PeerQuery {
    public static func matching(_ peers: [KnownPeer], text: String, filter: PeerFilter) -> [KnownPeer] {
        let terms = folded(String(text.prefix(256))).split(whereSeparator: \.isWhitespace).map(String.init)
        return peers.filter { peer in
            if filter == .active && peer.pending { return false }
            if filter == .pending && !peer.pending { return false }
            let searchable = folded(([peer.name] + peer.addresses).joined(separator: " "))
            return terms.allSatisfy { searchable.contains($0) }
        }.sorted { left, right in
            if left.pending != right.pending { return !left.pending }
            let order = left.name.localizedStandardCompare(right.name)
            if order != .orderedSame { return order == .orderedAscending }
            return left.id < right.id
        }
    }
    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
public enum ProfileNameRules {
    public static func normalized(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    public static func validationMessage(_ text: String) -> String? {
        let name = normalized(text)
        if name.isEmpty { return "请输入网络名称。" }
        if name.utf8.count > 160 { return "名称太长，请缩短后保存。" }
        if name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return "名称不能包含换行或控制字符。" }
        return nil
    }
}
