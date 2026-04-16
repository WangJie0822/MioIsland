# Ghostty 会话路由修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复灵动岛发送内容偶现写入错误 Ghostty 终端会话的问题。

**Architecture:** Hook 脚本在 SessionStart 时通过 title-probe 技术捕获 Ghostty terminal UUID，存入 SessionState；TerminalWriter 优先按 UUID 精准路由，降级到精确 cwd 匹配，最后 contains 兜底。

**Tech Stack:** Python (hook script), Swift/SwiftUI (app), AppleScript (Ghostty IPC)

**Spec:** `docs/superpowers/specs/2026-04-16-ghostty-session-routing-fix-design.md`

---

## 文件结构

| 文件 | 动作 | 职责 |
|------|------|------|
| `ClaudeIsland/Resources/codeisland-state.py` | 修改 | 新增 `probe_ghostty_terminal_id()` 函数，SessionStart 时调用 |
| `ClaudeIsland/Services/Hooks/HookSocketServer.swift` | 修改 | `HookEvent` 新增 `ghosttyTerminalId` 字段 + CodingKey + init 参数 |
| `ClaudeIsland/Models/SessionState.swift` | 修改 | 新增 `ghosttyTerminalId` 字段 |
| `ClaudeIsland/Services/State/SessionStore.swift` | 修改 | `createSession` 和 `processHookEvent` 中解析并存储 terminal ID |
| `ClaudeIsland/Services/Sync/TerminalWriter.swift` | 修改 | `sendViaGhosttyPerformAction` 改为三层递进路由 |

---

### Task 1: Hook 脚本 — 新增 Ghostty terminal ID 探测

**Files:**
- Modify: `ClaudeIsland/Resources/codeisland-state.py:16-49` (在 `get_tty()` 之后新增函数)
- Modify: `ClaudeIsland/Resources/codeisland-state.py:182-184` (SessionStart 分支中调用)

- [ ] **Step 1: 在 `get_tty()` 函数之后新增 `probe_ghostty_terminal_id()` 函数**

在 `codeisland-state.py` 的 `get_tty()` 函数（第 49 行 `return None` 之后）和 `send_event()` 函数（第 52 行）之间插入：

```python
def probe_ghostty_terminal_id(tty):
    """在 SessionStart 时通过 title-probe 探测 Ghostty terminal UUID。

    原理：hook 脚本的 stdout 被 Claude Code 管道捕获，但可以直接写入
    tty 设备路径设置终端标题，然后通过 AppleScript 按标题定位 terminal
    并取得其唯一 ID。

    仅在 TERM_PROGRAM == "ghostty" 且 tty 可用时执行。
    """
    import subprocess
    import uuid
    import time

    # 仅 Ghostty 终端执行
    if os.environ.get("TERM_PROGRAM") != "ghostty":
        return None
    if not tty:
        return None

    nonce = uuid.uuid4().hex[:8]

    # 写 OSC 2 到 tty 设备（绕过被管道捕获的 stdout）
    try:
        with open(tty, 'w') as f:
            f.write(f'\033]2;ci-probe-{nonce}\007')
            f.flush()
    except OSError:
        return None

    # 等 Ghostty 处理转义序列
    time.sleep(0.05)

    # 查询 Ghostty 找到带 nonce 标题的 terminal
    terminal_id = None
    try:
        result = subprocess.run(
            ['osascript', '-e',
             f'tell application "Ghostty" to id of first terminal '
             f'whose name contains "ci-probe-{nonce}"'],
            capture_output=True, text=True, timeout=2
        )
        if result.returncode == 0 and result.stdout.strip():
            terminal_id = result.stdout.strip()
    except Exception:
        pass

    # 恢复标题（重置为空，shell/Claude Code 会在下次 prompt 时恢复）
    try:
        with open(tty, 'w') as f:
            f.write('\033]2;\007')
            f.flush()
    except OSError:
        pass

    return terminal_id
```

- [ ] **Step 2: 在 SessionStart 分支中调用探测并写入 state**

修改 `codeisland-state.py` 第 182-184 行，从：

```python
    elif event == "SessionStart":
        # New session starts waiting for user input
        state["status"] = "waiting_for_input"
```

改为：

```python
    elif event == "SessionStart":
        # New session starts waiting for user input
        state["status"] = "waiting_for_input"
        # 探测 Ghostty terminal ID（仅 Ghostty + 有 tty 时执行）
        ghostty_id = probe_ghostty_terminal_id(tty)
        if ghostty_id:
            state["ghostty_terminal_id"] = ghostty_id
```

- [ ] **Step 3: 验证 Python 语法**

