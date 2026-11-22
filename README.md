# proxy-env-sync

**让「只认环境变量」的程序跟上 Clash Verge 的代理端口。**

一个不到 100 行的 PowerShell 脚本 + 一个计划任务。不开 TUN、只用「系统代理」模式时，Antigravity 这类程序也能正常登录和联网。

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

每 30 分钟（以及每次登录 Windows 时）跑一次：

1. 从 Clash Verge 的配置里读出当前的混合端口
   - 主来源：`%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml` 里的 `verge_mixed_port`
   - 回退：`profiles\*.yaml` 里按修改时间最新的 5 个文件，找 `mixed-port`
   - 兜底：`7897`
2. 把用户环境变量对齐成

   ```
   HTTPS_PROXY = http://127.0.0.1:<port>
   HTTP_PROXY  = http://127.0.0.1:<port>
   NO_PROXY    = localhost,127.0.0.1,::1,*.local
   ```

3. 值没变就直接退出（不写注册表、不广播）；变了才写 `HKCU\Environment`，再广播一次 `WM_SETTINGCHANGE`，让 Explorer 及之后启动的进程拿到新值。

所以：**换节点、换机场、换订阅都不用管**。机场只影响订阅里的节点，本地端口不变。

## 性能

| 场景 | 耗时 | 说明 |
|---|---|---|
| 端口没变（绝大多数） | ≈ 0.2 s | 几乎全是 PowerShell 启动开销；一天 48 次，合计约 10 秒 CPU 时间 |
| 端口变了 | ≈ 0.4 s | 写一次注册表 + 一次广播（每个窗口最多等 100 ms） |
| 常驻内存 | 0 | 无常驻进程；单次运行峰值约 44 MB，存活不到 1 秒 |

## 安装

```powershell
git clone https://github.com/<you>/proxy-env-sync
cd proxy-env-sync
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

`install.ps1` 会：

- 预编译 `EnvBroadcast.dll`（省掉每次运行时 `Add-Type` 编译的几秒）
- 注册计划任务 `proxy-env-sync`：登录时触发 + 每 30 分钟重复
- 立刻跑一次，打印结果

参数：`-IntervalMinutes 30`、`-TaskName "proxy-env-sync"`。

## 验证

```powershell
# 环境变量
Get-ItemProperty HKCU:\Environment -Name HTTPS_PROXY, HTTP_PROXY, NO_PROXY

# 任务状态与最后一次结果（0 = 成功；267009 = 正在运行）
Get-ScheduledTaskInfo -TaskName proxy-env-sync

# 变更历史
Get-Content "$env:LOCALAPPDATA\dsh-proxy-env-sync.log" -Tail 5
```

想看目标程序是否真的走了代理（Windows 10/11）：

```powershell
(Get-NetTCPConnection -OwningProcess (Get-Process language_server).Id -State Established).RemoteAddress |
  Group-Object | Sort-Object Count -Descending
```

出现一片 `127.0.0.1` 就说明它在连本地代理端口。

## 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
# 连环境变量一起清掉：
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -ClearEnv
```

## 注意事项

- **改了端口要重启目标程序**：环境变量只在进程启动时读一次，跑着的进程不会自己刷新。
- **它不改系统代理开关**。系统代理归 Clash Verge 管（建议在 Verge 里打开「系统代理」，让它自己维护注册表，否则 Verge 重启时可能把你的设置写回去）。
- **只写 `HKCU`（当前用户）**，不需要管理员权限，也不影响其他用户。
- **Clash Verge 专属**。换别的客户端，改 `-VergeDir`（配置所在目录）或用参数覆盖；端口读不到时用 `-FallbackPort`。
- 日志会自己滚动：超过 50 KB 只保留最后 200 行。

## 换个客户端怎么办

脚本里端口来源只有一处 `Get-VergePort`。例如用 v2rayN / sing-box / mihomo 直接跑：

```powershell
# 手动指定端口，不读任何配置
.\sync-proxy-env.ps1 ... # 目前没有 -Port 参数，最省事的做法是把 Get-VergePort 换成常量
```

如果你想要 `-Port` 这种显式参数，提 issue 或者自己加一行就好 —— 脚本本身是单文件、无依赖的。

## 关于这个项目

这个仓库由 **[@moonlight06hyx](https://github.com/moonlight06hyx) 与 AI 助手合作开发并共同维护**：

- 人负责定需求、判断方向、拍板要不要做（例如「只用系统代理、不开 TUN 也要能用」「别占 CPU 内存」「打包成项目发出去」）；
- AI 负责读日志、定位根因、写代码、验证数字（0.2 秒 / 44 MB 这些数字都是实测的，不是估的）。

所以文档里那种「为什么 Go 不读系统代理」「为什么广播要限 100 ms」的细节，是两边一起踩坑踩出来的。后续维护也是同样的分工：提 issue 说清楚现象，剩下的排查与改动交给 AI 助手，人只负责最后看一眼。

## 许可

MIT
