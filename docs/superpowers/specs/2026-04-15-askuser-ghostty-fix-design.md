# AskUserQuestion 选项按钮在 Ghostty 无响应修复

## 背景

灵动岛面板里，当 Claude 调用 `AskUserQuestion` 工具时，会在会话卡片内联渲染选项按钮（例如 "确认执行" / "跳过工作日志" / "调整时段"）。用户点击后，期望把对应的数字（1/2/3...）写入该会话所在终端的 stdin，让 Claude 读到用户的选择并继续。

在 Ghostty 终端下点击这些按钮无任何反应。作为对照，同一会话的 Allow/Deny 审批按钮工作正常。

## 根因

点击走的处理函数是 `ClaudeIsland/UI/Views/ClaudeInstancesView.swift:820 sendOptionToTerminal(index:session:)`，它只实现了三条分支：

1. `iterm` → AppleScript `tell application "iTerm2" ... write text`
2. `terminal`（排除 wez）→ AppleScript `tell application "Terminal" ... do script`
3. cmux → `CmuxTreeParser.sendText("\(index)\r", toCwd:)`

**没有 Ghostty 分支**。当 `session.terminalApp` 为 Ghostty 且 cmux 未安装（`CmuxTreeParser.isAvailable == false`）时，函数落到最后的兜底路径 `TerminalJumper.shared.jump(to: session)`——只把 Ghostty 窗口激活到前台，**不发送任何文字**。从用户视角看就是"点了没反应"。

对照之下，Allow/Deny 按钮调用 `sessionMonitor.approvePermission/denyPermission`（见 `ClaudeInstancesView.swift:462-468`），走的是 MCP 权限 IPC 通道，完全不经过终端 stdin，所以与终端类型无关，Ghostty 下依然能工作。AskUserQuestion 必须写入终端，这是两者的本质差异。

同时注意到 `ClaudeIsland/Services/Sync/TerminalWriter.swift:25 sendText(_:to:)` 已经是一个覆盖 cmux → iTerm → Ghostty → Terminal.app 的完整终端写入入口：
- cmux 分支通过 `cmuxRun ["list-workspaces"]` + cwd/sessionId 匹配发送
- iTerm 分支 `write text`（自带换行）
- Ghostty 分支 `activate` + System Events `keystroke` + `key code 36`（回车）
- Terminal.app 分支 `do script`（自带执行）

因此 `sendOptionToTerminal` 的本地实现是一个小而过时的重复版本，缺 Ghostty 分支只是表象，根本问题是两处终端写入路径漂移。

## 方案

把 `sendOptionToTerminal` 整个替换为对 `TerminalWriter.shared.sendText` 的一次调用，消除本地重复实现。

### 修改点

**文件**：`ClaudeIsland/UI/Views/ClaudeInstancesView.swift`

**位置**：`:820-877`（`sendOptionToTerminal` 函数体 + 紧随其后的 `runAppleScript` 辅助函数）

**改动**：

```swift
private func sendOptionToTerminal(index: Int, session: SessionState) async {
    DebugLogger.log("AskUser", "Sending '\(index)' to terminal \(session.terminalApp ?? "?") cwd=\(session.cwd)")
    let sent = await TerminalWriter.shared.sendText("\(index)", to: session)
    if !sent {
        DebugLogger.log("AskUser", "TerminalWriter failed, falling back to jump")
        await TerminalJumper.shared.jump(to: session)
    }
}
```

同步删除私有 `runAppleScript(_:)`（不再有调用方）。

### 为什么这样就够

- `TerminalWriter.shared.sendText` 内部已处理 cmux/iTerm/Ghostty/Terminal.app 四种终端并保证回车
- 调用方是 SwiftUI `Task { await ... }`，已经异步；`sendText` 是 `@MainActor async`，签名匹配
- `sendText` 对 cmux 的处理（`sendViaCmux` 按 cwd 扫描 workspace + surface）在行为上等价于原 `CmuxTreeParser.sendText(toCwd:)`，二者最终都落到 `cmux send`
- 失败时 fallback 到 `TerminalJumper.jump` 保留原有降级体验

## 影响评审

- **调用方**：`sendOptionToTerminal` 只在 `ClaudeInstancesView.swift:747` 一处被调用（选项 `onTapGesture` 里），签名不变，无需改调用点
- **并发/主线程**：`TerminalWriter` 是 `@MainActor`，`ClaudeInstancesView` 也在主线程渲染，调用合法
- **权限/审批路径**：不触及 Allow/Deny 的 `approveSession/rejectSession`，完全无影响
- **其他终端**：
  - iTerm / Terminal.app：行为等价（都是 AppleScript）。原实现只 `write text "1"`，无 `\n`；iTerm 的 `write text` 和 Terminal.app 的 `do script` 都自带回车，行为一致
  - cmux：行为等价（都是 `cmux send ... \r`）
  - Ghostty：**从不工作变成工作**（System Events keystroke + 回车）
  - Warp / WezTerm：维持现状（两种路径都不支持；将来只要在 `TerminalWriter` 里加分支，本修复自动受益）
- **向后兼容**：无行为回退，无 API 变更

## 测试

因 UI 交互涉及 AppleScript / System Events，无法完全单元测试。验收按以下完整链路手动验证：

