# AskUserQuestion Ghostty 修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让灵动岛面板中 `AskUserQuestion` 选项按钮在 Ghostty 终端下能把选择的数字写入会话，修复点击无响应的 bug。

**Architecture:** 用 `TerminalWriter.shared.sendText` 替换 `ClaudeInstancesView.sendOptionToTerminal` 内部重复实现的 iTerm/Terminal.app/cmux 分支。`TerminalWriter` 已经覆盖 Ghostty（System Events keystroke + 回车），复用后自动获得支持并消除代码漂移。

**Tech Stack:** Swift 5.9+, SwiftUI, macOS 14+, AppleScript via osascript, cmux CLI.

**Spec:** [`docs/superpowers/specs/2026-04-15-askuser-ghostty-fix-design.md`](../specs/2026-04-15-askuser-ghostty-fix-design.md)

**Test strategy:** 本项目无 XCTest 靶子；`TerminalWriter` 通过 osascript/cmux 子进程与真实系统交互，依赖辅助功能权限，不适合单元测试。按 spec 要求做完整链路手动验证（Ghostty / iTerm2 / cmux / 不支持终端四场景）。

---

## File Structure

本次改动仅涉及一个文件，无新文件：

| 文件 | 操作 | 责任 |
|---|---|---|
| `ClaudeIsland/UI/Views/ClaudeInstancesView.swift` | Modify `:820-877` | 替换 `sendOptionToTerminal` 为 `TerminalWriter` 调用；删除不再使用的私有 `runAppleScript` |

---

## Task 1: 核对修改前的行数与上下文

**Files:**
- Read: `ClaudeIsland/UI/Views/ClaudeInstancesView.swift:818-880`

- [ ] **Step 1: 读取目标区间**

用 Read 工具读 `ClaudeIsland/UI/Views/ClaudeInstancesView.swift` offset 818 limit 63 行，确认：

1. `:820-861` 是 `sendOptionToTerminal(index:session:) async` 函数体
2. `:863-877` 是 `runAppleScript(_:) -> Bool` 私有函数
3. `:879` 是下一个 `// MARK: - Subtitle` 注释

如果这些边界与当前文件不符（例如已被其他修改挪动），停止并汇报行号差异——**严禁盲改**。

- [ ] **Step 2: 确认调用方唯一**

Grep `sendOptionToTerminal` 在整仓库出现的位置：

```
rg -n "sendOptionToTerminal" ClaudeIsland
```

期望仅有两处匹配：
- `ClaudeIsland/UI/Views/ClaudeInstancesView.swift:747`（`onTapGesture` 调用）
- `ClaudeIsland/UI/Views/ClaudeInstancesView.swift:821`（函数定义）

若出现第三处调用方，停止并汇报——计划未覆盖。

- [ ] **Step 3: 确认 `runAppleScript` 仅本文件使用**

```
rg -n "runAppleScript" ClaudeIsland
```

期望仅本文件 `:833`、`:845`、`:863` 三处（两次调用 + 一次定义）。若其他文件也引用同名函数（Swift 类型方法，不会跨文件冲突，但防御一下），确认那是另一个类型的方法而非本处的私有函数。

- [ ] **Step 4: 确认 `TerminalWriter.shared.sendText` 签名可直接调用**

Read `ClaudeIsland/Services/Sync/TerminalWriter.swift:14-68`，确认：

1. `final class TerminalWriter` 是 `@MainActor`
2. `static let shared = TerminalWriter()`
3. `func sendText(_ text: String, to session: SessionState) async -> Bool` 签名存在
4. 其内部已覆盖 cmux/iTerm/Ghostty/Terminal.app 四分支

`InstanceRow`（`ClaudeInstancesView.swift` 里 `sendOptionToTerminal` 所在的 View）是 SwiftUI `View`，在主线程上下文——可以直接 `await TerminalWriter.shared.sendText(...)`。

---

## Task 2: 替换 `sendOptionToTerminal` 与删除 `runAppleScript`

**Files:**
- Modify: `ClaudeIsland/UI/Views/ClaudeInstancesView.swift:820-877`

- [ ] **Step 1: 用 Edit 工具做精确替换**

`old_string` 是当前 `:818-877` 的完整块（包含 `// MARK: - AskUserQuestion Response` 注释到 `runAppleScript` 的闭合大括号），`new_string` 是下面的新实现。

`old_string`：

