# 在 DSH Go 里让 AI 生成插件并注入 App

面向：iOS 17.1、rootless 越狱（Relaxin）、目标 App「黑洞入侵」`com.hole.io.attack.battle`。

---

## 0. 先纠正一个方向

**不要往 App Store 的 IPA 里塞 dylib。** 原因不是"难"，而是：

- App Store 版是 Apple 签名的，改 bundle 就得重签；重签后 `FairPlay` 解密链、App Group、推送全断，还拿不到 App Store 更新。
- 越狱下也**不需要**解密 IPA：tweak 是注入到运行中的进程里，类都在内存里，直接 hook 就行。

iOS 17.1 rootless 的正确形态是 **ElleKit + Filter**：写一个 deb，只对指定 bundle id 生效，卸载即恢复。

---

## 1. 这台机器的能力边界（我实测过）

在 DSH Go 的 bash 工具里跑：

| 能力 | 结果 |
|---|---|
| `node` | ✅ v24.22.1（引擎 Node Worker） |
| `fetch` 出站 HTTPS | ✅ HTTP 200 |
| `fetch` 到 127.0.0.1 | ✅ 可以连（连不上只因为没进程监听） |
| `child_process` | ❌ `child_process is unavailable in the iOS Node script Worker` |
| `/var/jb`、`/Applications` | ❌ 沙盒内看不见 |

**结论**：引擎能"说话"，不能"动手"。所以架构必须是：

```
DSH Go 引擎 (Node, 沙盒内)
   │  fetch http://127.0.0.1:8787
   ▼
jbhelper 守护进程 (launchd, root, 沙盒外)
   │  posix_spawn / 写文件
   ├─▶ /var/jb/usr/bin/make   编译 tweak
   ├─▶ /var/jb/usr/bin/dpkg   安装 deb
   └─▶ killall 黑洞入侵        让 ElleKit 重新加载
```

App 侧**一行 Swift 都不用改**就能跑通 MVP —— 因为引擎已经能跑 `node script.mjs`，而这个脚本能用 `fetch` 调 helper。

---

## 2. 本目录里给了什么

| 文件 | 作用 |
|---|---|
| `helper/jbhelper.m` | 越狱侧守护进程：HTTP API（exec / write / read / inspect），令牌鉴权，仅监听 127.0.0.1；`/inspect` 直接用 `mach-o/loader.h` 读 `cryptid` |
| `helper/com.dsh.jbhelper.plist` | launchd 配置，开机自启、崩溃重启 |
| `proxy/jb.mjs` | 引擎侧客户端：`health / inspect / exec / write / read / install / kill / respring` |
| `tweak-template/` | Theos 工程骨架：`Makefile`、`Tweak.x`、`Filter plist`、`control` |
| `skill/SKILL.md` | 给模型的技能提示词：教它按这个流程写 tweak |

---

## 3. 设备侧一次性准备

在越狱环境里（Filza 或 SSH 到手机，`/var/jb` 是 rootless 根）：

```sh
# 1) 依赖
/var/jb/usr/bin/apt install -y ellekit clang ldid make dpkg openssh

# 2) 编译并安装 helper
clang -fobjc-arc -O2 -framework Foundation -o /var/jb/usr/bin/jbhelper jbhelper.m
install -m 0755 /var/jb/usr/bin/jbhelper /var/jb/usr/bin/jbhelper
cp com.dsh.jbhelper.plist /var/jb/Library/LaunchDaemons/
launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.dsh.jbhelper.plist

# 3) 拿令牌
cat /var/jb/etc/jbhelper.token
```

嫌麻烦可以用脚本一步到位（在设备的 shell 里跑，不要在 DSH Go 的虚拟 shell 里跑）：

```sh
cd DSH-Go/jb && ./build.sh helper     # 编译 + 安装 + 重启 launchd + 打印令牌
./build.sh check                      # 不需要 clang 的静态检查
./build.sh tweak                      # 用 Theos 编 tweak 模板
./build.sh install <deb 路径>          # dpkg -i
```

