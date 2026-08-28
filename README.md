# DeepSeek-Harness 一键启动（双机统一版）

把 `npx @deepseek-ai/dsh web`（会默认打开 Edge、每次都要敲命令）变成**双击桌面图标即用**的桌面小程序：
无黑窗、无 Edge 弹出，打开 Chrome 独立窗口（无地址栏），任务栏显示 dsh logo。

- **一键启动**：双击桌面 `DeepSeek-Harness` 图标即可（服务未运行则自动后台启动 + 打开窗口；已在运行则直接开窗口）。
- **一键停止**：`DeepSeek-Harness.ps1 stop`（或 `setup.ps1 -StopShortcut` 生成的"停止"快捷方式）。
- **双机统一**：同一份文件零硬编码，拷贝到任何 Windows 机器运行一次 `setup.cmd` 即完成部署。

---

## 目录

1. [快速开始（本机）](#1-快速开始本机)
2. [双机部署流程（另一台电脑）](#2-双机部署流程另一台电脑)
3. [环境事实清单（重点：两台机器位置不同的东西）](#3-环境事实清单)
4. [config.json 配置参考](#4-configjson-配置参考)
5. [已知坑位（为什么这些位置会不一样）](#5-已知坑位)
6. [Agent 交接协议（给另一台电脑上的 AI 用）](#6-agent-交接协议)
7. [故障排查](#7-故障排查)
8. [可选优化](#8-可选优化)

---

## 1. 快速开始（本机）

```powershell
# ① 安装（生成桌面快捷方式 + 图标）
C:\Users\PC\Desktop\DeepSeek-Harness\setup.cmd

# ② 日常使用：双击桌面 "DeepSeek-Harness" 图标

# ③ 常用命令（在 PowerShell 中执行）
powershell -ExecutionPolicy Bypass -File "C:\Users\PC\Desktop\DeepSeek-Harness\DeepSeek-Harness.ps1" status   # 查看状态
powershell -ExecutionPolicy Bypass -File "C:\Users\PC\Desktop\DeepSeek-Harness\DeepSeek-Harness.ps1" stop    # 停止
powershell -ExecutionPolicy Bypass -File "C:\Users\PC\Desktop\DeepSeek-Harness\DeepSeek-Harness.ps1" doctor  # 环境诊断
```

> 注意：`stop` 会结束占用 3080 端口的 dsh 服务进程。**如果该进程正在运行 DeepSeek Harness 网页界面（含本会话），停止后界面会断开**——这是预期行为（服务即此进程）。

## 2. 双机部署流程（另一台电脑）

1. 把整个 `DeepSeek-Harness` 文件夹拷贝到另一台电脑的桌面（U 盘 / 网盘均可）。
2. 在另一台电脑上打开 PowerShell，运行：

   ```powershell
   cd <另一台桌面>\DeepSeek-Harness
   powershell -ExecutionPolicy Bypass -File .\DeepSeek-Harness.ps1 doctor   # 先看环境报告
   .\setup.cmd                                                               # 生成快捷方式
   ```

3. 若 `doctor` 报告与第 3 节清单有差异（如 Chrome 路径不同），按第 4 节修改 `config.json` 后重新运行 `setup.cmd`。
4. 双击桌面 `DeepSeek-Harness` 图标验证。

> 两台机器**各自独立**的 `config.json`、`logs\` 与图标，互不冲突；无需同步。

## 3. 环境事实清单

> 下表是本机（第一台电脑）**已核实**的值与"在另一台机器上如何探测"的命令。**两台机器上位置不一样的，几乎全在这里。**
> 另一台机器上的 agent 应逐项运行右侧命令，把结果与本机值对比。

| # | 项目 | 本机已核实值 | 另一台机器上的探测命令 |
|---|------|------------|----------------------|
| 1 | 操作系统 | Windows 11 (build 26200) | `[System.Environment]::OSVersion.VersionString` |
| 2 | PowerShell | 5.1（Windows PowerShell） | `$PSVersionTable.PSVersion` |
| 3 | 用户主目录 | `C:\Users\PC` | `$env:USERPROFILE` |
| 4 | 桌面路径 | `C:\Users\PC\Desktop`（**无 OneDrive 重定向**） | `[Environment]::GetFolderPath('Desktop')`（若与 `$env:USERPROFILE\Desktop` 不同 → 被 OneDrive 重定向） |
| 5 | 默认浏览器 | **Edge**（ProgId: `MSEdgeHTM`）—— 这是 `dsh web` 打开 Edge 的根源 | `(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice').ProgId` |
| 6 | Chrome | `C:\Program Files\Google\Chrome\Application\chrome.exe` | 注册表 `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe`（最可靠，两端都有注册） |
| 7 | Edge（仅回退用） | `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe` | 注册表 `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe` |
| 8 | Node.js | v24.14.1，**装在 D 盘** `D:\Program Files\nodejs\node.exe`（非标准位置！） | `Get-Command node \| Select-Object Source` 与 `node --version` |
| 9 | npm | 11.11.0，prefix `C:\Users\PC\AppData\Roaming\npm` | `npm --version`、`npm config get prefix` |
| 10 | npx 缓存目录 | `C:\Users\PC\AppData\Local\npm-cache\_npx\1e7f6d9597241db0\`（**哈希目录每台机器不同**） | `Get-ChildItem "$env:LOCALAPPDATA\npm-cache\_npx\*\node_modules\@deepseek-ai\dsh" -ErrorAction SilentlyContinue` |
| 11 | dsh 安装方式 | **仅 npx 缓存**，版本 0.1.1-rc.2；**未全局安装** | `Get-Command dsh`（有输出=已全局安装）；版本看第 10 项里的 `package.json` 或 `npx -y @deepseek-ai/dsh --version` |
| 12 | dsh web 参数 | 默认端口 **3080**；支持 `--no-open`（不打开默认浏览器） | `npx -y @deepseek-ai/dsh web --help` |
| 13 | DSH 数据目录 | `$DSH_HOME=C:\Users\PC\.dsh`（含 profiles / sessions / storages / settings.yaml） | `$env:DSH_HOME`；未设置则为 `~\.dsh` |
| 14 | 图标素材 | dsh 自带经典 logo：`...\@deepseek-ai\dsh-web-frontend\dist\favicon.svg`（任务栏图标自动取它） | 见第 10 项通配路径，追加 `\dsh-web-frontend\dist\favicon.svg` |
| 15 | 执行策略 | 脚本全部用 `-ExecutionPolicy Bypass` 启动，无需关心 | `Get-ExecutionPolicy -List` |

**本机 `doctor` 报告存档**：`environment-report.json`（运行 `DeepSeek-Harness.ps1 doctor -Json` 重新生成）。

## 4. config.json 配置参考

`config.json` 是**另一台机器的 agent 修改的唯一入口**：填了就用填的值（来源显示为 `[config.json]`），留空/`null` 就自动探测。**优先级：config.json > 自动探测。**

```json
{
  "chromePath": null,        // Chrome 完整路径；null=自动探测（标准路径→注册表）
  "edgePath": null,          // Edge 完整路径；null=自动探测（仅作 Chrome 缺失时的回退）
  "dshMode": "auto",         // auto | npx | global
                             //   auto   = 有全局 dsh 用 dsh，否则 npx（推荐）
                             //   npx    = 强制 npx -y @deepseek-ai/dsh
                             //   global = 强制 PATH 里的 dsh（未装则回退 npx 并告警）
  "port": 3080,              // 服务端口（两端默认一致即可；若本机 3080 被占可改）
  "desktopPath": null,       // 桌面路径；null=GetFolderPath('Desktop')（兼容 OneDrive 重定向）
  "shortcutName": "DeepSeek-Harness"  // 桌面快捷方式名
}
```

示例：另一台机器的 Chrome 装在非标准位置时：

```json
{
  "chromePath": "D:\\Software\\Chrome\\Application\\chrome.exe"
}
```

## 5. 已知坑位

1. **默认浏览器是 Edge**（UserChoice=`MSEdgeHTM`）→ `dsh web` 会自动打开 Edge。本方案用官方参数 `--no-open` 关闭自动打开，再由脚本显式启动 Chrome `--app` 独立窗口。**不要**用"改默认浏览器"来绕。
2. **Node.js 可能装在非标准盘符**（本机在 `D:\Program Files\nodejs`）。脚本不写死 Node 路径，通过 PATH/npx 调用；`npx.cmd` 在 `%APPDATA%\npm` 下。
3. **npx 缓存哈希目录每台机器不同**（`_npx\1e7f6d9597241db0\`）。脚本一律**通配发现**，禁止写死该哈希。
4. **桌面路径可能被 OneDrive 重定向**。脚本用 `[Environment]::GetFolderPath('Desktop')`，必要时 `config.json` 的 `desktopPath` 覆盖。
5. **DSH 数据目录随用户与 `DSH_HOME` 变化**（默认 `~\.dsh`）。换机器后会话/配置不共享——这是 dsh 自身行为，与启动器无关。
6. **`stop` 会杀 3080 上的 dsh 进程**。仅当进程名为 `node.exe` 且命令行含 `@deepseek-ai\dsh` 时才会杀（避免误杀其他程序）。若 3080 被无关程序占用，启动时会弹窗报错并退出，**绝不强杀**。
7. **PowerShell 5.1 语法限制**：脚本刻意避免 `??`、三元、`&&` 等 7+ 语法，改脚本时请保持兼容。
8. **.ps1 双击默认用记事本打开**：所以桌面入口是 `.lnk` 快捷方式 + `setup.cmd`，不是裸 .ps1。
9. **.ps1 文件必须保持 UTF-8 带 BOM 编码**：Windows PowerShell 5.1 对无 BOM 的 UTF-8 会按系统 ANSI(GBK) 误读中文，导致乱码甚至语法错误。三个 .ps1 已带 BOM；**任何编辑器/agent 修改后请保持 UTF-8 with BOM**（VS Code 右下角编码选 `UTF-8 with BOM`；或用记事本另存为时选 UTF-8）。可用下面的命令一键恢复：
   ```powershell
   $b = [IO.File]::ReadAllBytes('DeepSeek-Harness.ps1')
   if (-not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
     [IO.File]::WriteAllBytes('DeepSeek-Harness.ps1', [byte[]](0xEF, 0xBB, 0xBF) + $b)
   }
   ```

## 6. Agent 交接协议

> 以下步骤写给**另一台电脑上的 AI/agent**，让它独立完成部署。它应能读本文件、运行 PowerShell、编辑 JSON。

**目标**：在另一台 Windows 电脑上，让桌面出现可用的 `DeepSeek-Harness` 一键启动图标。

1. **环境盘点**：运行
   ```powershell
   powershell -ExecutionPolicy Bypass -File ".\DeepSeek-Harness.ps1" doctor -Json
   ```
   并读取生成的 `environment-report.json`。
2. **逐项对照**本 README 第 3 节表格，找出与本机不同的项。重点关注：
   - `chrome` 是否找到（未找到 → 另一台可能没装 Chrome，需装，或用 `edgePath`）
   - `node` / `npm` 是否存在（缺失 → 先安装 Node.js，这是 DSH 的前置依赖）
   - `desktopPath` 是否与预期桌面一致（OneDrive 重定向）
   - `globalDsh` / `npxCacheDsh`（决定 `dshMode` 用 auto 还是强制 npx）
3. **需要覆盖的项写入 `config.json`**（见第 4 节）。不要修改 `.ps1` 脚本逻辑。
4. **生成快捷方式**：运行 `.\setup.cmd`（或 `setup.ps1`）。
5. **验证**：
   - `DeepSeek-Harness.ps1 status` → 显示"未运行"或"运行中"；
   - 双击桌面 `DeepSeek-Harness` 图标 → 应出现 Chrome 独立窗口且页面标题为 DeepSeek Harness、无 Edge 弹出、无黑窗；
   - 若服务启动失败，查看 `logs\web.log` 与第 7 节。
6. **复核**：再次 `doctor`，确认覆盖项来源显示为 `[config.json]`。

**验收标准**：桌面图标存在且图标为 dsh logo；双击后 Chrome 独立窗口打开 DSH；任务栏窗口图标为 dsh logo；再次双击不重复启动服务；`stop` 能干净结束。

## 7. 故障排查

| 现象 | 处理 |
|------|------|
| 启动后长时间无窗口 | 看 `logs\web.log` 尾部；多半是 npx 首次联网下载或端口被占 |
| 弹窗"端口被其他程序占用" | 换 `config.json` 的 `port`，或处理占用方 |
| 弹窗"启动超时" | 看日志；`dshMode` 设为 `npx` 重试；确认能联网 |
| 桌面图标没有 logo | 重新运行 `setup.cmd`（自动刷新图标缓存）；或 `-IconPath` 指定图片 |
| 任务栏窗口不是 dsh logo | Chrome `--app` 窗口图标取页面 favicon；确认服务正常后**完全退出 Chrome 再重开**（favicon 有缓存） |
| `stop` 提示端口被疑似非 dsh 进程占用 | 该端口确实被其他程序占用，脚本已安全跳过 |
| 换机器后图标/日志旧内容还在 | 正常——每台机器各自独立目录，可删 `assets\`、`logs\` 后重跑 setup |

## 8. 可选优化

- **全局安装 dsh（推荐）**：两端各执行 `npm i -g @deepseek-ai/dsh`，再设 `"dshMode": "global"`。启动最快、彻底离线可用、无 npx 解析开销。
- **停止快捷方式**：`setup.cmd -StopShortcut` 生成桌面"停止"图标。
- **开机自启**：把 `DeepSeek-Harness.lnk` 复制到 `shell:startup`（`Win+R` 输入 `shell:startup` 回车），开机进桌面即服务就绪。
- **换 logo**：准备好 `logo.png`（建议 ≥256×256，透明背景）后运行 `setup.cmd -IconPath C:\路径\logo.png`；任务栏图标则需替换服务端 favicon（`dsh-web-frontend\dist\favicon.svg`），重开 Chrome 生效。

## 文件结构

```
DeepSeek-Harness\
├─ DeepSeek-Harness.ps1    主脚本（start/stop/status/doctor）
├─ run-server.ps1          后台服务进程（隐藏窗口 + 日志）
├─ setup.ps1               安装/修复/卸载（快捷方式、图标、PNG→ICO）
├─ setup.cmd               双击安装入口
├─ config.json             每机配置（agent 修改的唯一入口）
├─ README.md               本文件
├─ assets\DeepSeek-Harness.ico   桌面图标（可替换）
└─ logs\web.log            服务日志
```

> 历史备注：桌面原有的旧草稿 `DeepSeek-Harness.ps1`（端口错写 3000 的版本）已由本方案替代，不再使用。
