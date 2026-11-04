import SwiftUI
import NebulaClient

struct RenameNetworkView: View {
    @ObservedObject var model: AppModel
    let profile: NetworkProfile
    @State private var name: String
    @FocusState private var focused: Bool
    init(model: AppModel, profile: NetworkProfile) {
        self.model = model; self.profile = profile; _name = State(initialValue: profile.name)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("重命名网络").font(.title2.weight(.semibold))
            Text("只修改显示名称，设备身份、配置和当前连接保持不变。")
                .font(.callout).foregroundStyle(.secondary)
            TextField("网络名称", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            if let message = ProfileNameRules.validationMessage(name) { Text(message).font(.caption).foregroundStyle(.orange) }
            if let issue = model.problem { ProblemView(problem: issue) }
            HStack {
                Button("取消") { model.renameTarget = nil }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("保存名称") { Task { await model.renameProfile(profile.id, to: name) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.busy || ProfileNameRules.validationMessage(name) != nil || ProfileNameRules.normalized(name) == profile.name)
            }
        }.padding(28).frame(width: 430).tint(Palette.accent)
        .interactiveDismissDisabled(model.busy).onAppear { focused = true }
    }
}