Theos（设备内编译，第一次要装 SDK，约 1–2 GB）：

```sh
export THEOS=/var/jb/opt/theos
git clone --recursive https://github.com/theos/theos.git $THEOS
$THEOS/bin/install-sdk.sh   # 或者手动把 iPhoneOS SDK 放进 $THEOS/sdks
```

> 设备内编译偏慢但可用；如果你有 Mac，`make package` 放在 Mac 上更快，产物 `scp` 回手机 `dpkg -i` 即可，helper 那边只负责 install。

---

## 4. 工作区配置

`DSH-Go/jb/config.json`：

```json
{ "host": "127.0.0.1", "port": 8787, "token": "把 jbhelper.token 的内容粘进来", "timeoutMs": 600000 }
```

自检：

```sh
node DSH-Go/jb/proxy/jb.mjs health
# {"ok":true,"pid":…,"version":"1"}
```

跑一条命令：

```sh
node DSH-Go/jb/proxy/jb.mjs exec -- /var/jb/usr/bin/uname -a
```

---

## 5. 一次完整流程（AI 视角）

```sh
# 1. 建工程目录
node jb.mjs exec -- /var/jb/usr/bin/mkdir -p /var/jb/build/HoleNoAds

# 2. 传源码（本地 → 设备）
node jb.mjs write ./Makefile         /var/jb/build/HoleNoAds/Makefile
node jb.mjs write ./Tweak.x          /var/jb/build/HoleNoAds/Tweak.x
node jb.mjs write ./HoleNoAds.plist  /var/jb/build/HoleNoAds/HoleNoAds.plist
node jb.mjs write ./control          /var/jb/build/HoleNoAds/control

# 3. 编译
node jb.mjs exec -- /var/jb/usr/bin/make -C /var/jb/build/HoleNoAds package

# 4. 安装（产物在 .theos/_/debs/*.deb）
node jb.mjs install /var/jb/build/HoleNoAds/.theos/_/debs/com.dsh.holenoads_0.0.1_iphoneos-arm64.deb

# 5. 让目标 App 重新加载
node jb.mjs kill 黑洞入侵
```

第一次没找到真实类名之前，第 5 步会报 `killall` 找不到进程 —— 那是正常的，先把游戏打开一次。

---

## 6. "发现"：先把真实类名查出来

盲写 hook 命中率低。三步，顺序别换：

**0. 先预检（新增，最省事的一步）**

```sh
node DSH-Go/jb/proxy/jb.mjs inspect com.hole.io.attack.battle
```

helper 会读 `/var/containers/Bundle/Application/*/*.app`，按 `CFBundleIdentifier` 找到目标，然后解析 Mach-O 的 `LC_ENCRYPTION_INFO(_64)`：

```text
目标   黑洞入侵 (com.hole.io.attack.battle)
路径   /var/containers/Bundle/Application/xxxx/黑洞入侵.app
主件   黑洞入侵 [arm64, arm64e] 🔒 加密 (cryptid=1) 896MB
链接   17 个 dylib
         @rpath/UnityFramework.framework/UnityFramework
         @rpath/GADMobileAds.framework/GADMobileAds
         …
框架   6 个，其中未加密 4 个
         ✅ UnityFramework.framework 210MB
         …

结论   主二进制已加密：静态改包只能注入到未加密的 framework；ElleKit tweak 不受影响
       下一步：用 ElleKit tweak（进程内注入，与加密无关）
```

这直接回答两件事：**这个 App 能不能静态改包**、**它挂了哪些广告 SDK**（`dylibs` 列表就是线索，省掉一轮 frida 枚举）。

**A. 运行时枚举（推荐，需要 frida-server）**

```js
// enum.js
if (ObjC.available) {
  const names = Object.keys(ObjC.classes).filter(n =>
    /(Ad|AdMob|Pangle|BU|AT|MTG|ALSdk|AppLovin|IronSource|Vungle|Chartboost|UnityAds)/i.test(n));
  send(names);
}
```

```sh
frida -U -f com.hole.io.attack.battle -l enum.js --no-pause
```

**B. 看加载的二进制**

