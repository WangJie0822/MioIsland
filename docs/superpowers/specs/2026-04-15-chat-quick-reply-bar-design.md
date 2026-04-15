# ChatView 快速回复输入框 设计文档

**日期**：2026-04-15
**状态**：设计完成，待实现
**相关文件**：`ClaudeIsland/UI/Views/ChatView.swift`、`ClaudeIsland/Services/Sync/TerminalWriter.swift`

---

## 1. 背景与目标

### 1.1 需求

用户在灵动岛展开的 ChatView 里浏览 Claude 的回应时，经常会遇到"Claude 在自然语言里问了一个简短的确认性问题"但**没有走 AskUserQuestion 工具**的场景——比如 Claude 写完"要我继续优化这部分吗？"后等待用户答复。当前唯一的答复路径是点击"前往终端"跳转到终端再打字。这次变更在 ChatView 的"前往终端"按钮上方新增一行单行输入框，允许用户在灵动岛里直接输入简短回复（"1"、"是"、"继续"、"y" 等）并一键发送到终端。

### 1.2 设计原则

- **零摩擦**：进入 ChatView 即可直接打字，Enter 即发送，无需任何预备动作
- **不丢文本**：发送失败时保留用户已输入的内容，永远不清空
- **职责单一**：只负责"发送一段文本到目标终端"，不涉及历史、多行、格式化、图片等扩展功能
- **零新依赖**：完全复用已有的 `TerminalWriter.sendText` 通道，不引入任何新的外部 API 或 IPC 协议

### 1.3 作用范围

仅在 ChatView 的 `goToTerminalBar` 状态显示（即 `approvalTool == nil && session.phase != .ended`）。以下状态不显示：

| 状态 | 当前 bar | QuickReplyBar 是否显示 |
|---|---|---|
| 权限请求（approval） | `approvalBar` | ❌ 不显示 |
| AskUserQuestion 等交互工具 | `interactivePromptBar` | ❌ 不显示 |
| 空闲/processing/waitingForInput | `goToTerminalBar` | ✅ **显示** |
| 已结束（ended） | 无 bar | ❌ 不显示 |

## 2. 架构

### 2.1 组件划分

**新增一个组件**：`ChatQuickReplyBar`（`ClaudeIsland/UI/Views/ChatQuickReplyBar.swift`）

- 职责：承载单行输入框 + inline 错误提示 + sending 状态展示
- 不包含"前往终端"按钮（该按钮保留在现有的 `goToTerminalBar` 里不动）

**对外接口**：

```swift
struct ChatQuickReplyBar: View {
    let session: SessionState
    @FocusState.Binding var isFocused: Bool
    var onEscape: () -> Void
    // body: TextField + 可选的 error row
}
```

### 2.2 插入位置

修改 `ChatView.swift` 第 93-96 行的 `goToTerminalBar` 分支，把单一 View 改成 VStack 堆叠：

```swift
} else if session.phase != .ended {
    VStack(spacing: 0) {
        ChatQuickReplyBar(
            session: session,
            isFocused: $quickReplyFocus,
            onEscape: { viewModel.exitChat() }
        )
        goToTerminalBar
    }
    .transition(.opacity)
}
```

ChatView 需要新增一个 `@FocusState private var quickReplyFocus: Bool` 属性用于焦点管理。

### 2.3 发送通道

完全复用 `TerminalWriter.shared.sendText(_:to:)`。已验证：

- 覆盖 cmux → iTerm2 → Ghostty → Terminal.app 四条分支
- Ghostty 分支按 cwd 定位窗口（2026-04-15 刚修完的 bug 路径）
- `sendOptionToTerminal` 已在使用同一个 API，成熟度足够
- iTerm2/Terminal/Ghostty 的 AppleScript 都带回车，发送后 Claude Code TUI 自动提交 prompt

**不新增任何下游适配层。**

## 3. 焦点管理与键位

### 3.1 自动获焦触发点

**时机**：ChatQuickReplyBar 的 `.onAppear`。由于 SwiftUI 的条件渲染特性，ChatQuickReplyBar 只在进入 `goToTerminalBar` 分支时才被实例化，`.onAppear` 恰好对应：

