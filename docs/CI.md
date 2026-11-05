# macOS PR 检查

Issue #3。工作流为 .github/workflows/macos.yml，检查名称为「macOS build and tests」。

## 触发与权限

PR 创建、更新、重新打开，以及 main 推送时运行；合并后可手动触发。使用 macos-15 标准托管 runner，单次上限 25 分钟，同一 PR 新提交取消旧任务。权限仅 contents: read；检出后不保留令牌，不读取项目 secrets，不上传应用或诊断产物，不执行管理员安装。当前未配置分支保护。用户于 2026-11-05 已常设授权代理在所有验收条件满足、审查问题解决且适用检查通过后自动合并；单项 CI 通过不代表实机验收或其他门槛已完成。

本仓库为私有仓库，标准 runner 的执行计入账号现有 Actions 配额；没有调整预算或开通付费资源。配额不足时保留失败状态，不绕过检查。

官方 Actions 固定到提交；Go 版本读取 backend/go.mod，关闭自动切换工具链和共享依赖缓存。默认 Xcode 随 runner 镜像变化，每次记录系统、架构、Xcode、Swift 和 Go 版本。CI 的系统覆盖不代表产品的最低系统版本已完成实机验收。

## 固定内核输入

scripts/kernel-revision 是构建输入的 SHA 来源。scripts/prepare-kernel.sh 在缺少目标目录时从公开内核仓库获取该提交，目标默认为 GUI 的兄弟目录 nebula。已有目录只验证，不 fetch、切换分支、reset 或 clean；失败获取留下目录供排查，下一次应使用新的空目标目录。

scripts/verify-kernel.sh 拒绝 SHA 不符、修改的受跟踪文件、额外的编译源文件和符号链接目标。额外的本地说明文档不影响检查。当前固定内核没有 go:embed；若升级内核引入嵌入资源，应同步扩大输入校验。此检查服务于构建可复现性，不把开发者同 UID 的可写工作区变成安全隔离环境。

不要在原内核仓库中自动清理用户文件。更新 pin 前需独立审查内核、API 和组件兼容性。

## 干净环境复现

检出 GUI 到一个空工作区下的 nebula-gui，再运行：

```sh
bash scripts/prepare-kernel.sh
NEBULA_GUI_APP_OUTPUT="$PWD/build/CI/Nebula.app" bash scripts/test.sh
(cd backend && go vet ./...)
git diff --check
```

test.sh 先验证内核检查的拒绝路径，再执行构建、Go race、Swift 测试和 AppKit 退出探针。已有真实 AppModel 测试的分支合并后会自然包含该测试目标。

需要交互式桌面的 AppKit 探针若在 runner 上失败，保留失败并排查，不能静默跳过。CI 不覆盖真实 utun、路由、睡眠、系统管理员授权、实际通知投递和干净机器安装；这些由 Issue #4/#8 记录。