```sh
node jb.mjs exec -- /var/jb/usr/bin/ls /var/containers/Bundle/Application/*/黑洞入侵.app/Frameworks
```

广告 SDK 一般以 `.framework` 或 `libs/*.a` 静态链进去；静态链的类名照样能在运行时枚举到（A 办法）。

---

## 7. 如果你确实要改 DPSK-ios（产品化）

跑通 MVP 之后，把它做进 App 才有意义。按 `docs/architecture.md` 的约定，改这几处：

| 层 | 文件 | 改什么 |
|---|---|---|
| iOS 原生 | `app/ios/Runner/JBToolChannel.swift`（新） | 调 helper 的 Swift 客户端，Dart 通道 `dsh/jb` |
| 注册 | `app/ios/Runner/DshPlugin.swift` / `AppDelegate.swift` | 注册通道；同步 `tooling/ios/CHANNEL_COVERAGE.md` 与 `test-channel-contract.py` |
| Dart 通道 | `app/lib/jb/jb_channel.dart`（新） | MethodChannel 封装 |
| 状态 | `app/lib/state/jb_state.dart`（新） | 唯一 owner：在线状态、最近一次编译日志、已安装 tweak |
| 页面 | `app/lib/ui/settings/jb_page.dart`（新） | 设置项：helper 地址/令牌/连接测试/一键安装 |
| 设置入口 | `app/lib/ui/settings/index/spots.dart`、`settings_pages.dart` | 注册 `SettingsPageId` |
| 功能目录 | `app/lib/ui/features/feature_catalog.dart` | 加一节 |
| 引擎工具 | 仿 `PhoneGuest.kt` 的 iOS 版：写 `/opt/dsh-app/jb/{relay.cjs,jb.patch.yml}` 到 guest rootfs，`EngineChannel` 启动 `dsh web` 时挂 `--patch` | 让模型直接拿到 `jb_exec`/`jb_write` 工具，而不是每次手搓 node 命令 |
| 技能（最小成本） | `app/assets/skills/jb-tweak/SKILL.md` | 就是我写的 `skill/SKILL.md`，放进 assets 即可被模型加载，**这条单独做就能满足"AI 自动生成插件"** |

约束（来自 `architecture.md` §2.5/§6）：

- `ui/` 之外不能 import `ui/`；状态单一 owner。
- 文案中英同步：`app/lib/l10n/parts/*_{zh,en}.arb` → `python3 app/tool/l10n_merge.py`。
- 新通道要过 `python3 -B tooling/ios/test-channel-contract.py`。
- 改运行时补丁要登记 `runtime/patches/series` + `pins.json` 的 `targetSets`，否则 `rtbuild` 拒绝构建。

**省事的优先级**：先只加 `skill/SKILL.md` + `proxy/jb.mjs`（零代码改动，当天可用）→ 再用原生工具把它收进系统设置页。

---

## 8. 风险与边界

- **helper 是 root 权限的本地 HTTP 服务**：只听 127.0.0.1 + 令牌，但仍然等于给本机任意 App 一个 root 执行入口。别把令牌写进分享内容，用完可以 `launchctl bootout`。
- **rewarded 广告被拦会影响游戏奖励**：很多玩法靠"看广告得双倍"，拦截后拿不到奖励，这是预期行为。
- **App 更新**：tweak 是按 bundle id 注入的，更新后照样生效（类名变了才需要改 hook）。
- **别再注入 App Store 的 App 本体**：那会破坏签名并导致无法更新。
- **合规**：本仓库是 AGPL-3.0，README 明确请求"改造前先联系原作者 ccch1mneyyy"；自用无所谓，公开发布请先沟通并保留署名。
- **令牌泄露**：你贴在对话里的 GitHub PAT 已经暴露在会话记录里，**请立刻到 GitHub → Settings → Developer settings → Personal access tokens 吊销并重建**。我没有使用它。

---

## 9. 快速对照