- 初次进入可输入状态
- 从 approval/askUser 状态切换到可输入状态

```swift
.onAppear { isFocused = true }
```

**不在** `ChatView.onAppear` 获焦，原因：

- onAppear 时 `isLoading == true`，消息列表还是 spinner
- 如果 session 刚好处于 approval/askUser 状态进入 ChatView，onAppear 时输入框根本不存在
- 会话状态在 ChatView 打开后也可能动态切换，需要响应性的获焦时机

**边界 case**：会话从 approval → processing → approval → processing 来回切换时，QuickReplyBar 会被销毁和重建，每次重建都会触发 onAppear 自动获焦。

### 3.2 Enter 键

- **有非空内容**：触发发送 → 调用 `TerminalWriter.shared.sendText(trimmedText, to: session)` → 成功则清空输入框、保持焦点，失败则保留文本 + 显示 inline 错误
- **空内容**（或仅空白字符）：不做任何事，不发送

实现：`TextField` 的 `.onSubmit { handleSubmit() }`，在 handler 里做 trim + empty 检查。

### 3.3 Esc 键

使用 SwiftUI 的 `.onExitCommand { ... }` 修饰符捕获：

- **有非空内容**：清空输入框（`text = ""`），焦点保持
- **空内容**：调用父视图注入的 `onEscape` 闭包（即 `viewModel.exitChat()`），退出 ChatView 回到 session 列表

### 3.4 会话切换时的内容保留

**不保留**。`ChatView` 按 session 持有 viewModel，切换 session 会重建 ChatQuickReplyBar，其 `@State var text` 自动归零。

### 3.5 键位特性不支持清单（YAGNI）

- ❌ 上下箭头调出历史
- ❌ Shift+Enter 换行
- ❌ ⌘+Enter 的快捷键（Enter 本身就是发送）
- ❌ Tab 补全
- ❌ 字数限制

## 4. 数据流

### 4.1 发送时序

```
用户打字 "1" 并按 Enter
       │
       ▼
ChatQuickReplyBar.handleSubmit()
       │
       ├── trim 后检查非空 → OK
       ├── 立即 setSending(true)（禁用 TextField + 灰化）
       │
       ▼
await TerminalWriter.shared.sendText("1", to: session)
       │
       ├─── 成功 (Bool=true)
       │      ├── text = ""
       │      ├── errorMessage = nil
       │      ├── setSending(false)
       │      └── isFocused = true （保持焦点）
       │
       └─── 失败 (Bool=false)
              ├── text 保留不清空
              ├── errorMessage = L10n.quickReplyError
              ├── setSending(false)
              └── isFocused = true
```

### 4.2 并发保护

`isSending` 布尔状态防止用户在 AppleScript/cmux 调用未返回时反复按 Enter 造成重复发送。onSubmit handler 开头 guard：

```swift
func handleSubmit() {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isSending else { return }
    isSending = true
    Task {
        let ok = await TerminalWriter.shared.sendText(trimmed, to: session)
        await MainActor.run {
            isSending = false
            if ok {
                text = ""
                errorMessage = nil
            } else {
                errorMessage = L10n.quickReplyError
            }
            isFocused = true
        }
    }
}
```

### 4.3 Claude 回应的到达

**不需要特殊处理**。`ConversationParser` + `FileSyncScheduler` 监听 JSONL 文件，新消息自动 append 进 `ChatHistoryManager.shared.histories[sessionId]`，ChatView 第 129 行的 `.onReceive` 会把新内容 merge 进 `history` 并触发自动滚动。发送动作本身不需要等待回应。

## 5. 错误处理

### 5.1 错误分层

| 错误类型 | 触发条件 | 行为 |
|---|---|---|
| 空输入 | trimmed text 为空 | onSubmit 直接 return，无 side effect |
| 会话已结束 | `session.phase == .ended` | ChatQuickReplyBar 不会被实例化（互斥表保证），无需额外防护 |
| TerminalWriter 返回 false | cmux 找不到目标 / AppleScript 被拦截 / Accessibility 权限撤销等 | 保留输入、显示 inline 错误、写 DebugLogger |
| TerminalWriter 抛异常 | 当前 sendText 签名不 throws | 用 `await` 直接拿 Bool，无 try/catch |
| 用户连按 Enter | `isSending == true` | onSubmit 内 guard 拦截，直接 return |

