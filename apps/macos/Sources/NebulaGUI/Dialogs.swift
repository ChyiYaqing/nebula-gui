import AppKit
import SwiftUI
import NebulaClient

struct ProblemView: View {
    let problem: BackendProblem
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 5) {
                Text(problem.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let field = problem.field { Text(field).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Palette.small))
        .accessibilityElement(children: .combine)
    }
}
struct ImportView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.replacementID == nil ? "检查并导入网络" : "更新网络配置").font(.title2.weight(.semibold))
            if model.busy { ProgressView("正在验证配置与设备身份…").padding(.vertical) }
            if let candidate = model.candidate {
                TextField("网络名称", text: $model.importName).textFieldStyle(.roundedBorder)
                if let message = ProfileNameRules.validationMessage(model.importName) { Text(message).font(.caption).foregroundStyle(.orange) }
                LabeledContent("设备", value: candidate.device)
                LabeledContent("Nebula 地址", value: candidate.networks.joined(separator: ", "))
                LabeledContent("有效期至", value: candidate.expiration?.formatted(date: .abbreviated, time: .omitted) ?? candidate.expiresAt)
                Label("配置、证书与密钥校验通过", systemImage: "checkmark.shield").foregroundStyle(Palette.accent)
                Text("保存独立副本，原始文件保持不变。更新配置会保留上一版供恢复。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue = model.problem {
                ProblemView(problem: issue)
                if issue.code == "missing_file", ["pki.ca", "pki.cert", "pki.key"].contains(issue.field ?? "") {
                    Button("补选对应文件") { model.supplementFile() }
                }
            }
            HStack {
                Button("取消") { model.importing = false; model.candidate = nil; model.problem = nil }.keyboardShortcut(.cancelAction)
                    .disabled(model.busy)
                Spacer()
                Button(model.replacementID == nil ? "保存网络" : "确认更新") { Task { await model.confirmImport() } }
                    .buttonStyle(.borderedProminent).disabled(model.busy || model.candidate == nil || ProfileNameRules.validationMessage(model.importName) != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 480).tint(Palette.accent).interactiveDismissDisabled(model.busy)
    }
}
struct AuthorizationReviewView: View {
    @ObservedObject var model: AppModel
    @State private var consent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(model.removingAuthorization ? "移除连接后台" : model.upgradingAuthorization ? (model.authorization.helperIsNewer ? "换回此版本的连接后台" : "升级连接后台") : "启用连接后台", systemImage: "lock.shield")
                .font(.title2.weight(.semibold))
            Text(model.removingAuthorization ? "将停止并移除 Nebula GUI 的网络组件。原始配置与应用保存的网络不会删除。" : model.upgradingAuthorization ? (model.authorization.helperIsNewer ? "已安装的网络组件来自较新的 Nebula。继续会把它换成此 App 自带的较旧版本，现有受管连接会中断，较新版本修复的问题可能重新出现；建议改为更新 Nebula。已保存的配置保留。" : "将重启并升级本应用的网络组件，现有受管连接会中断。失败时尝试恢复旧组件；已保存的配置保留。") : "安装仅供当前登录用户控制的 root 网络组件。GUI 保持普通用户身份，管理员密码仅在 macOS 系统窗口输入。")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Text("将写入／移除以下文件").font(.caption.weight(.semibold))
                Text(AuthorizationPlan.helperPath).textSelection(.enabled)
                Text(AuthorizationPlan.plistPath).textSelection(.enabled)
            }.font(.system(size: 11, design: .monospaced)).padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            if !model.removingAuthorization {
                Text("组件开机启动，但不会自动连接。只接受当前用户的连接、断开和查询请求；GUI 后台退出即清理隧道。旧 Nebula 服务若仍加载，安装会被拒绝。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(model.removingAuthorization ? "我同意停止并移除此组件" : model.upgradingAuthorization ? (model.authorization.helperIsNewer ? "我同意重启并换回较旧的网络组件" : "我同意重启并升级上述网络组件") : "我同意安装上述网络组件并授予系统权限", isOn: $consent)
                .toggleStyle(.checkbox)
            HStack {
                Button("取消") { model.showAuthorizationReview = false }.keyboardShortcut(.cancelAction)
                if !model.removingAuthorization {
                    Button("移除已有组件…") { model.removingAuthorization = true; model.upgradingAuthorization = false; consent = false }
                }
                Spacer()
                Button(model.removingAuthorization ? "授权移除" : model.upgradingAuthorization ? (model.authorization.helperIsNewer ? "授权换回" : "授权升级") : "授权安装") {
                    Task { await model.manageAuthorization(removing: model.removingAuthorization) }
                }.buttonStyle(.borderedProminent).disabled(!consent || model.busy)
            }
        }.padding(28).frame(width: 570).tint(Palette.accent).interactiveDismissDisabled(model.busy)
    }
}