| 问题 | 答案 |
|---|---|
| 要改 App 吗？ | MVP 不用；产品化改 6 处（见 §7） |
| 要在 Mac 上做吗？ | 只有编译可以放 Mac；注入在设备上 |
| 要破解 IPA 吗？ | 不要，ElleKit 注入运行中进程 |
| 能彻底去广告吗？ | 能拦展示，但拦不住 App 内购解锁的"官方免广告"逻辑以外的服务端下发 |
| 怎么判断某 App 能不能改包？ | `jb.mjs inspect <bundle id>`：主二进制 `cryptid != 0` 就是加密的，静态改包要 CoreTrust bypass |

---

## 10. 那两个限制到底卡在哪一层

`child_process 不可用` 和 `/var/jb 不可见` 看着是两件事，实际是**三层不同的限制**叠在一起。想"解决"，先认清卡在哪层：

| 层 | 现象 | 谁在拦 | 怎么解 |
|---|---|---|---|
| ① 工具策略层 | `bash: EACCES: 路径不在工作区或本次运行的临时目录内` | 引擎的 just-bash 路径校验（连 `/tmp` 都拦） | 改 `runtime/` 里的路径策略，或把文件放进工作区 |
| ② Node Worker 层 | `child_process is unavailable in the iOS Node script Worker` | 引擎给 Worker 的 preload 把 `child_process` 打了桩 | 改 runtime 的 preload，重新生成 `runtime.zip` 并重签 |
| ③ 内核沙盒层 | `/var/jb`、`/Applications` 列不出来 | iOS Seatbelt，按 codesign entitlement 生成，**越狱不解** | 给 App 加 `com.apple.private.security.no-sandbox` 并重签 |

关键点：**第 ③ 层不是越狱能解决的**。tweak 注入进 App 进程也一样受这条沙盒约束 —— 沙盒是内核按签名里的 entitlement 建立的，跟有没有越狱无关。所以"改 App 让它直接 exec、直接读 /var/jb"必须同时打通 ①②③，缺一层都不行。

### 路线 A：helper 代理（零改动，已给）

App 既不需要 `child_process`，也不需要看见 `/var/jb` —— 它只 `fetch` 一个 HTTP 接口。三层限制一层都不用碰。代价：每次动作都要绕一次 HTTP，文件要显式 `write`。

### 路线 B：真正解沙盒（要自己编译 iOS 包）

dsh-go 的 iOS 包本来就必须在 Mac 上用 Xcode 自签（见 `app/ios/README.md`），所以这条路是可行的：

1. **③ 沙盒**：给 Runner 加 entitlement，重建：

   ```xml
   <!-- app/ios/Runner/Runner.entitlements -->
   <key>com.apple.private.security.no-sandbox</key><true/>
   <key>platform-application</key><true/>
   ```

   自签包在越狱设备上（amfi 已 patch）才认这些 entitlement；非越狱设备会直接启动失败。

2. **② Worker**：全仓搜这个字符串，就能定位打桩的地方：

   ```sh
   grep -rn "is unavailable in the iOS Node script Worker" runtime/
   ```

   改掉那处 stub，然后跑 `tooling/ios/prepare-engine.sh` 重新生成 `Engine/runtime.zip`（addon/framework 布局校验严格，见 `app/ios/README.md`）。

3. **① 工具策略**：`runtime/` 里的 just-bash 命令白名单与工作区路径校验要放开到允许绝对路径。

代价：App 不能再走 App Store 更新（本来 iOS 版就没有公开包）；每次升级都要重签；`RuntimeInstaller`/`EngineChannel` 的路径假设要复核；CI 的 `iOS compile` 不覆盖这套组合。

### 路线 C：本机 SSH 主机（不改 App，最接近原生）

dsh-go 自带远程主机（`packages/dsh_remote` + `dartssh2`）。越狱环境里装 `openssh-server`，在 App 里把 `127.0.0.1:22` 加成一台远程主机，让 DSH 引擎跑在手机上那个 root shell 里：

- 三层限制全部消失（连接端是真实 shell，不是 App 进程）；
- `make` / `dpkg` / 看 `/var/jb` 全都自然可用；
- 不改 App、不影响更新；
- 代价：要在设备上准备一份 Node + DSH 运行环境，且手机 SSH 长期监听有安全风险（只绑 127.0.0.1、关掉密码登录）。

