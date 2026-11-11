# Keychain 可行性与迁移决策

Issue #5，2026-11-04。结论：当前 ad-hoc 构建尚未证明可使用 Data Protection Keychain，不能启动生产凭据迁移。当前继续使用私有目录 0700、文件 0600，并由 Issue #6 减少无用历史副本。

## 已执行验证

显式执行 bash scripts/test-keychain-spike.sh，在临时目录编译并 ad-hoc 签名探针。探针只操作随机 service 下的随机临时数据，指定 Data Protection Keychain、WhenUnlockedThisDeviceOnly 和禁止交互的 LAContext；没有默认钥匙串回退、不查询已有条目、不改访问列表。成功路径读回比较后删除，输出只含状态码与布尔值。该探针不加入日常测试或 CI 自动运行。

本机环境 macOS 27.2 / Xcode 27.2 / Swift 6.4.2 / Apple Silicon。实际结果：

```json
{"schema":1,"kind":"adhoc_data_protection_keychain_spike","addStatus":-34018}
```

-34018 对应 errSecMissingEntitlement。只能说明当前探针的签名／entitlement 条件不满足，不能据此断言所有无会员账号的 macOS Keychain API 都不可用。当前没有任何生产 Keychain 写入或迁移。

## 路线比较与决策

| 路线 | 改动与收益 | 需要验证的代价 |
| --- | --- | --- |
| GUI 访问 Data Protection Keychain | 推荐的后续方向；GUI 取私钥，现有受限链路以内存配置传给后台 | 稳定签名和 entitlement、锁定／拒绝、跨升级身份、明文运行配置重构 |
| 普通 Go 后台访问文件型 Keychain | Go 可独立读取，较接近当前加载流程 | cgo 桥接、访问控制、后台二进制升级身份；旧文件型 API 与未来 iOS 不能视为同一路线 |
| 暂保留 0600 文件与有限历史 | 当前可交付，存储与协议不变 | 不提供 Keychain 保护，磁盘上仍有凭据，需明确保留与清理范围 |

不为绕过本次错误改用无约束访问列表，不扩大 root helper 为任意密钥读取服务。签名条件未解决前不迁移真实凭据；后续如选择文件型 Keychain，需要单独的隔离钥匙串／跨进程访问验证，不能把本探针当作其结果。

后续 GUI 方案维持：GUI → 私有 stdio → 普通 Go → 受鉴权 socket → root helper。只扩充必要的内存凭据载荷；配置元数据只存引用，日志和诊断不记录载荷。GUI 退出后不保证连接存续，符合当前会话所有权。

## 原子迁移方案与进入条件

先完成新的存储 schema 与最低应用版本检查。每个迁移单元为 profile/version，盘点当前、回滚、孤立和临时版本，用户导入源文件保持不变。

1. 验证旧当前／回滚版本可用，创建唯一迁移事务；旧索引仍指向原版。
2. 写入唯一 Keychain 引用并读回核验，未成功时结束事务，保留旧版。
3. 写入不含私钥的新版本、引用和摘要；校验重组配置、同步文件及目录。
4. 原子切换索引到新 schema。此前中断重启继续旧版；此后按新索引恢复，孤立 Keychain 项和暂存版本仅在确认无引用后回收。
5. 只有新版本和保留回滚版本均验证可读，才按保留策略回收受管旧明文副本。Keychain 锁定／拒绝不静默导出明文，也不误删最后可用数据。
6. 老应用不能解析新 schema 时应拒绝打开；回退需要支持新格式的已验证版本，不能承诺回退任意旧二进制。

需覆盖的中断点：Keychain 写入前后、新文件写入前后、索引切换前后、旧副本清理前后。必须用隔离存储和临时凭据验证，包含重复执行、锁定、拒绝、更新签名和进程退出。进程中断测试不等同于突然断电的持久性证明。

## 尚未完成

锁定／拒绝、应用升级／重启、普通 Go 访问、事务实现与故障注入均未完成；原因是当前 Data Protection Keychain 写入门槛未通过。本 Issue 不应按生产接入完成关闭。需要先确定稳定签名／entitlement 条件，或明确选择并验证文件型 Keychain 路线，再开生产接入 Issue。不开通账号、不付费、不读取用户真实钥匙串条目。

参考：[Apple TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)、[Keychain services](https://developer.apple.com/documentation/security/keychain-services)、[SecItemCopyMatching](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:))。API 可行性以本机探针和后续目标签名的测试为准。

探针若在添加成功与删除之间被强制终止，可能留下随机临时项；不承诺任意中断下自动清理。本次 -34018 路径未写入，不作为成功读写或清理证明。