运行：`python3 -c "import py_compile; py_compile.compile('ClaudeIsland/Resources/codeisland-state.py', doraise=True)"`

预期：无输出，退出码 0。

- [ ] **Step 4: 提交**

```bash
git add ClaudeIsland/Resources/codeisland-state.py
git commit -m "[feat|Sync|TerminalWriter][公共]hook脚本SessionStart时探测Ghostty terminal ID"
```

---

### Task 2: HookEvent — 新增 ghosttyTerminalId 字段

**Files:**
- Modify: `ClaudeIsland/Services/Hooks/HookSocketServer.swift:16-51`

- [ ] **Step 1: 在 `HookEvent` struct 中添加字段**

在 `HookSocketServer.swift:27`（`let message: String?` 之后）添加：

```swift
    let ghosttyTerminalId: String?
```

- [ ] **Step 2: 在 `CodingKeys` 中添加映射**

修改 `HookSocketServer.swift:29-36`，在 CodingKeys enum 中添加新 key。从：

```swift
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd, event, status, pid, tty, tool
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case notificationType = "notification_type"
        case message
    }
```

改为：

```swift
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd, event, status, pid, tty, tool
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case notificationType = "notification_type"
        case message
        case ghosttyTerminalId = "ghostty_terminal_id"
    }
```

- [ ] **Step 3: 更新 `HookEvent.init` 的参数列表和赋值**

修改 `HookSocketServer.swift:39-51`。从：

```swift
    init(sessionId: String, cwd: String, event: String, status: String, pid: Int?, tty: String?, tool: String?, toolInput: [String: AnyCodable]?, toolUseId: String?, notificationType: String?, message: String?) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.event = event
        self.status = status
        self.pid = pid
        self.tty = tty
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.notificationType = notificationType
        self.message = message
    }
```

改为：

```swift
    init(sessionId: String, cwd: String, event: String, status: String, pid: Int?, tty: String?, tool: String?, toolInput: [String: AnyCodable]?, toolUseId: String?, notificationType: String?, message: String?, ghosttyTerminalId: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.event = event
        self.status = status
        self.pid = pid
        self.tty = tty
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.notificationType = notificationType
        self.message = message
        self.ghosttyTerminalId = ghosttyTerminalId
    }
```

- [ ] **Step 4: 更新 `handleClient` 中构造 `updatedEvent` 的调用**

修改 `HookSocketServer.swift:439-451`（`let updatedEvent = HookEvent(...)` 调用）。从：

```swift
            let updatedEvent = HookEvent(
                sessionId: event.sessionId,
                cwd: event.cwd,
                event: event.event,
                status: event.status,
                pid: event.pid,
                tty: event.tty,
                tool: event.tool,
                toolInput: event.toolInput,
                toolUseId: toolUseId,  // Use resolved toolUseId
                notificationType: event.notificationType,
                message: event.message
            )
```

改为：

```swift
            let updatedEvent = HookEvent(
                sessionId: event.sessionId,
                cwd: event.cwd,
                event: event.event,
                status: event.status,
                pid: event.pid,
                tty: event.tty,
                tool: event.tool,
                toolInput: event.toolInput,
                toolUseId: toolUseId,  // Use resolved toolUseId
                notificationType: event.notificationType,
                message: event.message,
                ghosttyTerminalId: event.ghosttyTerminalId
            )
```

- [ ] **Step 5: 提交**

```bash
git add ClaudeIsland/Services/Hooks/HookSocketServer.swift
git commit -m "[feat|Sync|TerminalWriter][公共]HookEvent新增ghosttyTerminalId字段"
```

---

### Task 3: SessionState — 新增 ghosttyTerminalId 字段

**Files:**
- Modify: `ClaudeIsland/Models/SessionState.swift:20-28` (Instance Metadata section)
- Modify: `ClaudeIsland/Models/SessionState.swift:71-108` (init)

- [ ] **Step 1: 在 Instance Metadata 区域添加字段**

在 `SessionState.swift:28`（`var isBackground: Bool` 之后）添加：

```swift
    /// Ghostty terminal UUID，SessionStart 时通过 title-probe 捕获，
    /// 发送时用于精准路由，避免 cwd 匹配歧义。
    var ghosttyTerminalId: String?
```

- [ ] **Step 2: 更新 init 参数列表**

在 `SessionState.swift` 的 `nonisolated init(...)` 中，在 `isBackground: Bool = false,` 参数之后添加 `ghosttyTerminalId` 参数。修改 init 签名，从：

```swift
        isBackground: Bool = false,
        phase: SessionPhase = .idle,
```