### 怎么选

- 只想让 AI 生成 tweak 并装上 → **路线 A**（已实现，今天就能跑）。
- 想让 AI 有一个真正的 shell、随便跑命令 → **路线 C**。
- 想改 App 源码做成产品（比如把 `jb_exec` 做成原生工具）→ **路线 B**，且必须三层一起改。

---

## 12. 推到 GitHub 跑 CI 构建

### 12.1 先看清楚：现有 workflow 不会碰这套东西

我把上游 `main` 的 workflow 全读了一遍：

| Workflow | 触发 | 会不会构建 jb |
|---|---|---|
| `ci.yml` | PR→main、push→main、手动；**无 paths 过滤** | ❌ 跑的是 Flutter/Dart/运行时测试 |
| `ios-compile.yml` | push `main`/`feat/ios-**`/`ios/**` + 命中 `app/**`、`packages/**`、`tooling/ios/**`、`runtime/**` | ❌ 不匹配 `jb/**` |
| `ios-guest.yml` | 更细的 `runtime/ios/guest/**` 等 | ❌ |
| `ios-ui-tour.yml` | `app/lib/ui/**` | ❌ |
| `pr-gate.yml` | PR opened/reopened，但 `if: github.repository == 'ccch1mneyyy/dsh-Go'` | ❌ 在 fork 上整段跳过 |
| `runtime.yml` / `goldens.yml` | 基本手动 | ❌ |

结论：**必须自己加一个 workflow**，即 `ci/jb-toolchain.yml`。

### 12.2 落地步骤

1. 把 `ci/jb-toolchain.yml` 复制成仓库根的 `.github/workflows/jb-toolchain.yml`。
2. 把这套文件放到仓库根的 `jb/`（注意：不是 `DSH-Go/jb/`，workflow 里写的是 `jb/**`）。
3. 推分支：

   ```sh
   git checkout -b feat/jb-toolchain
   git add jb .github/workflows/jb-toolchain.yml
   git commit -m "ci(jb): build jbhelper and tweak on macOS runner"
   git push -u origin feat/jb-toolchain
   ```

   分支名命中 `feat/**` + 路径命中 `jb/**`，两个 job 会一起跑。

4. 产物在 Actions → 对应运行 → Artifacts：
   - `jbhelper-iphoneos-arm64`：`xcrun --sdk iphoneos clang` 交叉编译的真机二进制
   - `tweak-deb`：Theos 打出的 rootless deb

### 12.3 不改代码，手动触发已有 workflow

`ios-compile.yml` 支持 `workflow_dispatch`。设备上没有 curl，用 Node：

```sh
GH_TOKEN=<新 token> node -e '
const [owner, repo, wf, ref] = ["weishixiao", "DPSK-ios", "ios-compile.yml", "main"];
fetch(`https://api.github.com/repos/${owner}/${repo}/actions/workflows/${wf}/dispatches`, {
  method: "POST",
  headers: { authorization: `Bearer ${process.env.GH_TOKEN}`, accept: "application/vnd.github+json", "content-type": "application/json" },
  body: JSON.stringify({ ref }),
}).then(r => console.log("HTTP", r.status));
'
```

`204` 表示已入队；`403` 是 token 缺 `Actions: write`；`404` 是 workflow 文件不在默认分支上。

### 12.4 三个坑

- **token**：fine-grained PAT 至少需要目标仓库的 `Contents: Read/Write` + `Actions: Write`。之前贴出来那个必须吊销，别复用。
- **Theos 首次装 SDK**：`install-sdk.sh` 要拉 1–2 GB，`build-tweak` 的 30 分钟超时可能不够，必要时提到 `60`。
- **runner 架构**：`macos-15` 是 arm64 runner，编出来的 `jbhelper` 是 `arm64-apple-ios15.0`；如果你要在 Intel Mac 上手动复现，记得加 `-arch arm64`，否则会出 x86_64 废二进制。