### 5.2 错误消息

- **内容**：固定文案"发送失败，请重试或前往终端"，通过 `L10n.quickReplyError` 提供
- **样式**：inline 一行 11pt 红色字（`Color.red.opacity(0.85)`），位于输入框下方，顶部 padding 4
- **生命周期**：下一次成功发送时自动清空；切换 bar 状态（比如进入 approval）时也随组件销毁而清空

### 5.3 DebugLogger 日志

发送失败时写一条 log：

```swift
DebugLogger.log("Sync", "QuickReply send failed: text=\(trimmed.prefix(20)) session=\(session.sessionId.prefix(8))")
```

使用现有的 `Sync` tag，与 `TerminalWriter` 的日志共用便于排查。

### 5.4 不引入 toast 系统

项目当前没有全局 toast 组件，新增会扩大变更面积。inline 一行字足够表达错误状态。

## 6. 视觉规范

### 6.1 布局结构

```
┌───────────────────────────────────────────┐
│                                           │
│   (消息列表，带 fadeColor 渐变)            │
│                                           │
├───────────────────────────────────────────┤
│  ┌─────────────────────────────────────┐  │  ← ChatQuickReplyBar
│  │ 快速回复…                           │  │     单行 TextField
│  └─────────────────────────────────────┘  │
│  发送失败，请重试或前往终端              │  ← 仅失败时显示
├───────────────────────────────────────────┤
│  ┌─────────────────────────────────────┐  │  ← 现有 goToTerminalBar
│  │ 🖥  前往终端                         │  │
│  └─────────────────────────────────────┘  │
└───────────────────────────────────────────┘
```

### 6.2 样式细节

**TextField**：
- 背景：`Color.white.opacity(0.08)`
- 圆角：16
- 水平 padding：12
- 垂直 padding：9（目测匹配现有按钮高度的 ~75%）
- 字号：13pt regular
- 前景色：跟随 `.notchPalette()` 的 primary foreground
- placeholder："快速回复…"

**错误文案**：
- 字号：11pt
- 颜色：`Color.red.opacity(0.85)`
- 对齐：左对齐
- 顶部 padding：4

**Sending 状态**：
- TextField 透明度降到 0.6
- placeholder 变为"发送中…"
- 用户无法在此状态下输入（SwiftUI TextField 的 `.disabled(isSending)`）

**QuickReplyBar 整体容器**：
- 水平 padding：16
- 顶部 padding：10
- 底部 padding：6（为了让它和 goToTerminalBar 的顶部 padding 12 视觉连续）

### 6.3 fadeColor 渐变迁移

当前 `goToTerminalBar.overlay(alignment: .top)` 的 LinearGradient（`ChatView.swift:393-402`）挂在 goToTerminalBar 顶部，偏移 `-24`，用于和消息列表衔接。新设计下，渐变应该挂在 QuickReplyBar 上——因为 QuickReplyBar 现在是最上方的 bar，渐变需要跟随最上方 bar 的位置。

**实施方式**：在 `ChatQuickReplyBar` 的根容器上挂 `.overlay(alignment: .top) { LinearGradient ... }`，`goToTerminalBar` 的 overlay 移除。偏移、颜色、渐变停止点与原实现保持一致。

### 6.4 主题适配

遵循项目既有"card tint"惯例：`Color.white.opacity(0.08)`（输入框背景）和 `Color.white.opacity(0.12)`（按钮背景）是允许的硬编码中性值，因为它们叠加在 palette 背景之上会自动跟随主题变化。`goToTerminalBar` 的按钮就是这个写法。

其他前景色（文字、图标、错误红）必须通过 `.notchPalette()` / `.notchSecondaryForeground()` 或 `Color.red.opacity(0.85)` 等明确指定的中性值获取，不允许引入新的硬编码主题色。

## 7. 本地化

在 `ClaudeIsland/Core/Localization.swift` 新增三个字符串：

```swift
static var quickReplyPlaceholder: String { tr("Quick reply…", "快速回复…") }
static var quickReplySending: String { tr("Sending…", "发送中…") }
static var quickReplyError: String { tr("Send failed, retry or go to terminal", "发送失败，请重试或前往终端") }
```

