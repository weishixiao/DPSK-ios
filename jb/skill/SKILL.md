---
name: jb-tweak
description: 在已越狱的 iPhone 上为某个 App 编写、编译并安装 ElleKit tweak（例如去广告、改界面、加功能）。当用户要求"做插件注入到某 App"、"改某个 App 的行为"、"去掉某 App 的广告"时使用。设备上有 jbhelper 守护进程时可直接编译安装，否则只生成工程并给出安装步骤。
---

# 越狱 tweak 工作流

前提：设备已 rootless 越狱；`DSH-Go/jb/config.json` 里配好了 helper 地址与令牌；
`node DSH-Go/jb/proxy/jb.mjs health` 返回 `ok:true`。

## 0. 先预检，别对着注不进去的 App 白忙

**任何 tweak 工作之前必须先跑这一条：**

```sh
node DSH-Go/jb/proxy/jb.mjs inspect <bundle id>
```

它会返回：主二进制是否加密（`cryptid`）、`Frameworks/` 里哪些 Mach-O 未加密、以及链接了哪些 dylib。

怎么用这个结果：

| 结果 | 含义 | 该怎么做 |
|---|---|---|
| 主二进制 `✅ 未加密` | 这个 App 是已解密/自签的 | 静态改包和 ElleKit tweak 都可行 |
| 主二进制 `🔒 加密`，但有未加密 framework | App Store 原包 | **只写 ElleKit tweak**；静态改包要 CoreTrust bypass，iOS ≥ 17.1 没有 |
| 全部 `🔒 加密` | App Store 原包且无第三方 framework | 只能 ElleKit tweak |

另外，输出的「链接 dylib」列表本身就是**广告 SDK 线索**：`libUnityAds`、`BUAdSDK`、`GADMobileAds`、`AppLovinSDK`、`IronSource`、`MTGSDK` 这类名字直接告诉你该 hook 谁，比盲目 frida 枚举快。

不要因为"看起来能改包"就去改包 —— 改包会破坏签名，App Store 版改完装不回去。

## 1. 明确目标

先问清三件事（缺一不可）：

1. 目标 bundle id（如 `com.hole.io.attack.battle`）。
2. 要改什么行为（去广告 / 改界面 / 加功能 / 改数值）。
3. 是否需要保留 App Store 更新（决定注入方式，见第 3 步）。

## 2. 找 hook 点

**不要凭记忆猜类名。** 按这个顺序：

1. 让用户在设备上打开目标 App，然后枚举当前进程的类：
   `frida -U -n <进程名> -l enum.js`，用 `/Ad|SDK|Manager|AdView/i` 过滤。
2. 找不到 frida 就用 `objection -g <bundle id> explore` 的 `ios hooking list classes`。
3. 拿到类名后，先用 frida 现场验证 hook 是否生效，**再**写成 tweak。
4. 静态链进 Unity 游戏的广告 SDK 仍然能在运行时枚举到（它们是 ObjC/Swift SDK）。

## 3. 写工程

最小结构：

```
<ProjectName>/
├── Makefile              # THEOS_PACKAGE_SCHEME = rootless；TWEAK_NAME 与 Filter 同名
├── <ProjectName>.plist   # Filter → Bundles → 目标 bundle id
├── Tweak.x               # %hook 代码
└── control               # Package/Name/Version/Architecture: iphoneos-arm64/Depends: ellekit
```

规则：

- `Filter` 里只写目标 bundle id，绝不写 `com.apple.UIKit` 之类系统进程。
- 每个 `%hook` 的回调方法签名必须与真实方法一致；不确定就先只 hook 无返回值的 `show/present` 方法。
- 拦截类操作要可逆：不要 patch 内存、不要改 App 容器里的文件。
- 不要绕过内购（改 IAP 校验属于破解，超出"去广告"范畴，不写）。

## 4. 编译与安装

```sh
node DSH-Go/jb/proxy/jb.mjs exec -- /var/jb/usr/bin/mkdir -p /var/jb/build/<ProjectName>
node DSH-Go/jb/proxy/jb.mjs write <本地文件> /var/jb/build/<ProjectName>/<文件名>
node DSH-Go/jb/proxy/jb.mjs exec -- /var/jb/usr/bin/make -C /var/jb/build/<ProjectName> package
node DSH-Go/jb/proxy/jb.mjs exec -- /var/jb/usr/bin/ls /var/jb/build/<ProjectName>/.theos/_/debs
node DSH-Go/jb/proxy/jb.mjs install <deb 绝对路径>
node DSH-Go/jb/proxy/jb.mjs kill <进程名>
```

编译失败时读 make 输出，改完重新执行第 4 步；**不要**在没看到完整报错的情况下猜着改。

## 5. 验证

1. 让用户打开目标 App。
2. 读日志确认注入：`node jb.mjs exec -- /var/jb/usr/bin/log show --last 1m --predicate 'processImagePath CONTAINS "目标进程"'`。
3. 让用户复现原行为（例如进入关卡触发插屏广告），确认广告不再出现。
4. 若仍出现：回到第 2 步重新枚举，说明 hook 的类不是实际调用路径（常见于 SDK 有多个版本/多个入口）。

## 6. 交付

- 把工程留在 `DSH-Go/jb/<ProjectName>/`，并写清楚：改了哪个类、哪个方法、如何卸载（`dpkg -r <包名>`）。
- 明确告诉用户：这是按 bundle id 注入，App 更新后仍然生效；卸载 deb 即恢复。
