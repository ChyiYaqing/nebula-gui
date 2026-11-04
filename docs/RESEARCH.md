# Nebula GUI 竞品调研

调研日期：2026-11-03。资料包括公开 GitHub 仓库、界面源码、项目官方文档及官方截图。未安装运行竞品，未完成可用性、性能或安全测试。仓库默认分支和文档可能继续更新，截图不代表所有发行版本。

## 对首版最有参考价值的项目

| 项目 | 观察到的界面结构 | 可用于本项目的设计 | 使用边界 |
| --- | --- | --- | --- |
| NetBird | 默认小窗展示连接、配置、主机名和 IP；高级视图向右展开 Peers、Resources 和节点详情 | 菜单栏常驻、紧凑首页、按需展开诊断信息 | 登录和控制平面流程不适用于现有文件导入需求 |
| EasyTier | 配置网络与运行网络分阶段；基础设置直接展示、高级设置折叠；运行页使用节点指标表格 | 配置分层、可比较的连接详情、可操作的错误提示 | 不应将全部网络参数直接搬到普通用户首页 |
| ZeroTier DesktopUI | 托盘为主要入口，通过 Network ID 加入网络，菜单展示地址和网络选项 | 快速操作、地址复制、网络切换 | 本项目使用证书和 YAML，不能照搬 Network ID 接入流程 |
| Mobile Nebula | 按 Site 管理，详情含状态、日志、Active/Pending 隧道；配置分为身份、Lighthouse、防火墙和高级设置 | 证书信息、隧道术语和详情组织最接近 Nebula | 移动端界面与平台适配不能原样作为 macOS 桌面工程 |
| Nebula Commander | Web 管理网络和证书；Windows、Linux 客户端负责接入、状态、服务、路由等操作 | 桌面与后台分离、服务状态、注册引导 | 依赖额外控制平面，超出首版独立客户端范围 |

建议组合 NetBird 的界面层次与 Mobile Nebula 的业务分组。Nebula Commander 提供同生态参考，但引入其服务端会改变用户现有的配置分发方式。

## 仓库、源码和截图

### NetBird

