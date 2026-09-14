# DeepSeek-Harness 一键启动器（v2 · 单窗口双标签页 + 自动安全模式）

把 `npx @deepseek-ai/dsh web` 变成**双击即用**：一个 Windows Terminal 窗口、两个标签页
（`DSH 服务` + `DSH 日志`）、Chrome 独立窗口直开 GUI；插件不兼容时**自动进入安全模式**再启动一次。

- **一键启动**：双击桌面 `DeepSeek-Harness` 图标。
- **一键停止**：关掉窗口（= 停服务），或 `DeepSeek-Harness.ps1 stop`。
- **双机统一**：全部路径动态解析，同一份文件可在任意 Windows 机器上用 `setup.cmd` 部署。

---

## 目录

1. [现在是怎么工作的（架构）](#1-现在是怎么工作的)
2. [快速开始](#2-快速开始)
3. [子命令与日常使用](#3-子命令与日常使用)
4. [config.json 参考](#4-configjson-参考)
5. [安全模式详解](#5-安全模式详解)
6. [故障排查](#6-故障排查)
7. [**本次改造复盘（含我操作中的重大失误）**](#7-本次改造复盘)
8. [平台与语言坑位（PS 5.1 / Windows）](#8-平台与语言坑位)
9. [双机部署流程](#9-双机部署流程)
10. [环境事实清单](#10-环境事实清单)
11. [Agent 交接协议](#11-agent-交接协议)
12. [文件结构](#12-文件结构)

---

## 1. 现在是怎么工作的

```
桌面 DeepSeek-Harness.lnk
  └─ target = wt.exe（Windows Terminal 执行别名）
     args   = -w "DeepSeek-Harness" nt -d "<程序目录>" --useApplicationTitle
              "…\powershell.exe" -NoProfile -ExecutionPolicy Bypass
              -File "…\DeepSeek-Harness.ps1" start
        │
        └─ WT 命名窗口「DeepSeek-Harness」
             ├─ Tab1 「DSH 服务 · 3080」   ← 就是上面那个 powershell（入口 == 服务，同一个进程）
             │     └─ cmd /c npx -y @deepseek-ai/dsh --profile web --no-open --port 3080
             │          ├─ 输出原样落盘 logs\web.log（cmd 重定向，不经 PowerShell 文本管线）
             │          ├─ 抓到 "dsh web: http://127.0.0.1:3080/?token=…" → 视为就绪
             │          └─ 用该带令牌 URL 打开 Chrome --app（新版 GUI 需要令牌，裸 URL 会 401）
             └─ Tab2 「DSH 日志」          ← tail-log.ps1，只读跟随 logs\web.log
        │
        ├─ 共享状态：runtime\state.json    （runId/status/mode/pid/url/token/attempt/…）
        └─ 安全模式覆盖层：runtime\safe-mode.patch.yml（按 profile 自动推导，默认只保留 dsh-market）
```

关键设计点（都是被实际故障逼出来的）：

| 设计 | 为什么 |
|---|---|
| **入口就在 WT 标签页里**（不再用隐藏进程） | Win11 默认终端是 Windows Terminal 时 `-WindowStyle Hidden` **不生效**：隐藏进程会变成可见窗口。旧版“双击后冒出两个命令行窗口”就是这么来的 |
| **服务跑在 Tab1，关窗口=停服务** | 进程关系简单：一个窗口、两个标签页、一个服务；不再有隐藏的第三、第四个进程 |
| **就绪信号 = `dsh web: …?token=…` 这一行** | 新版 GUI 有进程令牌鉴权，裸 `GET /` 必然 401；旧版按网页标题探活会永远判失败 |
| **日志用 `cmd /c … > 文件` 重定向 + 显式 UTF-8 读取** | PS 5.1 用系统 GBK 代码页解码 node 的 UTF-8 输出 → 中文变 `宸插姞杞`，且不可逆 |
| **`--patch` 覆盖层做安全模式** | 官方机制、只置 `disabled: true`、**不改你的任何配置/profile 文件**，下次正常启动即自动恢复 |
| **stop 只认两种精确口径** | 见第 7.2 节事故复盘：宽口径会误杀 DSH Desktop |

生命周期：WT 窗口的生死 = 服务的生死。

- 关掉整个窗口 → 服务随之结束 → `state.json` 记为 `stopped`。
- 只关「DSH 日志」标签页 → 服务继续（窗口只剩 Tab1）。
- `stop` → 写 `status=stopping` → 服务进程与两个标签页依次退出 → 窗口自动关闭。

---

## 2. 快速开始

```powershell
# ① 安装/修复：生成桌面快捷方式与图标
C:\Users\yuenanmu\Desktop\DeepSeek-Harness\setup.cmd

# ② 日常使用：双击桌面 "DeepSeek-Harness"
# ③ 停止：关窗口，或
powershell -ExecutionPolicy Bypass -File "C:\Users\yuenanmu\Desktop\DeepSeek-Harness\DeepSeek-Harness.ps1" stop
```

前置依赖：Windows 10/11 + **Windows Terminal**（无则自动回退无窗口模式）、Node.js + npm、Chrome（无则回退 Edge）。
无需管理员权限。

---

## 3. 子命令与日常使用

```powershell
$L = "C:\Users\yuenanmu\Desktop\DeepSeek-Harness\DeepSeek-Harness.ps1"
powershell -ExecutionPolicy Bypass -File $L start        # 启动（默认；已在运行则只开窗口）
powershell -ExecutionPolicy Bypass -File $L stop         # 停止（-DryRun 只演练不执行）
powershell -ExecutionPolicy Bypass -File $L status       # 状态：运行中/模式/端口/PID/令牌打码/窗口数
powershell -ExecutionPolicy Bypass -File $L doctor       # 环境诊断（-Json 输出机器可读报告）
powershell -ExecutionPolicy Bypass -File $L safe-mode    # 生成并查看安全模式覆盖层
```

可用参数：

| 参数 | 作用 |
|---|---|
| `start -SafeMode` | 强制本次以安全模式启动（不用等它失败） |
| `start -WindowMode hidden` | 本次不建终端窗口（日志只写文件，失败弹窗） |
| `start -Port 3099` | 临时换端口（做实验时很有用，见第 7.2 节教训） |
| `doctor -Json` | 写出 `environment-report.json` |
| `doctor -Verify` | 额外用 `dsh --dump-config` 离线校验安全模式覆盖层 |
| `safe-mode -Rebuild` | 强制重算覆盖层（默认按 profile 变化自动缓存） |
| `safe-mode -Show` | 打印覆盖层内容与将禁用的行 id |
| `stop -DryRun` | **演练**：只报告将要结束哪些进程，绝不执行 |

> 在任意 PowerShell 里直接敲 `start` 也能用：脚本检测到自己不在 WT 标签页时，会自动把工作搬进命名窗口。

---

## 4. config.json 参考

```jsonc
{
  "chromePath": null,            // Chrome 路径；null=自动探测（标准路径→注册表）
  "edgePath": null,              // Edge 路径（仅回退用）
  "dshMode": "npx",              // auto | npx | global
  "port": 3080,                  // 服务端口
  "desktopPath": null,           // 桌面路径（兼容 OneDrive 重定向）
  "shortcutName": "DeepSeek-Harness",
  "profile": "web",              // dsh profile
  "windowMode": "terminal",      // terminal=单窗口双标签页 | hidden=无窗口（旧形态）
  "terminalWindowName": "DeepSeek-Harness",  // WT 命名窗口（同名即复用，不重复开窗）
  "autoSafeMode": true,          // 启动失败后自动用安全模式重试一次
  "keepPlugins": ["dsh-market"], // 安全模式保留的插件（按包名或行 id 匹配）
  "safeModeExtraIds": [],        // 追加禁用的行 id
  "startTimeoutSec": 90,         // 就绪超时（含首次 npx 下载）
  "logMaxMB": 5                  // 日志超过该大小，开服时轮转为 web.1.log
}
```

---

## 5. 安全模式详解

**触发**：首次启动满足任一条件 → 自动用安全模式再启动一次（`autoSafeMode`）

- 子进程在就绪前退出（插件树加载失败会让 dsh 直接退出）；
- 输出命中失败签名（`plugin tree failed to load` / `failed to import loader entry` /
  `failed to apply loader entry` / `does not provide an export named` / `Cannot find module` 等）；
- 超过 `startTimeoutSec` 仍未捕获就绪 URL（例如某个插件把启动挂住）。

**做法**：`dsh --profile web --patch "runtime\safe-mode.patch.yml" --no-open --port 3080`
其中覆盖层是「非破坏性补丁列表」，形如：

```yaml
- id: agent-teams
  disabled: true
```

**覆盖层怎么来的**（`safe-mode -Show` / `doctor` 都能看）：

1. 读 `<DSH home>\profiles\web\package.json` 的 `dsh.profile.bundles`（挂载清单）；
2. 跳过保留项：`@deepseek-ai/dsh-base`、`@deepseek-ai/dsh-web-app`（核心，硬编码保留）
   + `keepPlugins`（默认 `dsh-market`）；
3. 其余每个 bundle：读它的 `dsh.bundle.patch`，抽出所有行 id → 置 `disabled: true`；
4. **核心行保护**：核心 bundle 自带的行 id 一律不动
   （实测有第三方插件复用核心行 id：`dsh-file-upload` 的行 id 就是 web-app 的 `file-upload`，
   若不保护，在没有装该插件的 home 里会误关核心的“文件上传”能力）；
5. 追加基线兜底 id 与 `safeModeExtraIds`，去重后写文件；
   不存在的 id 只会让 Loader 打一行 `entry not found` 警告，**不会导致启动失败**。

**退出安全模式**：安全模式是**每次启动**的临时状态，不写任何持久配置。
修好插件（在安全模式里打开 GUI → 插件市场更新/卸载问题插件）后，重新双击即回到正常模式。

**当前本机状况（2026-09-14 实测）**：`~\.dsh` 这个 home 的正常模式启动**会失败**，元凶是
`@nanmicoder/dsh-agent-teams`（`ctx.subagents.registerContinuableSetup is not a function`），
所以现在双击会走安全模式；想彻底恢复，需在安全模式里更新或卸载该插件。

---

## 6. 故障排查

| 现象 | 处理 |
|---|---|
| 双击后停在「安全模式」 | 正常模式有插件不兼容。看 Tab2 / `logs\web.log` 里的 `failed to import loader entry X`，在安全模式的 GUI 里更新/卸载 X |
| 窗口没出现 | 看是否被任务栏折叠；`status` 看模式；确认装了 Windows Terminal（否则 `windowMode` 应为 `hidden`） |
| 弹窗「端口被其他程序占用」 | 换 `config.json` 的 `port`，或处理占用方（脚本绝不强杀陌生进程） |
| 弹窗「启动超时」 | 看日志；首次运行 npx 要下载，可调大 `startTimeoutSec`；或 `dshMode: global` |
| GUI 显示 `dsh web authentication required` | 说明不是通过本启动器打开的（裸 URL）。用 `status` 里的地址，或重新双击 |
| 日志中文乱码 | 本版已修（见第 7.1 节）。若又出现，检查是否有人把 `cmd` 重定向改回了 PowerShell 管道 |
| 日志里有 `patch: entry "X" not found` | 安全模式覆盖层列了当前 profile 不存在的 id，无害 |
| 桌面图标没 logo | 重跑 `setup.cmd` |
| 想保留现场做实验 | 用 `start -Port 3099`（别拿 3080 做破坏性实验，见第 7.2 节） |

---

## 7. 本次改造复盘

> 时间：2026-09-14。以下每条都有实测证据；第 7.2 节是我这次**真正犯下的错误**，建议细读。

### 7.1 四个真实根因（旧版为什么坏）

**(1) 新版 DSH 给 Web GUI 加了进程令牌鉴权 → 旧探活永远失败**
- `dsh@0.1.5-rc.1`（npx 缓存，2026-09-10 11:53 拉取）起，`GET /` 不带 `?token=` 一律 **401**：
  `dsh web authentication required; reopen the URL printed by dsh web.`
- 旧脚本 `Test-DshHttp` 是「GET / 后匹配页面标题」→ 在当前版本**必然 false** →
  服务明明起来了却弹「HTTP 校验失败」并 `exit 1`，Chrome 根本没机会打开。
- 实测：对正在运行的本机 DSH 发同一条请求得到 401；日志里 15:59 那次其实已经打印了
  `dsh web: http://127.0.0.1:3080/?token=…`（= 服务已就绪），用户却看不到界面。
- 修法：就绪判定改为抓这一行 URL，并**用带令牌的 URL 打开 Chrome**（首次访问 303 落 cookie）。

**(2) 插件与新版 DSH API 不兼容 → 插件树加载失败 → 进程直接退出**
- 日志实证：`plugin tree failed to load: … failed to import loader entry better-sidebar …`
  `'@deepseek-ai/dsh-settings' does not provide an export named 'settingsNamespace'`，
  最后一行 `Node.js v24.15.0` = 进程退出，端口永不监听。
- 修法：安全模式（第 5 节）。本次实测它就真的救回来了：`attempt=2 mode=safe`，安全模式段内插件报错 0。

**(3) 日志乱码（不可逆）**
- 旧 `run-server.ps1` 用 `& npx … 2>&1 | ForEach-Object { … } | Out-File -Encoding utf8`：
  PS 5.1 解码**原生程序输出**用的是 `[Console]::OutputEncoding`（本机 GBK/936），而 node 写的是 UTF-8
  → `已加载 账本` 变成 `宸插姞杞?璐︽湰`；GBK 无法表示的字节被替换成 `?`（旧日志里 42 个，**已永久丢失**）；
  `2>&1` 还把 stderr 变成 ErrorRecord 对象，渲染出莫名的 `System.Management.Automation.RemoteException` 行。
- 修法：子进程输出由 `cmd /c … > file` **原样字节落盘**，读取方显式按 UTF-8 解码；
  同时 `[Console]::OutputEncoding = UTF8` 保证终端标签页里的中文也正常。
- 实测：新日志乱码样本 0、`RemoteException` 0、正常中文可读。
  ⚠️ 旧日志（46KB、含 42 个不可恢复的 `?`）在联调时被我**直接删除、没有归档**——
  正确做法是改名归档（如 `web.pre-encoding-fix.log`）。其中的关键证据已摘录在本节与 7.1(2)，但原始文件不可找回。

**(4) 两个命令行窗口**
- 本机 `HKCU\Console\%%Startup` 未设置 + Win11 build 26200 → 默认终端是 Windows Terminal。
  实测：用 `-WindowStyle Hidden` 启动 PowerShell，**依然产生了一个可见的 `WindowsTerminal` 窗口**
  （标题 `Windows PowerShell`）。旧版有两个这样的隐藏进程（启动器 + 服务）→ 两个可见窗口。
- 修法：干脆不用隐藏进程：快捷方式直接 `wt.exe -w <命名窗口> nt …` 拉起**第一个标签页**，该标签页就是入口/服务；
  日志标签页由服务用 `wt -w <同名> nt` 补进**同一个窗口**。
- 实测：整个启动过程 WT 可见窗口数 = 1，标题 `DSH 服务 · 3080 · 安全模式`（中文标题无乱码，
  靠 `$Host.UI.RawUI.WindowTitle` 在进程内设置 + `--useApplicationTitle`，避免中文经命令行传递）。

### 7.2 ⚠️ 我操作中的重大失误：stop 误杀了 DSH Desktop 桌面版

**发生了什么**：我在 `stop` 里加了一段“顺手清理残留 dsh 进程”的逻辑：

```powershell
# ❌ 危险写法（已删除，勿再加回）
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -match '@deepseek-ai[\\/]dsh' -and $_.CommandLine -match '\bweb\b|--profile' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

DSH Desktop（Electron 桌面版）**也有自己的 node 宿主**，位于
`D:\…\DSH Desktop\resources\app\node_modules\node\bin\node.exe`，其命令行同样含 `@deepseek-ai/dsh`。
执行 `stop` 时它被这个过滤器命中并被强杀 → **你的桌面版直接退出、重进恢复模式**。

**为什么会犯**：原版脚本的 `stop` 只杀「监听 3080 端口的进程」，是安全的；
我为了“清理启动失败后的残留”把口径从「我占用的资源」放宽成了「看起来像 dsh 的东西」——
**一旦按“像什么”去批量杀进程，就一定会打到别人的进程**。而 DSH 生态里“像 dsh 的进程”至少三种：
npx 启动的 web 服务、全局 dsh、DSH Desktop 的 node 宿主。

**修法（现在的红线，写在 `lib\common.ps1` 原位注释里）**：

1. 删除了那个通用清理函数，并留下“禁止加回”的说明；
2. `stop` 只允许两种精确口径：
   - ① **监听目标端口**的进程，且命令行含 `@deepseek-ai\dsh|DeepSeek-Harness`；
   - ② `runtime\state.json` 里记录的**本次启动**包装进程 PID（精确到这一棵进程树）；
3. 两种口径里都**先排除**命令行含 `DSH Desktop|dsh-desktop` 的进程，命中则只告警、绝不结束；
4. 判据放宽为“命令行含 dsh”（不再要求进程名是 `node`）——实测监听者可能是 npx/cmd 中间进程；
5. 停止流程保留 `status=stopping` 哨兵：即使直接匹配没命中，监督器（Tab1）看到哨兵也会结束自己的子进程树；
6. 提供 `stop -DryRun` 演练；破坏性验证一律换端口（`-Port 3099`）做。

**验证**：`stop -DryRun` 演练后 DSH Desktop 进程数不变（6）、3080/3099 无残留；
`-Port 3099` 的 hidden 模式实测收尾后「dsh 残留 0、Chrome 窗口已关、DSH Desktop 完好」。

**可以带走的教训**：

- 破坏性命令的匹配范围**绝不要超过你实际拥有的资源**（端口、PID、自己的进程树）；
- 在一个进程生态里，`命令行关键字` ≠ `身份`；
- 任何 `kill`/`rm` 类代码都要配 `-DryRun`，并且**第一次真跑要在隔离资源上**（换端口/换目录）；
- 改别人的启动器要假设“用户同时还在用另一个入口（这里是 DSH Desktop）”，
  凡共享资源（进程/端口/配置目录）必须先做所有权判断。

### 7.3 其他被验证到的工程坑（都已在代码里修/规避）

| 坑 | 现象 | 处理 |
|---|---|---|
| **两套 DSH home** | `$env:DSH_HOME` 在 DSH Desktop 里被指向 `%APPDATA%\dsh-desktop\harness`，而双击启动器时没有这个变量 → `~\.dsh`。我第一次生成覆盖层时读了**桌面版的 home**，得到 14 个 bundle（与真实启动的 11 个完全不同） | 代码统一用 `Get-DshHome()`（尊重 `DSH_HOME`，否则 `~\.dsh`）；覆盖层缓存键加入 home+profile，跨 home 不复用；**测试时必须清掉 `DSH_HOME` 才等于双击环境** |
| **核心行 id 撞名** | 第三方 `dsh-file-upload` 的行 id 是 `file-upload`，而 `@deepseek-ai/dsh-web-app` 也有同名核心行 → 覆盖层会误禁核心能力 | 增加“核心行保护集”（从核心 bundle 的 patch 抽出全部行 id），命中则跳过并在 `safe-mode -Show` 里提示 |
| **`--dump-config` 不是纯只读** | 它会重写 profile 的 `cordis.yml`（内容与原来逐字节相同） | 只在 `doctor -Verify` 显式调用，不进启动热路径 |
| **PS 5.1 `Start-Process -PassThru` 无 `-Wait` 时 `ExitCode` 为 `$null`** | 日志出现「（退出码 ）」 | 读 ExitCode 前先 `WaitForExit(1000)` |
| **`edit` 类工具会剥掉 .ps1 的 BOM** | 无 BOM 的 UTF-8 脚本被 PS 5.1 按 GBK 读 → 中文注释乱码 → **直接语法报错**（`意外的标记 ")"`） | 每次改完 .ps1 立刻补 BOM + 用 AST 解析器做语法检查（第 8 节给了命令） |
| **受限会话里 npx 会 EPERM** | agent 沙箱下 `npx` 写 `_cacache\tmp` 被拒 | 校验改用**离线组合**：直接 node 导入 `@deepseek-ai/dsh-app-boot` 的 `loadProfile`/`composeEntries`（与 `--dump-config` 同一套合成函数），只读、无需启动服务 |
| **联调时“清理”变成了删除** | 我清空 `logs\web.log` 时直接删文件，历史证据丢失（见 7.1(3)） | 规则：任何“重置/清理”先改名归档（`xxx.pre-<原因>.log` 或 `.bak`），确认无用再删 |
| **`$PID` 是只读自动变量** | 我把函数参数命名为 `$Pid`，调用时抛 `Cannot overwrite variable Pid because it is read-only or constant`，`stop` 中途中断（靠 `status=stopping` 哨兵才收住尾巴） | 参数名用 `$TargetPid`/`$AncestorPid`；这类错误只有**运行到那一行**才会暴露，所以关键路径必须真跑一次 |
| **护栏判据不能按“路径/名字”** | 我第一版护栏写“命令行含 `DSH Desktop` 就跳过”，结果某些会话里 `node` 解析到桌面版自带的 `…\DSH Desktop\…\node.exe`，**把我们自己的服务也跳过了** | 归属判断要用**进程树**（state.pid 的子孙）；`--expose-internals` 才是桌面版宿主的可靠特征 |
| **中文字符串走命令行会被编码搞乱** | 我在 `pwsh -Command` 的字符串里写中文提示，命令本身被解成乱码字符导致语法错误 | 脚本文件内用中文没问题（UTF-8 BOM）；**传给命令行的临时脚本尽量用 ASCII**，长脚本写进 .ps1 再执行 |

### 7.4 覆盖层正确性的两种验证方式（推荐都跑）

```powershell
# 方式 A：官方 CLI 离线合成（会重写 profile 的 cordis.yml，内容不变）
powershell -ExecutionPolicy Bypass -File .\DeepSeek-Harness.ps1 doctor -Verify

# 方式 B：直接调用 DSH 自己的合成函数做「有/无覆盖层」差集，只读、不写任何文件
node .\tools\verify-overlay.mjs "$env:LOCALAPPDATA\npm-cache\_npx\<hash>\node_modules\@deepseek-ai" "$env:USERPROFILE\.dsh" .\runtime\safe-mode.patch.yml
```

实测结果（`~\.dsh`）：覆盖层新增禁用 10 个插件行，`dsh-market` 保留、核心行 0 误禁；
（DSH Desktop home）：新增禁用 12 个，`file-upload` 因核心行保护被跳过并给出提示。

### 7.5 本次验收记录

| 验收项 | 结果 |
|---|---|
| 双击（快捷方式实测）→ 单窗口双标签页 | ✅ WT 可见窗口 = 1，标题 `DSH 服务 · 3080 · 安全模式` |
| 服务真起来 | ✅ `status=running`，3080 监听，令牌 URL 探活 **303** |
| 浏览器进 GUI | ✅ `chrome --app` 进程 = 1（带令牌 URL） |
| 自动安全模式 | ✅ 正常模式真失败 → `attempt=2 mode=safe` → 就绪；安全模式段内插件报错 0 |
| 日志编码 | ✅ 乱码样本 0 / `RemoteException` 0 / 正常中文命中正常 |
| `stop` | ✅ 端口释放、dsh 残留 0、Chrome 独立窗口关闭、状态 `stopped`、窗口自动关闭；输出为 `已结束本次启动的进程树: PID=…（cmd.exe）` + `已结束 dsh 服务进程: PID=…（node）` |
| hidden 回退模式 | ✅ 端口 3099 实测：无终端窗口、服务起来、Chrome 打开、收尾零残留 |
| `doctor -Json/-Verify` | ✅ 报告与覆盖层校验均正常；`dsh-market` 行存在且未被禁用 |
| 进程安全 | ✅ 全流程 DSH Desktop 进程数保持 6，未被波及 |

---

## 8. 平台与语言坑位

1. **Windows Terminal 是硬依赖**（单窗口双标签页）。没有时自动回退 `windowMode: hidden`（无窗口、日志只写文件、失败弹窗）——但注意：**在 Win11 默认终端=WT 的机器上，隐藏进程仍会显示成窗口**，所以不要用“隐藏进程”当默认方案。
2. **`.ps1` 必须 UTF-8 with BOM**。PS 5.1 对无 BOM 的 UTF-8 会按系统 ANSI(GBK) 读，中文变乱码甚至语法错误。改完立刻执行：
   ```powershell
   $p='lib\common.ps1'
   $b=[IO.File]::ReadAllBytes($p)
   if(-not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)){ [IO.File]::WriteAllBytes($p,[byte[]](0xEF,0xBB,0xBF)+$b) }
   $err=$null; $t=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8)
   [void][System.Management.Automation.Language.Parser]::ParseInput($t,[ref]$null,[ref]$err); $err
   ```
3. **原生程序输出编码**：PS 5.1 用 `[Console]::OutputEncoding` 解码，务必显式设成 UTF-8；能不用管道就别用（本版改成文件重定向，更彻底）。
4. **不要写 PS 7 语法**（`??`、三元、`&&`、`-Encoding utf8NoBOM`），目标环境是 5.1。
5. **读 JSON/YAML 一律 `[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8)`**：否则中文包描述会解析失败。
6. **`Start-Process -ArgumentList` 传单个字符串**（不传数组）才不会破坏参数里的引号；`;` 在 PS 里是语句分隔符，交给 `wt` 时必须作为**一个完整字符串**传递（本版只用单条 `nt` 命令，天然规避）。
7. **配置文件与运行时文件**：`config.json`、`state.json` 用 UTF-8；`safe-mode.patch.yml` 写**不带 BOM**（交给 js-yaml 解析）。
8. `.ps1` 双击默认用记事本打开，所以入口必须是 `.lnk`/`.cmd`，不要裸 .ps1。

---

## 9. 双机部署流程

1. 把整个 `DeepSeek-Harness` 目录拷到另一台电脑桌面（U 盘/网盘均可）。
2. 目标机先装：**Windows Terminal**（Microsoft Store 搜索安装）、Node.js、Chrome。
3. 打开 PowerShell：
   ```powershell
   cd <另一台桌面>\DeepSeek-Harness
   .\setup.cmd                      # 生成快捷方式（自动判断 WT 是否可用）
   powershell -ExecutionPolicy Bypass -File .\DeepSeek-Harness.ps1 doctor -Json
   ```
4. 按 `environment-report.json` 与第 10 节清单比对差异，必要时改 `config.json`，重跑 `setup.cmd`。
5. 双击桌面图标验证：应出现**一个**终端窗口（两个标签页）+ Chrome 独立窗口；再双击一次不应重复开窗/开服务。

> 两台机器各自独立的 `config.json`、`logs\`、`runtime\`；无需同步。

---

## 10. 环境事实清单

| # | 项目 | 本机已核实值 | 另一台机器上的探测命令 |
|---|------|------------|----------------------|
| 1 | 操作系统 | Windows 11 (build 26200) | `[System.Environment]::OSVersion.VersionString` |
| 2 | PowerShell | 5.1（Windows PowerShell） | `$PSVersionTable.PSVersion` |
| 3 | 用户主目录 | `C:\Users\yuenanmu` | `$env:USERPROFILE` |
| 4 | 桌面路径 | `C:\Users\yuenanmu\Desktop` | `[Environment]::GetFolderPath('Desktop')` |
| 5 | 默认浏览器 | Edge (`MSEdgeHTM`)——`dsh web` 会自动开它 | `(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice').ProgId` |
| 6 | Chrome | `C:\Program Files\Google\Chrome\Application\chrome.exe` | 注册表 `…\App Paths\chrome.exe` |
| 7 | Edge（回退） | `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe` | 注册表 `…\App Paths\msedge.exe` |
| 8 | **Windows Terminal** | `C:\Users\yuenanmu\AppData\Local\Microsoft\WindowsApps\wt.exe`（1.24） | `Get-Command wt.exe` / `Get-AppxPackage Microsoft.WindowsTerminal` |
| 9 | Node.js | v24.14.1 装在 `D:\Program Files\nodejs\`（非标准位置） | `Get-Command node \| Select-Object Source` |
| 10 | npm | 11.11.0 | `npm --version` |
| 11 | npx 缓存 dsh | `%LOCALAPPDATA%\npm-cache\_npx\1e7f6d9597241db0\`（**哈希每台不同**），当前 `0.1.5-rc.1` | 通配 `_npx\*\node_modules\@deepseek-ai\dsh\package.json` |
| 12 | dsh 安装方式 | 仅 npx 缓存，**未全局安装** | `Get-Command dsh` |
| 13 | DSH home（web/CLI） | `C:\Users\yuenanmu\.dsh`（profile `web`） | `$env:DSH_HOME`；未设置则为 `~\.dsh` |
| 14 | **DSH home（桌面版）** | `C:\Users\yuenanmu\AppData\Roaming\dsh-desktop\harness`（两套 home，互不影响） | 看 DSH Desktop 进程的环境变量 `DSH_HOME` |
| 15 | 默认终端宿主 | 未设置 `HKCU\Console\%%Startup` → Win11 默认 **Windows Terminal** | `Get-ItemProperty 'HKCU:\Console\%%Startup'` |
| 16 | 执行策略 | 脚本统一用 `-ExecutionPolicy Bypass` | `Get-ExecutionPolicy -List` |

> `doctor` 在 DSH 会话里运行时，可能把宿主注入的 node（如桌面版的 `.desktop-bin\node.cmd`）报成 Node.js ——
> 那是会话环境所致，双击环境下会显示系统 Node。

---

## 11. Agent 交接协议

给另一台机器上的 AI/agent：

1. 跑 `doctor -Json`，读 `environment-report.json`，与本 README 第 10 节逐项对照。
2. 差异项写进 `config.json`（**不要改脚本逻辑**），重点看：Chrome / Windows Terminal / Node / desktopPath / dshMode。
3. 跑 `setup.cmd` 生成快捷方式，再 `doctor -Verify` 确认安全模式覆盖层合成正常。
4. 双击图标验证：**一个**终端窗口、两个标签页、Chrome 独立窗口、日志无乱码；`start` 第二次不应重复开窗。
5. 若启动失败：看 `logs\web.log` 的 `failed to import loader entry X`，在安全模式 GUI 的插件市场里更新/卸载 X。
6. **红线**：不要用“按命令行匹配批量结束 dsh 进程”的方式收尾（第 7.2 节事故）；停止只用 `stop`。

---

## 12. 文件结构

```
DeepSeek-Harness\
├─ DeepSeek-Harness.ps1   主入口/CLI：start | stop | status | doctor | safe-mode | serve | tail-log
├─ lib\common.ps1         共享库：配置/路径/端口与令牌探测/状态文件/日志/安全模式覆盖层生成
├─ lib\service.ps1        角色：Tab1 服务监督器（tee 日志/就绪判定/开 Chrome/安全模式重试）+ Tab2 日志跟随
├─ tail-log.ps1           Tab2 入口（只读跟随 logs\web.log）
├─ run-server.ps1         兼容入口（等价于 serve）
├─ setup.ps1 / setup.cmd  安装：快捷方式（wt 入口）/图标/可选的停止快捷方式
├─ config.json            每机配置（唯一需要改的文件）
├─ environment-report.json doctor -Json 的产物
├─ tools\verify-overlay.mjs  离线校验安全模式覆盖层（只读，调用 DSH 自身的合成函数）
├─ assets\                图标素材
├─ logs\web.log           服务日志（UTF-8 with BOM，中文可读；>5MB 自动轮转）
├─ logs\web.1.log         上一份轮转日志
└─ runtime\               运行时产物：state.json / safe-mode.patch.yml / safe-mode.key（可随时删）
```

### 状态文件字段（`runtime\state.json`）

```jsonc
{
  "runId": "20260914T132217-e8bc30",  // 每次启动唯一；标签页据此判断“我是否已被新启动接管”
  "status": "running",                // starting | running | stopping | stopped | failed
  "mode": "safe",                     // normal | safe
  "port": 3080, "pid": 29400,         // pid = 本次启动的 cmd 包装进程
  "url": "http://127.0.0.1:3080/?token=…",
  "attempt": 2, "startedAt": "…", "updatedAt": "…", "lastError": null
}
```

> 历史备注：旧版实现（无安全模式、按页面标题探活、隐藏进程、日志 GBK 乱码）已由本版替代。
