> v0.3 已完成本机授权升级、真实节点互通和普通后台异常恢复验证，结果见 [验证记录](VALIDATION.md)。不要手工以 root 运行 App 或配置后台。

# 本机开发

## 工程结构

```text
apps/macos/           Swift Package：原生 App、管道客户端与 XCTest
backend/             独立 Go 模块：导入、存储、协议与真实内核适配
scripts/build.sh     编译 Go 与 Swift，生成本地签名的 .app
scripts/test.sh      构建后执行 Go race、Swift 与 AppKit 退出回归测试
docs/                方案、设计、调研和验证记录
.build/、build/      被 Git 忽略的本机构建目录
```

后端通过 Go module 的本地 replace 读取 `../../nebula`。构建固定到方案中的提交；首次运行可能下载 Go 工具链与已锁定模块。`backend/go.sum` 记录依赖校验和。不向兄弟仓库写入代码、测试或构建产物。

## 构建与运行

```sh
bash scripts/build.sh
open build/Nebula.app
```

App 通过 `Contents/Helpers/nebula-gui-backend` 启动固定内核版本的后台，使用 stdin/stdout JSON，不调用 shell，不开放网络监听或共享管理 socket。它直接使用 Go 内核的结构化 API，不解析 CLI 展示文本。

默认数据目录为当前用户的 `~/Library/Application Support/NebulaGUI`，需要目录只对当前用户开放。每个保存的配置使用随机 ID、版本化目录和原子更新的当前版本索引。运行配置内含凭据，文件权限为 0600，目录权限为 0700；本机验证版尚未接入 Keychain。

可使用隔离目录进行开发测试：

```sh
open -n build/Nebula.app --args --data-dir /private/tmp/nebula-gui-dev
```

`--import /absolute/path/config.yaml` 仅打开预览，不自动保存。`--snapshot-to /private/tmp/nebula.png` 在窗口绘制后保存窗口内容 PNG，用于开发视觉检查。不要在真实凭据预览上生成供公开发布的截图。

普通配置后台拒绝 root 身份；不要用 `sudo` 启动它。GUI 通过受控 Unix socket 请求单独的特权网络组件执行内核操作，安装与移除由用户在 GUI 主动授权，详见 [授权说明](AUTHORIZATION.md)。

## 测试

完整入口：

```sh
bash scripts/test.sh
```

Go 测试生成临时 CA、主机证书与密钥，覆盖正常导入、源文件独立、错误凭据、范围拒绝、配置替换与回滚、目录权限、协议和诊断脱敏。生命周期测试使用明确的测试替身，不能作为真实隧道互通证据。Go 子进程与 Swift 测试另行调用实际构建的后台验证管道与退出行为。

单独执行实际后台的 Swift 测试：

```sh
NEBULA_GUI_TEST_BACKEND="$PWD/.build/bin/nebula-gui-backend" \
  swift test --package-path apps/macos --scratch-path .build/swift
```

显式启用一次原生隧道启动测试：

```sh
cd backend
NEBULA_GUI_NATIVE_TEST=1 go test -v -count=1 \
  -run TestNativeConnectionAttempt ./internal/client
```

该测试会尝试内核网络操作。得到 `authorization_required` 只证明权限错误路径可识别；只有实际成功并停止才证明本机启动与断开，仍不证明远端节点互通。

开发截图所需的临时测试身份可单独生成，不应进入 Git：

```sh
cd backend
NEBULA_GUI_FIXTURE_DIR=/private/tmp/nebula-gui-fixture \
  go test -v -count=1 -run TestExportDevelopmentFixture ./internal/client
```

## 清理

关闭 App 窗口不会退出应用，菜单栏仍可重新打开。菜单选择断开并退出，后台通过 EOF 清理并释放锁；正常退出不依赖固定延时。若后台操作超时被强制终止，界面保留清理未确认提示，并阻止同一客户端静默恢复成正常连接状态。

网络组件从 GUI 的“管理后台”入口授权移除。删除保存配置应从 App 的移除操作执行；移除会删除该配置的全部受管版本和凭据副本，原始分发文件保持不变。不要删除用户其他 Nebula 或 VPN 的目录、设备和路由。

## 尚未交付

Keychain、退出整个 App 后保持连接、Intel/macOS 13 实机测试、iOS/Linux 实现及正式签名分发均未完成。v0.3 已实现组件升级、唤醒同步与有限恢复、主动开启的系统到期通知；实机授权升级与普通后台异常恢复已通过；真实睡眠及系统通知投递仍需验收。

## 保留运行中的 App 并构建下一版

```sh
NEBULA_GUI_APP_OUTPUT="$PWD/build/Next/Nebula.app" bash scripts/test.sh
```

该参数只改变 App 包输出位置，不安装、升级或重启 root 组件。当前 App 使用自己包内的后台，因此独立构建不会覆盖其运行文件。切换 App 时，先断开并退出旧实例，再打开新实例；不能让两个实例同时持有同一配置目录。


## v0.3 恢复与诊断

会话恢复不持久保存连接意图。普通后台或特权会话失效后，先关闭原普通后台，再通过认证组件确认旧控制会话清理完成；确认会设置会话序号栅栏，拒绝已接收但延迟执行的旧请求。只有这一步成功，传输层才解锁清理警告。

退出使用永久传输屏障，阻止导入或刷新回调在后台关闭后重新启动子进程。通知协调器对每次系统异步调用检查代次，配置替换或关闭通知可撤回迟到的添加请求。

可单独验证普通用户 ICMP socket（仅回环地址，不创建隧道）：

```sh
(cd backend && NEBULA_GUI_ICMP_TEST=1 go test -race -run TestUnprivilegedICMPLoopback ./internal/client)
```

隔离 `--data-dir` 实例不发送系统通知。新版本建议构建到 `build/Completion/Nebula.app`，避免覆盖正在运行的版本。详细范围见 [macOS 补全方案](MACOS_COMPLETION.md)。


CI: [macOS PR checks](CI.md).
