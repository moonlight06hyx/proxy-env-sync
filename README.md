# proxy-env-sync

![ci](https://github.com/moonlight06hyx/proxy-env-sync/actions/workflows/ci.yml/badge.svg)

**让 Antigravity 在「只用系统代理、不开 TUN」的情况下也能登录。**

一个启动器脚本：读 Clash Verge 的混合端口 → 探测端口是否在监听 → 只给即将启动的 Antigravity 进程带上 `HTTPS_PROXY`。不写全局环境变量，不建计划任务。

---

## 它解决什么问题

Windows 上的「系统代理」是一个注册表设置：

```
HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ProxyEnable / ProxyServer
```

- **Chromium / Electron / WinINet 程序**（Chrome、Edge、Antigravity 主界面、各类桌面 App）会读它 —— 所以开了系统代理，它们就正常走代理。
- **Go 程序不会读它。** Go 的 `net/http` 用 `ProxyFromEnvironment` 取代理，只看 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` 这三个环境变量。

Antigravity 的 `language_server.exe` 就是一个 Go 程序。于是会出现这种错位：

| 现象 | 原因 |
|---|---|
| 浏览器能打开 google.com，Antigravity 却登录不上 | 界面走系统代理了，`language_server.exe` 还在裸连 |
| 日志里 `Post "https://oauth2.googleapis.com/token": EOF` | 回调到了（`step=callback_received`），换 token 时连接被断 |
| `failure_kind=general_error last_step=callback_received` | 同上，卡在最后一步 |
| 只有开 TUN 模式才正常 | TUN 在网卡层劫持流量，与程序读不读环境变量无关 |

## 它做什么

把开始菜单 / 任务栏的 Antigravity 快捷方式改成先跑 `launch-antigravity.ps1`（经 `run-hidden.vbs`，不闪黑框）。启动时：

1. 从 Clash Verge 的配置里读出当前的混合端口
   - 主来源：`%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml` 里的 `verge_mixed_port`
   - 回退：`profiles\*.yaml` 里按修改时间最新的 5 个文件，找 `mixed-port`
   - 兜底：`7897`
2. 试着连一下 `127.0.0.1:<port>`（400 ms 超时）
   - **端口在监听** → 只在这次启动里注入

     ```
     HTTPS_PROXY = http://127.0.0.1:<port>
     HTTP_PROXY  = http://127.0.0.1:<port>
     NO_PROXY    = localhost,127.0.0.1,::1,*.local
     ```

     然后启动 `Antigravity.exe`（沿用原快捷方式的 `--remote-debugging-port=0`）。
   - **端口没在监听**（Clash 没开）→ 不带任何代理变量启动，等于纯直连。
3. 每次决定写一行日志：`proxy on, port 7897 is listening` / `no proxy, port 7897 is closed`。

所以：**换节点、换机场、换订阅都不用管**。机场只影响订阅里的节点，本地端口不变；端口变了下一个启动自动跟上。

### 为什么不是写全局环境变量

这个仓库最初是「每 2 分钟把 `HTTPS_PROXY` 写进 `HKCU\Environment`」的设计。它有两个真问题：

1. **代理关着时更糟。** 端口没人监听，所有认环境变量的程序（WorkBuddy、Codex、各种 node 工具、Go 程序）都会往死端口连，连国内站点也跟着失败 —— 这一版把 WorkBuddy 和 Codex 弄断过。
2. **改环境变量要广播。** 直接改注册表删值而不发 `WM_SETTINGCHANGE`，Explorer 会一直留着旧的一份，从开始菜单/托盘重开程序也没用，新进程继承的还是旧的。

所以现在把代理作用域收到「Antigravity 这一棵进程树」，其他程序完全不受影响。

## 性能

| 场景 | 影响 |
|---|---|
| 启动 Antigravity | 多一个 PowerShell 进程，约 0.3–0.5 s 后退出 |
| 常驻 | 0 —— 没有后台进程、没有计划任务 |
| 内存 | 单次启动峰值约 40 MB，随后回收 |

## 安装

```powershell
git clone https://github.com/moonlight06hyx/proxy-env-sync
cd proxy-env-sync
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

`install.ps1` 会：

- 备份开始菜单与任务栏的 `Antigravity.lnk`（`.lnk.bak`），然后把它们指向 `wscript.exe run-hidden.vbs launch-antigravity.ps1`
- 如果存在旧的 `proxy-env-sync` 计划任务，一并删掉
- 清掉旧版留下的用户级 `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY`（用会广播的 API，Explorer 立刻拿到新环境）

参数：`-AppPath "C:\...\Antigravity.exe"`、`-SkipShortcuts`、`-TaskName "proxy-env-sync"`（要删的旧任务名）。

## 验证

```powershell
# 看这次启动做了什么决定
Get-Content "$env:LOCALAPPDATA\antigravity-proxy-launch.log" -Tail 5

# 不启动、只打印决定
powershell -NoProfile -ExecutionPolicy Bypass -File .\launch-antigravity.ps1 -DryRun

# 看 language_server 是否真的在连本地代理端口
(Get-NetTCPConnection -OwningProcess (Get-Process language_server).Id -State Established).RemoteAddress |
  Group-Object | Sort-Object Count -Descending
```

出现一片 `127.0.0.1` 就说明它在连本地代理端口。要确认 Antigravity 真的能过代理，登录一次看 `%APPDATA%\Antigravity\logs\language_server.log` 里有没有 `[auth-login] ... outcome=success`。

## 实测：规则是怎么分流的

系统代理开着（`ProxyEnable=1`、`ProxyServer=127.0.0.1:7897`）、Clash Verge 在跑，订阅里的规则是
`geolocation-!cn → 机场` / `cn_domain → DIRECT` / `cn_ip → DIRECT` / `MATCH → 机场`。实测命中（原文来自 `logs\sidecar\sidecar_*.log`）：

| 请求 | 命中 | 结果 |
|---|---|---|
| `www.workbuddy.cn` | `RuleSet(cn_domain)` | DIRECT |
| `mcp-pan.baidu.com` | `RuleSet(cn_domain)` | DIRECT |
| `daily-cloudcode-pa.googleapis.com`（Antigravity 换 token 走的就是它） | `RuleSet(geolocation-!cn)` | `三毛机场2.0[日本aws-1]` |
| 不在国内规则里的中转站域名 | `MATCH` | 走机场；有的站不认这个出口，回 403 |

### 系统代理这个开关到底影响谁

| 场景 | Antigravity | Chrome / 微信 / WorkBuddy | Codex / cc-switch（reqwest、Go 一类） |
|---|---|---|---|
| Clash 在跑，系统代理开 | 走 7897，按规则分流 | 走 7897，按规则分流 | 不读系统代理 → 直连 |
| Clash 在跑，系统代理关 | 走 7897（启动器注入），按规则分流 | 直连 | 直连 |
| Clash 退出 | 直连（探测到端口关闭，不注入） | 直连 | 直连 |

也就是说：「系统代理」开关决定**浏览器那类程序**走不走代理；Antigravity 走不走只看 `127.0.0.1:<port>` 在不在监听。

## 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

从 `.lnk.bak` 还原快捷方式（没有备份就改成直指 `Antigravity.exe`）。因为从来不写全局变量，卸载没有环境变量要清。

## 注意事项

- **改了端口要重启 Antigravity**：环境变量只在进程启动时读一次。
- **它不改系统代理开关**。系统代理归 Clash Verge 管（建议在 Verge 里打开「系统代理」，让它自己维护注册表）。
- **只写当前进程的环境块**，不需要管理员权限，也不影响其他程序。
- **Clash Verge 专属**。换别的客户端用 `-VergeDir` 指配置目录；读不到端口时用 `-FallbackPort`。
- 日志会自己滚动：超过 32 KB 只保留最后 200 行。

## 开发与测试

`launch-antigravity.ps1 -DryRun` 只打印「会用哪个端口、带不带代理」，不启动任何程序。CI 用它验证三条端口读取路径：

```powershell
.\launch-antigravity.ps1 -DryRun -VergeDir C:\some\fake\verge
```

每次 push 到 `main`，GitHub Actions 会：

1. 用 PowerShell 的 `Parser` 解析每个 `.ps1`（语法错就红）；
2. 跑 `PSScriptAnalyzer`（Error/Warning 级别，配置见 `PSScriptAnalyzerSettings.psd1`）；
3. 三个 dry-run 用例：`verge_mixed_port` 读取、`profiles\*.yaml` 里 `mixed-port` 的回退、读不到时的 7897 兜底。

> 顺带一提：上一版的正则只认 `mixed-port:`（连字符），而 Verge 实际写的是 `verge_mixed_port:`（下划线），本地只是因为真实端口恰好等于兜底值 7897 才「看起来正常」—— 是 CI 抓出来的。

## 关于这个项目

这个仓库由 **[@moonlight06hyx](https://github.com/moonlight06hyx) 与 AI 助手合作开发并共同维护**：

- 人负责定需求、判断方向、拍板要不要做；
- AI 负责读日志、定位根因、写代码、验证数字。

## 许可

MIT