改为：

```swift
        isBackground: Bool = false,
        ghosttyTerminalId: String? = nil,
        phase: SessionPhase = .idle,
```

- [ ] **Step 3: 在 init body 中赋值**

在 `self.isBackground = isBackground` 之后添加赋值。从：

```swift
        self.isBackground = isBackground
        self.phase = phase
```

改为：

```swift
        self.isBackground = isBackground
        self.ghosttyTerminalId = ghosttyTerminalId
        self.phase = phase
```

- [ ] **Step 4: 提交**

```bash
git add ClaudeIsland/Models/SessionState.swift
git commit -m "[feat|Sync|TerminalWriter][公共]SessionState新增ghosttyTerminalId字段"
```

---

### Task 4: SessionStore — 解析并存储 ghosttyTerminalId

**Files:**
- Modify: `ClaudeIsland/Services/State/SessionStore.swift:162-168` (processHookEvent 中 tty 处理之后)
- Modify: `ClaudeIsland/Services/State/SessionStore.swift:221-233` (createSession)

- [ ] **Step 1: 在 processHookEvent 中存储 ghosttyTerminalId**

在 `SessionStore.swift` 的 `processHookEvent` 方法中，在 tty 处理块之后（第 168 行 `}` 之后、第 169 行 `session.lastActivity = Date()` 之前）添加：

```swift
        if let ghosttyId = event.ghosttyTerminalId {
            session.ghosttyTerminalId = ghosttyId
            DebugLogger.log("Hook", "Ghostty terminal ID captured: \(ghosttyId.prefix(8))")
        }
```

- [ ] **Step 2: 在 createSession 中初始化 ghosttyTerminalId**

修改 `SessionStore.swift` 的 `createSession(from:)` 方法。从：

```swift
    private func createSession(from event: HookEvent) -> SessionState {
        let tty = event.tty?.replacingOccurrences(of: "/dev/", with: "")
        return SessionState(
            sessionId: event.sessionId,
            cwd: event.cwd,
            projectName: URL(fileURLWithPath: event.cwd).lastPathComponent,
            pid: event.pid,
            tty: tty,
            isInTmux: false,  // Will be updated
            isBackground: tty == nil,
            phase: .idle
        )
    }
```

改为：

```swift
    private func createSession(from event: HookEvent) -> SessionState {
        let tty = event.tty?.replacingOccurrences(of: "/dev/", with: "")
        return SessionState(
            sessionId: event.sessionId,
            cwd: event.cwd,
            projectName: URL(fileURLWithPath: event.cwd).lastPathComponent,
            pid: event.pid,
            tty: tty,
            isInTmux: false,  // Will be updated
            isBackground: tty == nil,
            ghosttyTerminalId: event.ghosttyTerminalId,
            phase: .idle
        )
    }
```

- [ ] **Step 3: 提交**

```bash
git add ClaudeIsland/Services/State/SessionStore.swift
git commit -m "[feat|Sync|TerminalWriter][公共]SessionStore解析并存储ghosttyTerminalId"
```

---

### Task 5: TerminalWriter — 三层递进路由

**Files:**
- Modify: `ClaudeIsland/Services/Sync/TerminalWriter.swift:548-568` (sendViaGhosttyPerformAction)

- [ ] **Step 1: 重写 `sendViaGhosttyPerformAction` 为三层递进**

将 `TerminalWriter.swift` 中现有的 `sendViaGhosttyPerformAction` 方法（第 548-568 行）替换为：