```swift
    // MARK: - AskUserQuestion Response

    /// Send an option selection to the session's terminal
    private func sendOptionToTerminal(index: Int, session: SessionState) async {
        let termApp = session.terminalApp?.lowercased() ?? ""

        // Try AppleScript for iTerm2 / Terminal.app / Ghostty
        if termApp.contains("iterm") {
            let script = """
            tell application "iTerm2"
                tell current session of current tab of current window
                    write text "\(index)"
                end tell
            end tell
            """
            if runAppleScript(script) {
                DebugLogger.log("AskUser", "Sent via iTerm2")
                return
            }
        }

        if termApp.contains("terminal") && !termApp.contains("wez") {
            let script = """
            tell application "Terminal"
                do script "\(index)" in selected tab of front window
            end tell
            """
            if runAppleScript(script) {
                DebugLogger.log("AskUser", "Sent via Terminal.app")
                return
            }
        }

        // cmux — native AppleScript: send text directly to the terminal
        guard CmuxTreeParser.isAvailable else {
            DebugLogger.log("AskUser", "No supported terminal, jumping")
            await TerminalJumper.shared.jump(to: session)
            return
        }

        DebugLogger.log("AskUser", "Sending '\(index)' to cmux terminal cwd=\(session.cwd)")
        let sent = CmuxTreeParser.sendText("\(index)\r", toCwd: session.cwd)
        DebugLogger.log("AskUser", "Sent: \(sent)")
    }

    private func runAppleScript(_ script: String) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
```

`new_string`：

```swift
    // MARK: - AskUserQuestion Response

    /// 把用户选择的选项编号写入会话所在终端。
    /// 复用 TerminalWriter 统一入口，覆盖 cmux / iTerm2 / Ghostty / Terminal.app 四种终端；
    /// 任一原因失败时降级为 jump（激活终端窗口，让用户手动输入）。
    private func sendOptionToTerminal(index: Int, session: SessionState) async {
        DebugLogger.log("AskUser", "Sending '\(index)' via TerminalWriter (term=\(session.terminalApp ?? "?") cwd=\(session.cwd))")
        let sent = await TerminalWriter.shared.sendText("\(index)", to: session)
        if sent {
            DebugLogger.log("AskUser", "Sent successfully")
        } else {
            DebugLogger.log("AskUser", "TerminalWriter failed, falling back to jump")
            await TerminalJumper.shared.jump(to: session)
        }
    }
```

- [ ] **Step 2: 读取修改后的区域确认**

Read `ClaudeIsland/UI/Views/ClaudeInstancesView.swift` offset 815 limit 30 行，确认：

1. 新 `sendOptionToTerminal` 体共 9 行左右
2. `runAppleScript` 已消失
3. 紧随其后的是 `// MARK: - Subtitle`

- [ ] **Step 3: 确认 import 无需改动**

Grep 文件顶部 import 块：

```
rg -n "^import" ClaudeIsland/UI/Views/ClaudeInstancesView.swift
```

`TerminalWriter`、`TerminalJumper`、`DebugLogger`、`SessionState` 都在同一 target（`ClaudeIsland`）里，Swift 同 module 无需 import。无需新增 import。

- [ ] **Step 4: 扫描孤立引用**

确认 `CmuxTreeParser.sendText` 和 `CmuxTreeParser.isAvailable` 在本文件已无调用：

```
rg -n "CmuxTreeParser" ClaudeIsland/UI/Views/ClaudeInstancesView.swift
```

期望：无匹配（本文件已不直接依赖 `CmuxTreeParser`）。`CmuxTreeParser` 本身在其他文件仍被使用，**不要删除** `CmuxTreeParser.swift`。

---

## Task 3: 构建验证

**Files:**
- Build: 整个 `ClaudeIsland.xcodeproj`

- [ ] **Step 1: 运行 xcodebuild 编译**

```
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -60
```

期望：`** BUILD SUCCEEDED **` 出现在末尾。

- [ ] **Step 2: 若出现编译错误**

常见失败与对策：

| 错误 | 可能原因 | 对策 |
|---|---|---|
| `Cannot find 'TerminalWriter' in scope` | TerminalWriter 可能未加入 ClaudeIsland target | 打开 Xcode 检查 `TerminalWriter.swift` 的 Target Membership 勾选 `ClaudeIsland` |
| `Actor-isolated instance method 'sendText' ...` | 调用方不在 `@MainActor` 上下文 | 在 `sendOptionToTerminal` 函数签名前加 `@MainActor`（但先确认父 View 是否已是 MainActor，SwiftUI View 默认是） |
| `'runAppleScript' is unused` 警告残留 | 删除不彻底 | 再次 Read 文件确认 `runAppleScript` 的函数体已完全移除 |

修复后重新运行 Step 1 直到成功。**不要跳过构建验证**。

