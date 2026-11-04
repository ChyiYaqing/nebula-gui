# macOS 内部候选构建与验收

Issue #8。当前只生成本地内部候选，使用 ad-hoc 签名，没有 Developer ID 或公证，不上传、不发布、不安装系统组件。不将其描述为可供普通用户直接下载使用的正式 Beta。

## 版本与构建

VERSION 与 BUILD_NUMBER 分别控制 App 版本和构建号。Swift 界面读取 bundle 版本，Go 两个组件通过链接变量写入相同版本。helperRelease、协议与内核 SHA 独立管理，不能用 App 版本替代协议协商。

默认 debug；内部候选使用 release。显式设置 macOS 13.0 部署目标及 CGO 编译／链接选项。本轮发现旧 Go helper 的 minos 为 27.2、清单却声明 13.0；当前构建后逐个检查 Mach-O，不再依赖清单推断兼容性。目标版本只说明二进制构建声明，不证明对应系统实机可用。

每次构建包含 build-info.json：源码提交及 dirty 状态、固定内核 SHA、工具链、架构、配置、组件版本／协议与 helper 哈希。构建开始和结束都核对源码状态；候选要求干净 release。内核校验复用 Issue #3 的固定提交与编译输入检查，已有工作区只读。此流程可按记录重建，不声称已经验证跨机器字节级复现。

嵌入 manifest 只保存 helper 哈希，避免 GUI 签名资源哈希产生循环。外部 verification.json 记录签名后的全部二进制哈希；归档解压后重新检查并比较两份报告，确认二进制一致。

## 命令

```sh
NEBULA_GUI_BUILD_CONFIGURATION=release NEBULA_GUI_APP_OUTPUT="$PWD/build/ReviewRelease/Nebula.app" bash scripts/build.sh
python3 scripts/verify-app.py build/ReviewRelease/Nebula.app
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-package.py build/ReviewRelease/Nebula.app
bash scripts/package-beta.sh
```

打包从干净工作区构建到新建的 build/Beta 子目录，生成 App、标注 internal 的 ZIP、SHA256、原包／解压校验报告及 INTERNAL-BUILD.txt。不覆盖运行中的 build/Nebula.app。该脚本没有发布、管理员授权、服务注册或卸载动作。

离线元数据命令只输出编译常量，不打开配置目录、控制 socket 或隧道：

```sh
build/ReviewRelease/Nebula.app/Contents/Helpers/nebula-gui-backend metadata
build/ReviewRelease/Nebula.app/Contents/Helpers/nebula-gui-helper -metadata
```

verify-app.py 只用于可信的本机构建，它会在签名检查后执行组件的 metadata 入口；不能当作任意下载应用的安全扫描器。ad-hoc 签名只能检查包完整性，不能提供发布者身份。

## 兼容性与实机门槛

| 环境 | 已有证据 | 尚未完成 |
| --- | --- | --- |
| macOS 27.2 / Apple Silicon | 本轮 release 构建、离线组件、包校验、完整本地测试；既有版本真实连接见 VALIDATION.md | 新候选的完整安装、真实连接、升级失败回退及卸载 |
| macOS 15.8.2 / Apple Silicon | Issue #3 CI 验证构建、Go／Swift／退出测试 | 新候选的特权组件与干净机器安装 |
| macOS 13 / Apple Silicon | 三个产物头部 minos 声明均为 13.0 | 真正系统运行与 launchctl 行为，不能标为已支持 |
| Intel / Universal | 无 | 编译、打包和全部运行验收 |

干净机器需按 MACOS_ACCEPTANCE.md 和既有授权说明完成首次导入、系统授权、连接、退出清理、升级／取消／失败回退和卸载，并记录系统、架构、签名、组件、进程与路由证据。不得以降低 Gatekeeper／SIP 保护替代普通用户安装验收。

正式 Beta 还需用户确定支持平台、Apple Developer Program 与分发方式，并验证签名、公证、下载和升级路径；本 Issue 不授权注册账号、付费、发布或合并。上述实机和分发门槛未通过前保留 Draft。

## 本轮检查

独立目录 release 构建与三个组件校验通过。四项负向检查分别拒绝版本、协议、架构及最低系统不一致；debug 完整 scripts/test.sh、Go vet 与 diff 检查通过。安全／架构审查提出的内核来源和归档回读比较已补齐。最终候选归档及组合验证的具体结果在对应 PR 中记录。
