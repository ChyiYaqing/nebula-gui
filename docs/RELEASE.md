# macOS Release 打包

Issue #46。参考 [elink-ai Release](https://github.com/ChyiYaqing/elink-ai/blob/main/.github/workflows/release.yml)，使用本仓库已有的 GitHub 托管 `macos-15` runner，不依赖 elink-ci 专用 runner。

## 触发与产物

`.github/workflows/release.yml` 在相关 PR 上验证打包；Actions 中手动运行 **macOS Release** 会测试当前所选 ref 并生成 `macos-release` artifact，保留 7 天，不创建 Release。日常 `bash scripts/build.sh` 仍默认为当前架构的 debug 构建。

获得单独的发布授权后，维护者更新根目录 `VERSION`（仅 `X.Y.Z`，无前导零）及 `scripts/build.sh` 中的 `CFBundleVersion`，经 PR 合入后再推送对应 `vX.Y.Z` tag。tag 必须与其提交中的 VERSION 一致，否则工作流失败。应用版本与 helper 的 `HelperRelease` 各自管理；helper 行为改变时仍须按 [授权约定](AUTHORIZATION.md) 提升 helper 发布号。本次实现不创建或推送 tag。

tag 流程先执行完整测试与 Go vet，再 release 编译两种架构的 Swift GUI、Go backend 和 Go helper，将三个可执行文件都合成 Universal 并重新 ad-hoc 签名。构建显式设置 macOS 13.0 部署目标，包括 CGO 编译与链接目标。

产物为 `Nebula-vX.Y.Z-macos-universal.dmg`、同名 ZIP、`build-info.json`、`release-notes.md` 和 `SHA256SUMS`。DMG 内包含 App 与 Applications 快捷入口。manifest 记录源码 SHA、工作区是否有未提交改动、固定内核 SHA、工具链和包内文件哈希。打包后重新解压 ZIP、只读挂载 DMG，核对签名、文件哈希、每个组件的两种架构和 Mach-O 最低版本。不会启动 GUI、helper 或安装服务。

仅 tag 事件的独立 job 持有 `contents: write`，下载并核对 artifact 后创建 **Draft prerelease** 并附加产物。PR／手动构建只有读权限，不读取 Apple 证书或其他仓库 secrets。上传使用 GitHub 自动提供的 `GITHUB_TOKEN`。

## 下载、重跑与回退

在 Actions 运行详情下载 artifact；tag 对应的附件也可在仓库 Releases 的草稿中下载（需要仓库权限）。SHA256SUMS 覆盖 DMG、ZIP、manifest 和说明文本。普通用户不需要运行构建或校验终端命令。

失败后可重跑同一 tag；仅更新已有草稿的附件，不自动公开。已公开 Release 会被拒绝覆写。不要在工作流运行期间手动公开草稿；本工作流不会完成正式发布。需要修正已公开内容时，使用新版本和新 tag，经独立授权后发布。

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
