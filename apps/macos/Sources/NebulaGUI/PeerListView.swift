import SwiftUI
import NebulaClient

struct PeerListView: View {
    let peers: [KnownPeer]
    let canProbe: Bool
    let probeBusy: Bool
    let probe: NodeProbe?
    var latency = LatencyHistory()
    var monitoring = false
    @Binding var expanded: Set<String>
    let copy: (String) -> Void
    let test: (String) -> Void
    @State private var query = ""
    @State private var filter: PeerFilter = .all
    @State private var limit = 50
    private var matching: [KnownPeer] { PeerQuery.matching(peers, text: query, filter: filter) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本机已知节点").font(.subheadline.weight(.medium))
                Spacer()
                Text("\(peers.count) 条记录").foregroundStyle(.secondary)
            }
            Text("来源于本机隧道记录，活动或待握手均不代表远端在线。").foregroundStyle(.secondary)
            if !peers.isEmpty {
                TextField("搜索设备名或地址", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索已知节点")
                Picker("隧道记录筛选", selection: $filter) {
                    ForEach(PeerFilter.allCases) { item in Text(item.title).tag(item) }
                }.pickerStyle(.segmented)
            }
            let results = matching
            if results.isEmpty {
                Text(peers.isEmpty ? "当前没有隧道记录。这不代表其他设备离线。" : "没有匹配的节点，试试其他名称或地址。")
                    .foregroundStyle(.secondary).padding(.vertical, 8)
                if !peers.isEmpty {
                    Button("清除搜索和筛选") { query = ""; filter = .all }
                }
            } else {
                ForEach(Array(results.prefix(limit))) { peer in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .top) {
                            Text(peer.name.isEmpty ? "未知名称" : peer.name).fontWeight(.medium).lineLimit(2)
                            Spacer()
                            Text(peer.pending ? "待握手" : "活动隧道").foregroundStyle(.secondary)
                        }
                        ForEach(peer.addresses, id: \.self) { address in
                          VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(address).monospaced().textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading).help(address)
                                if monitoring && !peer.pending { latencyCell(address) }
                                CopyAddressButton(address: address, label: "复制节点地址 \(address)") { copy(address) }
                                Button { test(address) } label: { Label("测试", systemImage: "waveform.path.ecg").frame(minHeight: 40) }
                                    .disabled(!canProbe || probeBusy).help("测试 \(address)")
                                    .accessibilityLabel("测试节点 \(address)")
                            }
                            if let probe, probe.address == address { ProbeFeedback(probe: probe, showsAddress: false) }
                            if monitoring && !peer.pending && expanded.contains(address) {
                                LatencyDetail(points: latency.points(for: address), stats: latency.stats(for: address))
                            }
                          }
                        }
                    }.padding(.vertical, 6)
                    Divider()
                }
                HStack {
                    Text("显示 \(min(limit, results.count))／\(results.count) 条匹配记录").foregroundStyle(.secondary)
                    Spacer()
                    if results.count > limit { Button("加载更多") { limit += 50 } }
                    if !query.isEmpty || filter != .all { Button("清除筛选") { query = ""; filter = .all } }
                }
            }
        }.font(.caption)
        .onChange(of: query) { value in limit = 50; if value.count > 256 { query = String(value.prefix(256)) } }
        .onChange(of: filter) { _ in limit = 50 }
    }
    /// Latest value and a five-minute sparkline; the chevron opens the detailed chart.
    private func latencyCell(_ address: String) -> some View {
        let points = latency.points(for: address)
        let latest = points.last
        let grade = LatencyGrade.of(latest?.ms ?? nil)
        let open = expanded.contains(address)
        return Button {
            if open { expanded.remove(address) } else { expanded.insert(address) }
        } label: {
            HStack(spacing: 8) {
                Text(latest.map { latencyText($0.ms) } ?? "采样中")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(latest == nil ? Color.secondary : grade.color)
                    .frame(width: 58, alignment: .trailing)
                LatencySparkline(points: points, color: grade.color).frame(width: 120, height: 26)
                Image(systemName: open ? "chevron.up" : "chevron.down").foregroundStyle(.secondary).frame(width: 12)
            }.frame(minHeight: 40)
        }
        .buttonStyle(PressStyle())
        .help(open ? "收起延迟详情" : "查看延迟详情")
        .accessibilityLabel("\(address) 延迟 \(latest.map { latencyText($0.ms) } ?? "采样中")，\(open ? "收起" : "展开")详情")
    }
}
