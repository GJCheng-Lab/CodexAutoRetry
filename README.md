# Codex Auto Retry for Windows

Windows AutoHotkey v2 工具，用于监测 Codex 独立桌面客户端侧栏中的异常会话，并通过 Windows UI Automation 逐个进入目标会话，确认容量错误后执行重试或安全发送。

项目地址：<https://github.com/GJCheng-Lab/CodexAutoRetry>

## 当前能力

- 自动绑定可用的 Codex 主窗口，不要求窗口位于前台。
- 每 5 秒重新扫描 UIA 侧栏。
- 识别已实测状态：`Task failed`、`任务未成功`、`任务失败`。
- 支持嵌套项目、嵌套会话行和多个异常会话串行处理。
- 单会话冷却 10 秒；每分钟最多 6 次；单次运行最多 200 次。
- 只处理容量错误：

  `Selected model is at capacity. Please try a different model.`

- 支持 `Retry`、`重试`、`重試`。
- 使用 UIA `InvokePattern` 操作，不激活 Codex、不移动真实鼠标、不发送键盘输入。
- 发现异常后显示右下角通知，0.3 秒后操作，约 2 秒内渐隐。

## 环境要求

- Windows 10/11
- AutoHotkey v2
- Windows PowerShell 5.1
- Codex 独立桌面客户端
- `sqlite3.exe` 在 PATH 中时，可额外读取本机 Codex 状态库

## 运行

1. 安装 AutoHotkey v2。
2. 将 `settings.example.ini` 复制为 `settings.ini`，按需修改。
3. 双击运行 `CodexAutoRetry.ahk`。

程序不会修改 Codex 安装文件、认证信息、远程项目、SSH 配置或 Codex 状态数据库。

## 快捷键

| 快捷键 | 功能 |
|---|---|
| `Ctrl+Alt+F10` | 重新绑定 Codex 主窗口 |
| `Ctrl+Alt+F9` | 只读 UIA 探测，写入 `probe.log` |
| `Ctrl+Alt+F7` | 处理一个符合条件的会话 |
| `Ctrl+Alt+F6` | 开关自动处理 |
| `Ctrl+Alt+F8` | 暂停或恢复自动处理 |
| `Ctrl+Alt+Q` | 退出程序 |

## 配置

示例见 [settings.example.ini](settings.example.ini)：

```ini
[Limits]
scan_seconds=5
cooldown_seconds=10
max_per_minute=6
max_per_session=200
verify_seconds=6

[Behavior]
auto_enabled=true
```

## 处理流程

```text
UIA 侧栏扫描；若后台 UIA 树未暴露失败标记，则只读查询本机最新失败回合
        ↓
异常会话去重与冷却检查
        ↓
重新定位目标会话
        ↓
UIA InvokePattern 切换会话
        ↓
确认当前会话、容量错误和操作按钮
        ↓
只执行一次操作并短时验证
        ↓
继续处理下一个会话
```

标题包含“错误”或“失败”不会单独触发异常判断。前台时优先使用已实测的实时 UIA 状态子元素；后台 UIA 树没有暴露红色标记时，状态库只提供最新容量失败回合的候选，进入会话、错误核验和按钮操作仍必须通过 UIA 完成。每个 `thread_id + turn_id` 只处理一次，避免历史失败记录重复触发。

如果目标会话的发送区已经有用户内容，程序会记录 `SKIP|composer_has_content`，右下角显示跳过通知，不会调用发送按钮，也不会提交已有内容。

发送区按钮也参与判断：向上箭头按“有内容”处理并跳过；语音按钮（当前中文 UIA 名称为 `听写`）按“无内容、无可执行发送动作”处理；容量异常且无内容时，使用右侧三角形对应的底部 UIA Button，通过位置和排除语音、停止、模型按钮来定位，不依赖图像像素。

## 本机状态与远程项目

`CodexStateReader.ps1` 只读：

- `%USERPROFILE%\\.codex\\thread_history_1.sqlite`
- `%USERPROFILE%\\.codex\\state_5.sqlite`

它读取最新失败回合和 `thread_id`，默认只查询最近 24 小时的状态。它只覆盖本机 Codex 状态库，且不会直接触发自动操作；远程项目需要由 Windows 桌面客户端 UIA 暴露异常状态后才能自动处理。当前已实测远程项目侧栏中的 `任务未成功` 可以被识别。

## 诊断工具

```powershell
powershell -ExecutionPolicy Bypass -File .\CodexLogReader.ps1
powershell -ExecutionPolicy Bypass -File .\CodexStateReader.ps1
powershell -ExecutionPolicy Bypass -File .\diagnose.ps1 -Handle <HWND>
powershell -ExecutionPolicy Bypass -File .\UiaRetry.ps1 -Handle <HWND> -Mode sidebar-dump
```

诊断只输出必要的控件属性、有限会话标题和状态信息，不导出完整聊天正文、认证信息或工具输出。

## 日志语义

`retry.log` 和 `probe.log` 不进入 Git。主要记录：

- `AUTO_BIND`：绑定的 PID 和 HWND
- `DETECTED`：异常候选及来源
- `NOTICE`：通知气泡
- `SENT`：操作消息已发送
- `VERIFY`：短时验证结果
- `SKIP`：跳过原因

`SENT` 不代表模型调用恢复成功。`CAPACITY_AGAIN` 表示点击后仍观察到容量错误；`EFFECT_NOT_CONFIRMED` 表示验证时间内没有足够恢复信号。

## 当前实测

- UIA 已识别中文状态 `任务未成功`。
- 已识别并处理 `PhonOP → 初始化 PhonOP M0 架构审计`。
- 随后识别并处理 `EDEN → 读取文档并完成任务 EDENet 项目交接与 M2.1 开发任务...`。
- 两个会话均完成后台会话切换及 UIA 操作发送。
- 后续扫描不再返回这两个异常标记。

日志仍区分操作发送和模型恢复，不把 `SENT` 或静态检查报告为恢复成功。

## 文件说明

| 文件 | 作用 |
|---|---|
| `CodexAutoRetry.ahk` | 常驻循环、窗口绑定、限频、通知和 UIA 调用 |
| `UiaRetry.ps1` | UIA 探测、侧栏扫描、会话定位、错误和按钮确认 |
| `CodexLogReader.ps1` | 只读提取日志中的容量错误辅助信息 |
| `CodexStateReader.ps1` | 只读读取本机 Codex SQLite 最新失败回合 |
| `diagnose.ps1` | 汇总 UIA 和日志诊断 |
| `settings.example.ini` | 配置示例 |
| `UIA_DIAGNOSTIC.md` | 实测 UIA 结构和覆盖边界 |
| `UPSTREAM.md` | 上游项目、固定 commit 和许可证记录 |

## 上游与许可证

本项目参考了 `luzay-max/codex-auto-retry` 的 Windows AHK/PowerShell 实现，以及 `yuxi1989/Codex-RetryPilot` 的按钮识别和效果判断思路。固定 commit、使用范围和许可证见 [UPSTREAM.md](UPSTREAM.md)。

根目录保留上游 MIT 许可证文本，详见 [LICENSE](LICENSE)。