## 8. 对现有功能的影响评审

### 8.1 不受影响的模块

- ✅ `approvalBar`（权限请求 UI）
- ✅ `interactivePromptBar`（AskUserQuestion UI）
- ✅ 非展开状态的灵动岛外观（不涉及 NotchWindow.sendEvent 或 hit-test 相关代码）
- ✅ `HookSocketServer` / `SessionStore` / `ConversationParser` 等后台服务
- ✅ `TerminalWriter` 内部实现（只作为消费方调用，不修改）
- ✅ `ChatView` 现有的 `.task` / `.onReceive` / `focusTerminal()`
- ✅ 非 ChatView 的其他视图（ClaudeInstancesView、SystemSettingsView 等）

### 8.2 受影响的模块（需验证不回归）

- ⚠️ `ChatView.body` 第 93-96 行的 `goToTerminalBar` 分支 — 从单 View 变成 VStack 容器
- ⚠️ `ChatView.swift:178` 的 `.onAppear` 注释 — 需要删除"input bar is removed"注释，改为空 body 或直接删除
- ⚠️ fadeColor 渐变的挂载位置 — 从 `goToTerminalBar.overlay` 迁移到 VStack 或 QuickReplyBar
- ⚠️ ChatView 的 FocusState 管理 — 新增 `@FocusState private var quickReplyFocus: Bool`，注意与其他可能存在的 focus 无冲突（当前 ChatView 没有别的 FocusState）

### 8.3 互斥逻辑

第 1 章 1.3 节的状态表保证了 QuickReplyBar 与其他三种 bar 的互斥性由现有的 if-else 分支直接约束，不需要 QuickReplyBar 内部做状态检查。

## 9. 测试 / 验证计划

### 9.1 测试现状

`ClaudeIslandTests/` 目录下有 `.swift` 文件但未加入 Xcode 项目，`xcodebuild test` 找不到 test bundle。**本变更不新增单元测试**——先 wire up 一个全新 test target 的成本远超本功能需求。验证以手动端到端为主。

### 9.2 手动端到端验证清单

每一项必须真实复现通过，不允许"代码看起来对所以应该能工作"。

#### 核心功能路径

- [ ] **基础发送（Ghostty）** — Ghostty 里开 Claude Code → 点灵动岛 session 卡片 → 输入框自动获焦 → 输入"1"→ Enter → Ghostty 终端出现"1"并被 Claude 提交 → 灵动岛消息列表随后更新
- [ ] **基础发送（iTerm2）** — 同上，换 iTerm2
- [ ] **基础发送（Terminal.app）** — 同上，换 Terminal.app
- [ ] **基础发送（cmux 分支）** — cmux 容器里跑 Claude Code → 确认 cmux 分支优先命中（grep DebugLogger 确认 "sendViaCmux" 日志出现）
- [ ] **多 Ghostty 窗口** — 同时开 3 个 Ghostty 窗口指向不同 cwd → 快速回复到会话 A → 文字落在 A 的窗口而非最前窗口（回归保护，4 月 15 日 Ghostty cwd 定位 bug 不能回归）

#### 边界行为

- [ ] **空输入 Enter** — 空输入按 Enter → 无任何副作用
- [ ] **空输入 Esc** — 空输入按 Esc → 退出 ChatView 回到 session 列表
- [ ] **非空输入 Esc** — 打字后按 Esc → 清空输入框，焦点保持
- [ ] **连按 Enter** — 打字后快速按两次 Enter → 只发送一次
- [ ] **会话切换不残留** — session A 打字一半 → 切到 session B → B 的输入框是空的
- [ ] **连续发送** — 发送成功后自动清空 + 保焦 → 直接再输入一条 → 再次成功
- [ ] **中文输入** — 输入"继续"→ Enter → 终端正确显示中文并提交

#### 状态互斥

- [ ] **权限请求时隐藏** — 触发 Edit 工具调用 → 显示 approvalBar → QuickReplyBar 不可见
- [ ] **AskUserQuestion 时隐藏** — 触发 AskUserQuestion → 显示 interactivePromptBar → QuickReplyBar 不可见
- [ ] **权限解除后恢复** — Allow 权限请求 → approvalBar 消失 → QuickReplyBar 重新出现并**自动获焦**
- [ ] **ended session** — 会话结束 → QuickReplyBar 和 goToTerminalBar 都不显示