1. **Ghostty + 真实 AskUserQuestion**：在 Ghostty 里启动 Claude 会话，触发一个 `AskUserQuestion`，从灵动岛面板点击选项按钮 1/2/3，确认对应数字被写入 Ghostty 并 Claude 收到选择继续执行
2. **iTerm2 回归**：同上流程验证 iTerm2 下仍能工作
3. **cmux 回归**：cmux 环境下验证选项发送仍然走 cmux send
4. **失败降级**：人为用一个不支持的终端（例如 Warp）触发，确认会 fallback 到 `TerminalJumper.jump`（窗口被激活而非静默）

不新增自动化测试（与原有 `sendOptionToTerminal` 一致，该函数从未有单测；终端交互依赖系统权限和实际进程，不适合 XCTest 环境）。

## 风险

- **低**：改动被限制在一个函数内，外部 API 签名不变
- **cmux 路径差异**：原 `CmuxTreeParser.sendText(toCwd:)` 按 cwd 精确匹配，`TerminalWriter.sendViaCmux` 额外按 session uuid 前 8 位匹配 workspace 标题——在一个 cwd 下跑多会话时，新实现精准度更高，不是回退
- **Accessibility 权限**：Ghostty 分支依赖 System Events keystroke，需要 CodeIsland 获得"辅助功能"权限。若权限缺失，`osascript` 会静默失败并返回 false，走 fallback jump——与修复前"只 jump 不写"的体验一致，不会更糟

## 不做的事

- 不加 Warp / WezTerm 等其他终端支持（本次只修 Ghostty 这一报告问题）
- 不重构 `TerminalWriter` 通用逻辑（但见下面 Addendum：允许修复 Ghostty 分支的定位 bug）
- 不改 Allow/Deny 路径
- 不增加 UI 层面的错误提示（保持和现有写入路径一致的静默降级）

---

## Addendum 1（2026-04-15，首次实测后发现）

### 二级根因

完成 Task 1-3 后，用户在 Ghostty 下实测点击选项，`TerminalWriter.shared.sendText` 真的把 keystroke 发出去了，但落到了**错的 Ghostty 窗口**——即不是触发 AskUserQuestion 的那个 session 所在的窗口。

`ClaudeIsland/Services/Sync/TerminalWriter.swift:46-56` 的 Ghostty 分支脚本：

```applescript
tell application "Ghostty" to activate
delay 0.3
tell application "System Events"
    keystroke "<text>"
    key code 36
end tell
```

`activate` 不指定具体窗口或 tab——它只把 Ghostty app 拉到前台，`System Events keystroke` 会落到当时**最前的**那个 Ghostty 窗口。多窗口场景下必然串。

这是 `TerminalWriter` 的潜在 bug，以前只在"手机同步 + 单窗口"下被验证过所以没暴露。AskUserQuestion 修复只是把它放大到必然发生。

### 同步影响范围

手机同步链路（`SyncManager → TerminalWriter.sendText`）的 Ghostty 路径有同样的 bug——手机端消息发到有多个 Ghostty 窗口的用户时也会命中错窗口。修复 Ghostty 分支同时治好两个消费者。

### 修复方案

参考 `ClaudeIsland/Services/Window/TerminalJumper.swift:238-254 jumpViaGhostty` 已验证的写法——按 `working directory contains session.cwd` 枚举 Ghostty terminal 并 `focus` 匹配项。把它植入 `TerminalWriter.swift:46-56` Ghostty 分支脚本头部，在 `activate` 之后、`keystroke` 之前。

新脚本：

```applescript
tell application "Ghostty"
    activate
    try
        set matches to every terminal whose working directory contains "<escapedCwd>"
        if (count of matches) > 0 then
            focus (item 1 of matches)
        end if
    end try
end tell
delay 0.3
tell application "System Events"
    keystroke "<escapedText>"
    key code 36
end tell
```

要点：

- `try ... end try` 包裹 focus 块——若 Ghostty AppleScript 词典某版本不支持 `working directory` 属性，`activate` 已生效，退化到原行为不中断
- `cwd` 做 `"` 转义防注入
- `delay 0.3` 保留让 focus 切换稳定

### 代码修改面

仅 `ClaudeIsland/Services/Sync/TerminalWriter.swift:46-56` 这一分支，约 10 行替换。签名 `sendText(_ text: String, to session: SessionState) async -> Bool` 不变；调用方无感。

### 影响评审（Addendum 部分）

- **AskUserQuestion 路径**：从"发到错窗口"变成"发到对的窗口" ✅
- **手机同步路径**：顺带从 bug 变正确 ✅
- **单 Ghostty 窗口场景**：matches 仅 1 个，行为等价于原实现 ✅
- **无 cwd 匹配的 Ghostty 窗口**：focus 块跳过，回退到 `activate` 后发到最前窗口——与原行为一致，不回退 ✅
- **iTerm2 / Terminal.app / cmux 分支**：完全不触碰，无回归风险 ✅
- **AppleScript 注入风险**：text 和 cwd 都做了 `"` 转义（与 iTerm 分支相同处理），安全 ✅

### 原 "不做的事" 条款修正

> 原条款："不重构 `TerminalWriter` 内部"
>
> 修正为："不重构 `TerminalWriter` 通用逻辑；但允许修复 Ghostty 分支的多窗口定位 bug，该修复是 AskUserQuestion 修复能真正工作的前置条件。"
