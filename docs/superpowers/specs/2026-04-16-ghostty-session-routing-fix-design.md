# Ghostty 会话路由修复设计

> 修复灵动岛发送内容偶现写入错误会话的问题

## 1. 问题描述

### 现象

在灵动岛中对会话 A 发送快速回复或点击 AskUser 选项，文字偶尔出现在 Ghostty 中会话 B 的终端里。

### 根因

`TerminalWriter.sendViaGhosttyPerformAction`（`TerminalWriter.swift:548-568`）路由逻辑：

```applescript
set matches to every terminal whose working directory contains "\(escapedCwd)"
set tgt to item 1 of matches
```

三个缺陷叠加：

| 场景 | 缺陷 |
|------|------|
| 父子/兄弟目录（`/Work/A` 和 `/Work/A-v2`）| `contains` 子串匹配导致误命中 |
| 同目录多会话 | 所有终端都匹配，`item 1` 顺序不确定 |
| 两者叠加 | 放大效应 |

`SessionState` 已有 `pid` 和 `tty` 字段（hook 的 `os.getppid()` 和 `ps -o tty=` 捕获），但 Ghostty 分支完全未利用。对比 phone sync 的 `sendTextDirect` 路径已用 `livePid` 做精准路由。

### 约束

- Ghostty AppleScript API 暴露 `id`（UUID）、`name`、`working directory`，**不暴露 `tty`**
- `perform action "text:..." on (first terminal whose id is "UUID")` 可精准定位（已验证）
- macOS 已禁用 `TIOCSTI`，不能直接向 pty 注入输入
- 用户未安装 cmux，消息全走 Ghostty AppleScript 分支

## 2. 方案概述

两阶段修复：

1. **精确 cwd 匹配**：`contains` → `is`，消除路径子串误匹配
2. **Hook 时捕获 Ghostty terminal ID**：SessionStart 时通过 title-probe 技术获取终端的唯一 UUID，后续发送直接按 ID 路由

## 3. 详细设计

### 3.1 Hook 时 Ghostty Terminal ID 捕获

**时机**：仅在 `SessionStart` 事件、tty 可用、终端为 Ghostty 时执行。

**Ghostty 检测**：hook 脚本通过 `os.environ.get("TERM_PROGRAM") == "ghostty"` 判断（已验证 Ghostty 设置此环境变量）。

**原理**：hook 脚本的 stdout 被 Claude Code 管道捕获，但可以直接写入 tty 设备路径（`/dev/ttysXXX`）来设置终端标题。通过 AppleScript 按标题匹配即可定位到精确的 terminal 对象。

**流程**：

```
SessionStart 触发
  → 检测终端类型为 Ghostty
  → 生成 nonce（8 位随机串）
  → 写 OSC 2 到 /dev/ttysXXX："\033]2;ci-probe-{nonce}\007"
  → sleep 50ms（等 Ghostty 处理转义序列）
  → osascript 查询：id of first terminal whose name contains "ci-probe-{nonce}"
  → 恢复标题："\033]2;\007"
  → 将 terminal_id 写入 hook JSON 的 "ghostty_terminal_id" 字段
```

**codeisland-state.py 伪代码**：

```python
def probe_ghostty_terminal_id(tty):
    """在 SessionStart 时探测 Ghostty terminal UUID。"""
    import subprocess, uuid

    nonce = uuid.uuid4().hex[:8]

    # 写 OSC 2 到 tty 设备（绕过被管道捕获的 stdout）
    try:
        with open(tty, 'w') as f:
            f.write(f'\033]2;ci-probe-{nonce}\007')
            f.flush()
    except OSError:
        return None

    time.sleep(0.05)

    # 查询 Ghostty
    try:
        result = subprocess.run(
            ['osascript', '-e',
             f'tell application "Ghostty" to id of first terminal '
             f'whose name contains "ci-probe-{nonce}"'],
            capture_output=True, text=True, timeout=2
        )
        terminal_id = result.stdout.strip()
    except Exception:
        terminal_id = None

    # 恢复标题
    try:
        with open(tty, 'w') as f:
            f.write('\033]2;\007')
            f.flush()
    except OSError:
        pass

    return terminal_id if terminal_id else None
```

**调用位置**：`main()` 中 `event == "SessionStart"` 分支内，探测成功后加入 `state["ghostty_terminal_id"]`。