---

## Task 4: 人工完整链路验证

**Files:**
- 无代码改动，运行中验证

**前置条件：** 已构建成功的 ClaudeIsland.app；辅助功能权限已授予（Ghostty 场景必需）。

- [ ] **Step 1: Ghostty 场景（主修复目标）**

1. 启动 ClaudeIsland.app
2. 在 Ghostty 终端打开一个 Claude Code 会话
3. 发送一个会触发 `AskUserQuestion` 的指令，例如：让 Claude 调用 `/brainstorm` 或任意能触发 `AskUserQuestion` 的场景
4. 等待灵动岛面板展开，出现选项按钮（如"确认执行"/"跳过"）
5. 点击第一个选项按钮
6. **期望**：Ghostty 窗口被激活，对应数字 "1" 被写入 Claude 会话，Claude 继续执行
7. **若失败**：查看 Console.app 的 `com.codeisland` subsystem 日志，看 `AskUser` 分类输出。若看到 `TerminalWriter failed`，检查是否辅助功能权限被 macOS 拒绝（System Settings → Privacy & Security → Accessibility → ClaudeIsland 是否勾选）

- [ ] **Step 2: iTerm2 回归**

1. 在 iTerm2 打开一个 Claude Code 会话
2. 重复上面的 `AskUserQuestion` 触发
3. 从灵动岛点击选项
4. **期望**：iTerm2 session 收到数字并回车，Claude 继续
5. **若失败**：旧代码本来工作，现在坏了——必须定位问题，不能交付

- [ ] **Step 3: cmux 回归（若本机已安装 cmux）**

1. 检查 `/Applications/cmux.app/Contents/Resources/bin/cmux` 是否存在
2. 若存在：在 cmux 内打开会话触发 `AskUserQuestion`，点击选项
3. **期望**：cmux 面板收到数字并继续
4. 若本机无 cmux，跳过此步骤并在交付说明中注明"cmux 路径未在本机验证，但代码路径等价于原 `CmuxTreeParser.sendText`"

- [ ] **Step 4: 不支持终端降级场景**

1. 若有 Warp 或 WezTerm，在其中打开 Claude 会话触发 `AskUserQuestion`
2. 点击选项
3. **期望**：窗口被激活（jump 兜底），**不会静默无反应**——这是对"修复前 Ghostty 行为"的一致性保留
4. 若无此类终端，跳过

- [ ] **Step 5: 汇总验证结果**

把四个场景的结果列成表：

| 场景 | 结果 |
|---|---|
| Ghostty | ✅ / ❌ |
| iTerm2 | ✅ / ❌ |
| cmux | ✅ / ❌ / 未验证 |
| 降级 | ✅ / ❌ / 未验证 |

至少 Ghostty 和 iTerm2 必须 ✅。若有 ❌，**禁止提交**，回到 Task 2 定位问题。

---

## Task 5: 提交

**Files:**
- Stage: `ClaudeIsland/UI/Views/ClaudeInstancesView.swift`

- [ ] **Step 1: 检查 diff**

```
git diff ClaudeIsland/UI/Views/ClaudeInstancesView.swift
```

期望 diff 净减少约 45 行（删掉 iTerm/Terminal.app/cmux 三段 + `runAppleScript`，新增约 10 行）。

确认不包含任何无关改动。若工作区有其他本次未涉及的文件（`ServerConnection.swift`、`NotchViewController.swift`、`CodeLightLocalSupport.swift`、`project.pbxproj`），**不要** `git add -A`，只暂存目标文件。

- [ ] **Step 2: 暂存并提交**

**⚠️ 全局规则：未经用户确认不自动执行 git commit。** 此步骤只有在用户明确说"提交"或"commit"时才执行。

确认用户授权后：

```
git add ClaudeIsland/UI/Views/ClaudeInstancesView.swift
git commit -m "[fix|UI|AskUserQuestion 选项按钮][公共]修复 Ghostty 终端下点击选项无响应，改为复用 TerminalWriter 统一写入入口"
```

- [ ] **Step 3: 验证提交**

```
git log -1 --stat
```

确认只有 `ClaudeInstancesView.swift` 被改动，hunks 数量约为 1（单一替换块）。

---

## 完成判据

- `xcodebuild build` 成功
- Ghostty 场景手动验证通过（数字写入 + Claude 继续）
- iTerm2 场景手动验证通过（回归不坏）
- `sendOptionToTerminal` 内部不再直接依赖 `CmuxTreeParser` 或本地 `runAppleScript`
- 仅 `ClaudeInstancesView.swift` 一个文件被改动
