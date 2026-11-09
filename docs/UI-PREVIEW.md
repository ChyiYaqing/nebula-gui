# 界面开发预览

`bash scripts/preview-ui.sh` 编译独立的原生预览工具，直接使用产品视图与 AppModel 的隔离初始化器。它只填充合成网络、节点和错误，不启动普通后台、root helper、轮询、环境监控或真实存储。

```sh
# 交互预览。标题与网络名明确标注合成数据。
bash scripts/preview-ui.sh --scenario connected --page nodes

# 生成单个窗口内容快照后退出；不会截取桌面或其他 App。
bash scripts/preview-ui.sh --scenario connected --page overview \
  --width 900 --snapshot /private/tmp/nebula-overview.png

# 编译一次后可直接运行预览二进制。
bash scripts/preview-ui.sh --build-only
.build/bin/nebula-ui-preview --scenario unavailable --appearance dark \
  --snapshot /private/tmp/nebula-health-dark.png
.build/bin/nebula-ui-preview --scenario connected --menu \
  --snapshot /private/tmp/nebula-menu.png
```

`--scenario` 支持 `empty`、`disconnected`、`connected`、`other`、`busy`、`missing`、`unavailable`、`failed`、`recovering`，以及另一网络失败或恢复时查看所选网络的 `failed-other`、`recovering-other`；节点延迟监测使用 `monitor`（三个活动节点的合成 5 分钟历史，其中一行展开，配合 `--page nodes`），日志页的升级提示使用 `logs-upgrade`，软件更新有新版本时使用 `update`（配合 `--page configuration`，合成发布，不联网、不安装）。`--page` 支持 `overview`、`nodes`、`configuration`、`logs`。窗口最小宽度为 760，默认 900；`--height` 可加高窗口（最小 570，默认 720）；`--appearance dark` 使用深色。快照生成后会核对渲染阶段没有向假后台发送请求。

`--disable-animations` 只关闭预览事务的动画，不伪装成系统“减少动态效果”设置。产品视图读取真实的 `accessibilityReduceMotion`；系统设置的实机验收应另记，不能用事务覆盖代替。

预览编译时显式排除生产授权和通知适配器，替换为拒绝系统操作的版本，不执行管理员命令、不发送通知、不写通知偏好。可用 `.build/bin/nebula-ui-preview --verify-isolation` 验证直接授权执行器、完整移除入口和通知操作均被隔离。预览的连接操作只会得到合成错误，不建立网络；完整生命周期与系统操作验收仍使用正常构建和独立测试网络。预览不替代 #4 的实机验收。

原创 App 图标由 `scripts/generate-icon.swift` 和产品中的 `NebulaGlyph` 几何图形生成，正常构建会写入忽略目录内的 iconset 及 App 资源；不需要图像服务或外部素材。