### 3.2 数据模型变更

**SessionState.swift** 新增字段：

```swift
/// Ghostty terminal UUID，SessionStart 时通过 title-probe 捕获。
/// 发送时用于精准路由，避免 cwd 匹配歧义。
var ghosttyTerminalId: String?
```

**HookEvent** 解析 JSON 中的 `ghostty_terminal_id` 字段。

**SessionStore.swift**：
- `createSession(from:)` 初始化该字段
- `updateSession` 中若 event 携带 `ghostty_terminal_id` 则更新

### 3.3 TerminalWriter 路由改造

`sendViaGhosttyPerformAction` 改为三层递进：

**Layer 1 — ID 精准路由**（`ghosttyTerminalId` 可用时）：
```applescript
tell application "Ghostty"
    set tgt to first terminal whose id is "<UUID>"
    perform action ("text:" & <content> & return) on tgt
end tell
```
AppleScript 报错（terminal 已关闭）则记录日志，降级到 Layer 2。无需主动清空 `ghosttyTerminalId`——终端关闭后 Claude 进程也会终止，不会有后续发送。

**Layer 2 — 精确 cwd 匹配**（无 ID 或 ID 失效）：
```applescript
set matches to every terminal whose working directory is "<cwd>"
```
`is` 替代 `contains`，消除路径子串误匹配。单匹配直接用；多匹配取 `item 1`。

**Layer 3 — contains 兜底**（Layer 2 零匹配时）：
```applescript
set matches to every terminal whose working directory contains "<cwd>"
```
覆盖 symlink / 路径规范化不一致等边缘场景，保持现有行为作为最后防线。

### 3.4 错误处理

| 场景 | 处理 |
|------|------|
| 探测时 Ghostty 无响应 / 未运行 | 静默跳过，`ghosttyTerminalId` 为空 |
| 探测时 tty 不可写 | 跳过探测，走 cwd 匹配 |
| 发送时 terminal 已关闭（ID 失效）| 捕获 AppleScript 错误，记录日志，降级 Layer 2 |
| 非 Ghostty 终端 | 不执行探测，字段始终为空，不影响其他终端分支 |

### 3.5 向后兼容

所有新逻辑都是 additive。`ghosttyTerminalId` 为空时行为与现有完全一致（除了 `contains` → `is` 的改进，Layer 3 兜底保持原始 `contains` 行为）。

## 4. 涉及文件

| 文件 | 变更 |
|------|------|
| `ClaudeIsland/Resources/codeisland-state.py` | 新增 `probe_ghostty_terminal_id()`，SessionStart 时调用 |
| `ClaudeIsland/Models/SessionState.swift` | 新增 `ghosttyTerminalId` 字段 |
| `ClaudeIsland/Services/State/SessionStore.swift` | 解析并存储 `ghostty_terminal_id` |
| `ClaudeIsland/Services/Sync/TerminalWriter.swift` | 三层递进路由改造 |
| `ClaudeIsland/Services/Hooks/HookSocketServer.swift` | `HookEvent` 新增 `ghosttyTerminalId` 字段 |

## 5. 测试计划

| # | 场景 | 验证方式 |
|---|------|----------|
| 1 | 单会话发送 | 快速回复 + AskUser 选项，确认写入正确终端 |
| 2 | 同目录两个会话 | 分别对两个会话发送，确认各写入正确终端 |
| 3 | 父子目录 | 对 `/A` 会话发送，确认不会写入 `/A-v2` |
| 4 | Terminal ID 失效 | 关闭终端后发送，确认降级到 cwd 匹配而非崩溃 |
| 5 | 非 Ghostty 终端 | iTerm2 / Terminal.app 下验证无回归 |
| 6 | 探测日志 | SessionStart 后检查 `~/.claude/.codeisland.log` 确认 ID 捕获成功 |
| 7 | 标题恢复 | 探测后确认终端标题无残留 |

日志增强：在 `sendViaGhosttyPerformAction` 中记录使用了哪一层（ID / exact cwd / contains fallback）。

## 6. 不改动的部分

- `sendTextDirect`（phone sync 路径）：已用 `livePid` 走 cmux，不走 Ghostty AppleScript
- iTerm2 / Terminal.app 分支：不在本次范围
- cmux 分支的 `sendViaCmux`：独立问题，不在本次范围