#### 错误处理

- [ ] **Accessibility 权限撤销** — System Settings 关闭 Code Island 的 Accessibility → Ghostty 会话发送 → 显示红色 inline 错误、文字未清空、可重试
- [ ] **cmux 未安装降级** — 临时重命名 `/Applications/cmux.app/Contents/Resources/bin/cmux` → 发送到 cmux 会话 → 降级到 Ghostty/Terminal 分支继续发送成功
- [ ] **DebugLogger 日志** — 每次失败路径都应在 `~/.claude/.codeisland.log` 里产生一条 `Sync` tag 的日志

#### 回归保护

- [ ] **fadeColor 渐变仍在** — 消息列表底部到 QuickReplyBar 之间的渐变可见
- [ ] **notchPalette 主题** — 切换一次 notch 主题（Classic → Mono）→ QuickReplyBar 颜色跟随主题切换
- [ ] **灵动岛点击外部** — 灵动岛打开状态下点击外部区域 → 灵动岛合拢（不会因为 TextField 是 firstResponder 阻塞合拢）
- [ ] **FocusState + 多 session 卡片** — 连续点开三个不同 session 的 ChatView → 每次都自动获焦成功

### 9.3 执行顺序

1. 实现完成后 `xcodebuild build` 确认无编译错误
2. 替换 `/Applications/Code Island.app`（`CodeLightLocalSupport` 自动拷贝保留 Accessibility 权限）
3. Ghostty 单窗口场景先跑一遍（最典型路径）
4. 逐项打勾清单
5. 所有项通过后进入 git commit / PR

### 9.4 关键风险与兜底

**风险**：SwiftUI 的 `.onExitCommand` 在 NSPanel（尤其 `.nonactivatingPanel`）里可能不生效，Esc 键捕获失败。

**兜底方案**：如果实测 `.onExitCommand` 不触发，退路是在 `NotchWindow` 里重写 `keyDown(with:)`，手动检测 `keyCode == 53`（Esc）并通过 NotificationCenter 发一个 "quickReply.escape" 广播给 ChatView 处理。这个兜底不进入 spec 默认路径，只在实现阶段发现问题时启用。

## 10. 性能影响

可忽略。新增一个 TextField + 一个 Text，SwiftUI 视图树深度 +1。TerminalWriter 调用路径未变。JSONL 监听、Hook IPC、NotchWindow hit-test 都未触及。

## 11. 回滚路径

如果发现严重问题，回滚步骤：

1. 从 `ChatView.body` 的 goToTerminalBar 分支移除 VStack 和 ChatQuickReplyBar 引用
2. 删除 `ChatQuickReplyBar.swift`
3. 恢复 `ChatView.swift:178` 的原注释（或保持删除）
4. 撤销 `Localization.swift` 新增的三个字符串
5. 撤销 fadeColor overlay 的迁移（恢复到 `goToTerminalBar.overlay`）
6. 从 Xcode project 里移除 `ChatQuickReplyBar.swift`

本功能不涉及持久化、`settings.json`、Hook、IPC 协议变更，回滚没有数据迁移风险。

## 12. 不做的事（明确 YAGNI 清单）

- ❌ 多行输入 / TextEditor
- ❌ 发送历史（上下箭头调出）
- ❌ 自动补全 / slash command 建议
- ❌ 图片粘贴 / 拖拽文件
- ❌ 字数限制
- ❌ 按 sessionId 持久化未发送的草稿
- ❌ 全局 toast 系统
- ❌ 单元测试（现有测试基础设施未 wire up，成本过高）
- ❌ 自定义发送快捷键（Enter 即发送，固定行为）
- ❌ 发送后关闭灵动岛（保持打开连续使用）

---

**结束。** 本文档覆盖需求、架构、数据流、错误处理、视觉规范、本地化、影响评审、验证计划、回滚路径和 YAGNI 清单。下一步交给 `writing-plans` skill 生成可执行的实现计划。
