# App 选择与进程侦察（设计说明）

这份文档说明聊天框「应用」入口的真实行为边界，以及为什么边界画在这里。

## 交互

聊天输入框的「＋」面板里，原来的「语音通话」位置现在是「应用」。

1. 点「应用」→ 弹出应用列表（按名称/Bundle ID 可搜索）。
2. 选中一个 → 往当前对话发一条消息：`显示名 (bundleId)`。
3. 模型拿到这条消息后，按普通对话回答。

没有第 4 步。选中应用不会启动它、不会附加到它的进程、不会读取它的内存。
应用列表来自系统的已安装应用注册表（`LSApplicationWorkspace`），只有名称和
Bundle ID 两个字段。

## 为什么只到这一步

「运行时内存读写 + Hook 任意方法」这套能力，对付款校验、会员状态、游戏数值是
同一条通路。把这些能力打包成「选任意 App → 自动生成注入代码」，产出的就不只是
逆向学习工具，而是一键破解器。这个我不做。

能做的、也确实有价值的部分是**只读侦察**：拿到一个 App 的可执行文件后，分析
Mach-O 结构、段布局、链接的框架、加载的库、entitlements、签名信息。这些是真正
理解一个二进制怎么工作所需的东西，而且不改变目标任何状态。

## 守护进程（agent/service）

特权部分已经从主进程里拆出来，作为一个 launchd 常驻进程
（`dsh-go-agentd`），通过 XPC 与 App 通信。App 和 harness 主进程都不直接执行
`task_for_pid`、内存读写这类操作。

- **白名单前置**：每个请求先过 `DshGoAgentSafety`，不在白名单里的目标直接
  `ERR_TARGET_NOT_ALLOWED`，没有任何旁路。
- **高危操作需要人工确认**：`mem.write` 必须带 `confirmed: true`，否则
  `ERR_CONFIRMATION_REQUIRED`。
- **只读方法**：`probe.ping`、`probe.listProcesses`、`probe.modules`、
  `probe.readMemory`（有长度上限）。
- **未实现**：`tweak.compile`、`tweak.inject` 当前返回 `ERR_NOT_IMPLEMENTED`。

## RootHide 环境

RootHide 的进程隐藏机制会干扰 `task_for_pid`、`ptrace` 这类调用。要在这种环境
里让特权进程正常工作，需要：

1. 守护进程由 launchd 启动，带 `platform-application` 与 `task-for-pid-allow`
   entitlement——这是 App 进程拿不到的。
2. 守护进程的 Mach service 名称注册在 launchd job 里，App 按名称连接，不依赖
   进程可见性。
3. RootHide 的隐藏列表按需把 App 自身排除，使系统调用不被拦截。

这些是环境配置，属于合法准备工作，文档里如实写出；具体绕过他人 App 保护的
操作不在本仓库范围内。

## 边界清单

| 能力 | 状态 |
| --- | --- |
| 列出已安装应用（名称、Bundle ID） | ✅ 已实现 |
| 把选中的应用发进对话 | ✅ 已实现 |
| 只读进程侦察（进程列表、模块、内存读） | ✅ 已实现 |
| 内存写入 | ⚠️ 需人工确认，默认关闭 |
| Tweak 生成 / 编译 / 注入 | ❌ 不实现 |