```swift
    /// Ghostty 专用发送通道：三层递进路由。
    ///
    /// Layer 1: ghosttyTerminalId 精准路由（SessionStart 时通过 title-probe 捕获的 UUID）
    /// Layer 2: 精确 cwd 匹配（is 替代 contains，消除路径子串误匹配）
    /// Layer 3: contains 兜底（覆盖 symlink/路径规范化不一致等边缘场景）
    ///
    /// 为什么不走 `System Events keystroke`：keystroke 命令按当前系统输入法状态
    /// 把字符逐个翻译成虚拟键码，非 ASCII 字符（中文等）会被误翻译成乱码。
    ///
    /// Ghostty 的 `perform action` 接受 `text:<content>` 格式，content 被 Ghostty
    /// 的 action 层原样写入 pty，原生支持任意 UTF-8 字节。
    private func sendViaGhosttyPerformAction(text: String, session: SessionState) -> Bool {
        let literalExpr = buildGhosttyTextLiteral(text)

        // Layer 1: 按 Ghostty terminal UUID 精准路由
        if let terminalId = session.ghosttyTerminalId {
            let escapedId = terminalId
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
                tell application "Ghostty"
                    set tgt to first terminal whose id is "\(escapedId)"
                    perform action ("text:" & \(literalExpr) & return) on tgt
                end tell
                """
            if sendViaAppleScript(text, script: script) {
                DebugLogger.log("Sync", "Ghostty: sent via terminal ID \(terminalId.prefix(8))")
                return true
            }
            // ID 失效（terminal 已关闭），降级到 Layer 2
            DebugLogger.log("Sync", "Ghostty: terminal ID \(terminalId.prefix(8)) stale, falling back to cwd match")
        }

        let escapedCwd = session.cwd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Layer 2: 精确 cwd 匹配（is 替代 contains）
        let exactScript = """
            tell application "Ghostty"
                set matches to every terminal whose working directory is "\(escapedCwd)"
                if (count of matches) is 0 then
                    error "no Ghostty terminal matched exact cwd"
                end if
                set tgt to item 1 of matches
                perform action ("text:" & \(literalExpr) & return) on tgt
            end tell
            """
        if sendViaAppleScript(text, script: exactScript) {
            DebugLogger.log("Sync", "Ghostty: sent via exact cwd match")
            return true
        }

        // Layer 3: contains 兜底（symlink / 路径规范化等边缘场景）
        let containsScript = """
            tell application "Ghostty"
                set matches to every terminal whose working directory contains "\(escapedCwd)"
                if (count of matches) is 0 then
                    error "no Ghostty terminal matched cwd"
                end if
                set tgt to item 1 of matches
                perform action ("text:" & \(literalExpr) & return) on tgt
            end tell
            """
        if sendViaAppleScript(text, script: containsScript) {
            DebugLogger.log("Sync", "Ghostty: sent via contains cwd fallback")
            return true
        }

        DebugLogger.log("Sync", "Ghostty: all three layers failed for cwd=\(session.cwd)")
        return false
    }
```

- [ ] **Step 2: 验证编译**

运行：
```bash
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

预期：`BUILD SUCCEEDED`

- [ ] **Step 3: 提交**

```bash
git add ClaudeIsland/Services/Sync/TerminalWriter.swift
git commit -m "[fix|Sync|TerminalWriter][公共]Ghostty三层递进路由：ID精准→精确cwd→contains兜底"
```

---

### Task 6: 端到端验证

**Files:** 无代码变更，纯验证。

- [ ] **Step 1: 编译并安装**

```bash
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

预期：`BUILD SUCCEEDED`

启动 app（Xcode Run 或双击 build 产物）。

- [ ] **Step 2: 验证 terminal ID 捕获**

在 Ghostty 中启动一个新的 Claude Code 会话（`claude` 命令），等待 SessionStart hook 触发。

检查日志：
```bash
grep "Ghostty terminal ID captured" ~/.claude/.codeisland.log | tail -3
```

预期：看到类似 `Ghostty terminal ID captured: 1DAD401D` 的日志。

- [ ] **Step 3: 验证单会话发送**

在灵动岛中对该会话使用快速回复输入框发送一条消息。

检查日志：
```bash
grep "Ghostty: sent via" ~/.claude/.codeisland.log | tail -3
```

预期：看到 `Ghostty: sent via terminal ID XXXXXXXX`。

确认消息出现在正确的 Ghostty 终端中。

- [ ] **Step 4: 验证同目录双会话（核心场景）**

在同一目录下开两个 Ghostty 终端，各启动一个 Claude Code 会话。分别在灵动岛对两个会话发送不同的消息（如 "hello1" 和 "hello2"），确认各自写入正确的终端。

- [ ] **Step 5: 验证父子目录**

在 `/tmp/test-a` 和 `/tmp/test-a-v2` 各启动一个 Claude Code 会话。对 `/tmp/test-a` 的会话发送消息，确认不会写入 `/tmp/test-a-v2` 的终端。

- [ ] **Step 6: 验证标题恢复**

SessionStart 后观察 Ghostty 终端标题，确认没有 `ci-probe-` 残留。

- [ ] **Step 7: 验证 AskUser 选项点击**

触发一个需要 AskUserQuestion 的 Claude 操作，在灵动岛点击选项按钮，确认写入正确终端。

---

## 依赖关系

```
Task 1 (hook脚本) ──┐
Task 2 (HookEvent) ──┤
Task 3 (SessionState)─┼── Task 4 (SessionStore) ── Task 5 (TerminalWriter) ── Task 6 (验证)
                      │
```

Task 1-3 互相独立，可并行。Task 4 依赖 2+3。Task 5 依赖 3。Task 6 依赖全部。