- [GUI 源码](https://github.com/netbirdio/netbird/tree/main/client/ui)
- [主窗口与默认／高级视图](https://github.com/netbirdio/netbird/blob/main/client/ui/frontend/src/modules/main/MainPage.tsx)
- [节点详情](https://github.com/netbirdio/netbird/blob/main/client/ui/frontend/src/modules/main/advanced/peers/PeerDetailPanel.tsx)
- [官方桌面说明](https://docs.netbird.io/client/desktop-app)
- [节点视图截图](https://docs.netbird.io/docs-static/img/client/desktop-app/peers-view.png)

调研时的桌面版本采用 Wails v3 与 React。UI 框架与连接后台的选型是两件事，借鉴其交互不要求采用同一技术栈。

### EasyTier

- [GUI 工程](https://github.com/EasyTier/EasyTier/tree/main/easytier-gui)
- [GUI 编译说明](https://github.com/EasyTier/EasyTier/blob/main/easytier-gui/README.md)
- [配置页面](https://github.com/EasyTier/EasyTier/blob/main/easytier-web/frontend-lib/src/components/Config.vue)
- [运行状态与节点表格](https://github.com/EasyTier/EasyTier/blob/main/easytier-web/frontend-lib/src/components/Status.vue)
- [官方配置截图](https://raw.githubusercontent.com/EasyTier/easytier.github.io/main/public/gui-config-dark.png)

桌面 GUI 采用 Tauri 2。截图展示了基础配置、折叠的高级设置以及运行入口；源码还展示了延迟、流量等节点指标。本项目只能展示后台确实提供的指标，不能照搬竞品字段。

### ZeroTier DesktopUI

- [仓库与构建说明](https://github.com/zerotier/DesktopUI)
- [加入网络窗口](https://github.com/zerotier/DesktopUI/blob/main/src/join.rs)
- [托盘操作](https://github.com/zerotier/DesktopUI/blob/main/src/main.rs)
- [服务与 GUI 的分工](https://docs.zerotier.com/config/)

独立服务执行网络操作，普通用户界面通过服务接口交互。Network ID 接入比本项目的证书文件接入更短，不能据此估算 Nebula 导入开发成本。

### Mobile Nebula

- [仓库](https://github.com/DefinedNet/mobile_nebula)
- [Site 详情](https://github.com/DefinedNet/mobile_nebula/blob/main/lib/screens/site_detail_screen.dart)
- [配置分组](https://github.com/DefinedNet/mobile_nebula/blob/main/lib/screens/siteConfig/site_config_screen.dart)
- [Apple Packet Tunnel Provider 实现](https://github.com/DefinedNet/mobile_nebula/blob/main/ios/NebulaNetworkExtension/PacketTunnelProvider.swift)

Flutter 界面与原生隧道适配并存。它证明 Nebula 有 Apple 移动端接入实践，但不能证明当前仓库已经具备可直接使用的 macOS Network Extension 产品。

### Nebula Commander

- [仓库](https://github.com/NixRTR/nebula-commander)
- [Windows 原生客户端说明](https://github.com/NixRTR/nebula-commander/blob/main/client/windows-app/README.md)
- [服务器地址与注册码接入页](https://github.com/NixRTR/nebula-commander/blob/main/client/windows-app/Pages/EnrollmentPage.xaml)
- [Linux 桌面安装说明](https://nebulacmdr.com/docs/usage/ncclient/installation/linux/)
- [Linux 状态页截图](https://raw.githubusercontent.com/NixRTR/nebula-commander/main/packaging/flatpak/screenshots/status.png)

Windows 采用 WinUI 3，Linux 采用 GTK4/libadwaita。它的桌面功能依赖管理服务，不能只拷贝界面便获得独立连接能力。

### 其他检索结果

- [XDGFX/nebula-gui](https://github.com/XDGFX/nebula-gui)：项目自述为 Electron 测试项目；调研时公开 API 显示最后推送在 2021 年，不作为成熟实现依据。
- [Tailscale 开源范围](https://github.com/tailscale/tailscale#other-clients)：主仓库未包含全部桌面 GUI 包装代码，不作为完整公开桌面 GUI 源码样本。

## Apple 平台与跨平台资料

| 资料 | 支持的判断 |
| --- | --- |
| [Apple 开发者账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account/) | 免费账号与付费开发者计划的能力不同；高级能力与分发资源不能混同本机编译 |
| [分发与测试方式](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases) | 普通 macOS App 有无代码签名导出路径，不代表所有扩展能力都可使用 |
| [Developer ID](https://developer.apple.com/help/account/certificates/create-developer-id-certificates) | 正式直接分发的签名身份与开发签名不同 |
| [macOS 分发与公证](https://developer.apple.com/macos/distribution) | 面向普通用户分发需单独设计签名、公证与安装体验 |
| [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice?language=objc) | macOS 13 及以后可管理应用的 Login Item、LaunchAgent、LaunchDaemon；实际注册还受批准与签名等条件影响 |
| [TN3134 部署规则](https://developer.apple.com/documentation/Technotes/tn3134-network-extension-provider-deployment?changes=_1_6&language=objc) | macOS Packet Tunnel 的 App Extension 限 App Store；直接分发使用 System Extension；iOS 使用 App Extension |
| [NEPacketTunnelProvider](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider) | 系统支持自定义 IP 隧道、虚拟地址与目标路由配置，需要对应 entitlement |
| [TN3120 使用场景](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers?changes=_1_5_1) | Packet Tunnel 用于远端网络访问，不应被当作任意本机流量过滤器 |
| [Flutter 平台支持](https://docs.flutter.dev/resources/faq)及[平台通道](https://docs.flutter.dev/platform-integration/platform-channels) | 可共享 UI，但授权、后台和隧道接入仍需要平台实现 |

资料描述的是调研时的平台规则，不是已执行的测试。后续引入依赖、开始系统服务或 Network Extension 工作前，应重新核对目标系统版本和官方要求。
