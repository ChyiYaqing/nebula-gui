# macOS Release 打包

Issue #46／#54。参考 [elink-ai Release](https://github.com/ChyiYaqing/elink-ai/blob/main/.github/workflows/release.yml)。macOS 打包在 MacMini M4 的本仓库专用 runner 上运行，标签为 `[self-hosted, macOS, ARM64, nebula-gui-ci]`；跨 job 附件校验与草稿 Release 写入继续使用 Ubuntu 托管 runner。M4 实例和工作区隔离见 [CI 说明](CI.md)。

## 触发与产物

`.github/workflows/release.yml` 在相关 PR 上验证打包；Actions 中手动运行 **macOS Release** 会测试当前所选 ref 并生成 `macos-release` artifact，保留 7 天，不创建 Release。日常 `bash scripts/build.sh` 仍默认为当前架构的 debug 构建。

获得单独的发布授权后，维护者更新根目录 `VERSION`（`X.Y.Z` 或 `X.Y.Z-rcN`，无前导零，N 从 1 开始）及 `scripts/build.sh` 中的 `CFBundleVersion`，经 PR 合入后再推送对应 `v${VERSION}` tag。tag 必须与其提交中的 VERSION 一致，否则工作流失败。应用版本与 helper 的 `HelperRelease` 各自管理；helper 行为改变时仍须按 [授权约定](AUTHORIZATION.md) 提升 helper 发布号。

RC tag、附件名和 manifest 的 `version` 保留完整版本，例如 `0.1.0-rc1`；Info.plist 的 `CFBundleShortVersionString` 和 manifest 的 `applicationVersion` 使用 `0.1.0`，符合 [Apple 的三段数字格式](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring)。首个候选版本的 build 为 5，helper 兼容发布号保持 0.3.1。

tag 流程先执行完整测试与 Go vet，再 release 编译两种架构的 Swift GUI、Go backend 和 Go helper，将三个可执行文件都合成 Universal 并重新 ad-hoc 签名。构建显式设置 macOS 13.0 部署目标，包括 CGO 编译与链接目标。

产物为 `Nebula-vX.Y.Z-macos-universal.dmg`、同名 ZIP、`build-info.json`、`release-notes.md` 和 `SHA256SUMS`。DMG 内包含 App 与 Applications 快捷入口。manifest 记录源码 SHA、工作区是否有未提交改动、固定内核 SHA、工具链和包内文件哈希。打包后重新解压 ZIP、只读挂载 DMG，核对签名、文件哈希、每个组件的两种架构和 Mach-O 最低版本。不会启动 GUI、helper 或安装服务。

独立 Ubuntu job 在所有触发方式下下载 artifact 并核对 SHA256SUMS，验证跨 job 传递后的目录与内容。仅 tag 事件的独立 job 持有 `contents: write`，下载并再次核对 artifact 后创建 **Draft prerelease** 并附加产物。PR／手动构建只有读权限，不读取 Apple 证书或其他仓库 secrets。上传使用 GitHub 自动提供的 `GITHUB_TOKEN`。

## 软件更新签名（#69）

App 内的软件更新只安装带有效 Ed25519 签名的 ZIP。`scripts/update-public-key` 保存公钥（Base64 编码的 32 字节原始公钥，可为空）。`build.sh` 校验格式后写入 Info.plist 的 `NebulaUpdatePublicKey`，`build-info.json` 的 `updatePublicKey` 记录同一值。公钥为空的构建只能检查更新、打开发布页，不能自动安装。

tag 事件的草稿 job 从 `build-info.json` 读取公钥。公钥非空时，必须配置仓库 secret `NEBULA_UPDATE_SIGNING_KEY`（PEM 格式 Ed25519 私钥），且其公钥与 App 内置公钥一致，否则失败。签名后用公钥回验，上传 `Nebula-vX.Y.Z-macos-universal.zip.sig`（签名的 Base64 文本）。私钥只写入 runner 临时目录，权限 0600，步骤结束即删除。PR 与手动运行不读取该 secret。

App 匿名访问 Releases API，前提是本仓库公开。一次性准备步骤（需维护者授权后执行；私钥不要放在仓库目录内）：

```sh
openssl genpkey -algorithm ed25519 -out ~/nebula-update-key.pem   # 需支持 Ed25519 的 OpenSSL 3
gh secret set NEBULA_UPDATE_SIGNING_KEY < ~/nebula-update-key.pem
openssl pkey -in ~/nebula-update-key.pem -pubout -outform DER | tail -c 32 | base64 > scripts/update-public-key
```

公钥经 PR 合入后，之后的 tag 才会生成签名。已发布的版本里没有这把公钥，因此从这些版本升级到第一个内置公钥的版本，仍需手动安装一次。轮换密钥时，必须先发布一个用旧密钥签名、但内置新公钥的版本；私钥丢失后，只能让用户手动安装一个内置新公钥的版本。私钥泄露时，应立即删除该 secret，并按丢失处理。

## 下载、重跑与回退

在 Actions 运行详情下载 artifact；tag 对应的附件也可在仓库 Releases 的草稿中下载（需要仓库权限）。SHA256SUMS 覆盖 DMG、ZIP、manifest 和说明文本。普通用户不需要运行构建或校验终端命令。

失败后可重跑同一 tag；仅更新已有草稿的附件，不自动公开。已公开 Release 会被拒绝覆写。不要在工作流运行期间手动公开草稿；本工作流不会完成正式发布。需要修正已公开内容时，使用新版本和新 tag，经独立授权后发布。

用户明确要求发布某个版本时，在 tag 工作流完成、附件和校验值核对后，再公开对应草稿为 Prerelease，RC 不设为 Latest。缺少正式签名时，发布说明必须保留 ad-hoc／未公证和实机验收限制；公开候选版本不表示这些门槛已完成。

本地复现：

```sh
bash scripts/prepare-kernel.sh
NEBULA_GUI_APP_OUTPUT="$PWD/build/ReleaseTests/Nebula.app" bash scripts/test.sh
bash scripts/package-release.sh
python3 scripts/test-release.py
```

脚本拒绝覆盖已有 `build/Release/vX.Y.Z`，本地重跑前将旧目录移出该位置保存。归档与构建只写本仓库忽略目录；现有兄弟内核只读验证，不切换或修改。回退自动化可 revert 本 PR，不修改用户数据、已安装 App 或 root helper。回退应用或系统组件需要独立的兼容性与授权流程。

## 分发门槛

这些是 **release 优化的内部验证包**：ad-hoc 签名，未 Developer ID 签名、未公证，不是已验收的对外 Beta。不要要求用户关闭 Gatekeeper／SIP。Universal 和部署目标检查不代表 Intel／Apple Silicon、macOS 13／其他系统的安装与运行验收已完成。

干净机器导入、管理员授权、连接、升级失败回退与卸载继续由 #8／Draft PR #16 和 #4 验收；此工作流不关闭这些任务，也不替代组件兼容协议检查。正式签名、公证、系统组件安装及真实发布仍需单独授权。
