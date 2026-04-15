# ChatView 快速回复输入框 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `ChatView` 的 `goToTerminalBar` 上方新增一行单行输入框，允许用户在灵动岛里快速发送简短文本回复到目标终端，完全复用既有的 `TerminalWriter.sendText` 通道。

**Architecture:** 新增独立组件 `ChatQuickReplyBar`（放在单独的 `.swift` 文件里保持文件职责聚焦），承载 TextField + inline 错误提示 + sending 状态。在 `ChatView.body` 的 `goToTerminalBar` 分支里用 VStack 把新组件堆在原按钮上方，互斥逻辑不变。`.notchPalette()` 主题适配自动继承自 `ChatView` 根容器。

**Tech Stack:** Swift 5/6, SwiftUI (TextField/FocusState/onExitCommand), AppKit hybrid。利用项目既有的 `PBXFileSystemSynchronizedRootGroup`，新文件无需手动改 `.xcodeproj`。

**Spec:** `docs/superpowers/specs/2026-04-15-chat-quick-reply-bar-design.md`

---

## Pre-flight Notes（给执行者）

在开始前必须知道的几点：

1. **工作目录必须是 `/Users/wj/Work/OpenSource/CodeIsland`**。第一件事是 `pwd` 确认匹配后再动手。
2. **Xcode 项目使用 `PBXFileSystemSynchronizedRootGroup`**。新建 `.swift` 文件只需放到 `ClaudeIsland/` 目录下相应位置，Xcode 会自动加入 build target，**不要手动编辑 `ClaudeIsland.xcodeproj/project.pbxproj`**。
3. **项目没有 wire up 的测试 target**。`xcodebuild test` 找不到 test bundle；本功能的验证是**编译 + 手动端到端**，不是 xctest。单元测试相关步骤一律跳过，最后 Task 4 有完整的手动验证清单。
4. **Build 命令**（copy-paste 即可）：
   ```bash
   xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland \
     -configuration Debug -destination 'platform=macOS' build \
     CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" 2>&1 | tail -5
   ```
   成功标志：`** BUILD SUCCEEDED **`。
5. **Spec 实现偏差说明**（需要留意两点）：
   - Spec §2.2 描述为 ChatView 新增 `@FocusState private var quickReplyFocus: Bool`。**实际实现复用已有的 `ChatView.swift:28` 的 `@FocusState private var isInputFocused: Bool`**（fork 自上游 Claude Island 的历史 state，当前未被任何 view 使用）。语义仍然是"输入框焦点"，不改名以减少变更面积。
   - Spec §8.2 有一行"当前 ChatView 没有别的 FocusState"——**这个陈述与实际不符**（已有 `isInputFocused`）。不影响实现，但下次修 spec 时要顺手纠正。
6. **Debug 构建产物的安装路径**：项目有 `CodeLightLocalSupport` 会把 Debug build 自动拷贝到 `/Applications/Code Island.app`，以保留 Accessibility 权限。手动验证时直接从 Applications 启动即可——不要从 `build/` 目录启动那个没签名的版本。
7. **提交规范**：`[类型|模块|功能][影响范围]描述`，中文。每个 Task 结尾都给出了完整 commit message，照抄即可。

---

## File Structure

本次变更涉及 3 个文件：

| 文件 | 操作 | 职责 |
|---|---|---|
| `ClaudeIsland/Core/Localization.swift` | Modify | 新增 3 个本地化字符串：`quickReplyPlaceholder` / `quickReplySending` / `quickReplyError` |
| `ClaudeIsland/UI/Views/ChatQuickReplyBar.swift` | **Create** | 新组件：TextField + inline 错误提示 + 发送逻辑。独立文件，~120 行 |
| `ClaudeIsland/UI/Views/ChatView.swift` | Modify | ① 删除 `inputText` 死代码 state；② 将 `goToTerminalBar` 分支包进 VStack，在上方插入 `ChatQuickReplyBar`；③ 将 fadeColor overlay 从 `goToTerminalBar` 迁到 `ChatQuickReplyBar` 内部；④ 更新 `onAppear` 的遗留注释 |

拆分原则：`ChatQuickReplyBar` 放独立文件而不是塞进已经 1261 行的 `ChatView.swift`，因为它是一个职责明确的独立 UI 单元（类似 `ChatApprovalBar`/`ChatInteractivePromptBar`，但那两个目前和 `ChatView` 挤在同一个文件里——本次不动它们，只保证新组件从一开始就是干净的单文件）。

---

## Task 1: 新增 Localization 字符串

**Files:**
- Modify: `ClaudeIsland/Core/Localization.swift:179-180`

- [ ] **Step 1: 确认工作目录并打开文件**

```bash
pwd   # 必须输出 /Users/wj/Work/OpenSource/CodeIsland
```

打开 `ClaudeIsland/Core/Localization.swift`，定位到第 179-180 行（`goToTerminal` 和 `terminal` 字符串所在位置）。

- [ ] **Step 2: 插入三个新字符串**

在第 180 行的 `static var terminal: String { tr("Terminal", "终端") }` 之后、第 181 行空行之前，插入以下内容：

```swift
    static var quickReplyPlaceholder: String { tr("Quick reply…", "快速回复…") }
    static var quickReplySending: String { tr("Sending…", "发送中…") }
    static var quickReplyError: String { tr("Send failed, retry or go to terminal", "发送失败，请重试或前往终端") }
```

插入后该区域应该是：

```swift
    static var goToTerminal: String { tr("Go to Terminal", "前往终端") }
    static var terminal: String { tr("Terminal", "终端") }
    static var quickReplyPlaceholder: String { tr("Quick reply…", "快速回复…") }
    static var quickReplySending: String { tr("Sending…", "发送中…") }
    static var quickReplyError: String { tr("Send failed, retry or go to terminal", "发送失败，请重试或前往终端") }

    // MARK: - Session state
```

- [ ] **Step 3: 编译验证**

```bash
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland \
  -configuration Debug -destination 'platform=macOS' build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`。字符串尚未被任何 view 引用，所以 build 仍然成功——只是把字符串 ready 在那里等 Task 2 使用。

- [ ] **Step 4: Commit**

```bash
git add ClaudeIsland/Core/Localization.swift
git commit -m "[feat|UI|本地化][公共]新增 ChatQuickReplyBar 三个本地化字符串"
```

---

## Task 2: 创建 ChatQuickReplyBar 组件

**Files:**
- Create: `ClaudeIsland/UI/Views/ChatQuickReplyBar.swift`

- [ ] **Step 1: 确认目标目录存在**

```bash
ls ClaudeIsland/UI/Views/ | head
```

Expected: 看到 `ChatView.swift`、`ClaudeInstancesView.swift` 等文件。确认 `UI/Views/` 目录存在。

- [ ] **Step 2: 创建 `ChatQuickReplyBar.swift` 并填入完整内容**

创建 `ClaudeIsland/UI/Views/ChatQuickReplyBar.swift`：

```swift
//
//  ChatQuickReplyBar.swift
//  ClaudeIsland
//
//  灵动岛 ChatView 里的快速回复输入框：单行 TextField，Enter 发送，
//  发送通道完全复用 TerminalWriter.sendText。仅在 goToTerminalBar
//  状态（非 approval、非 AskUserQuestion、非 ended）下出现。
//  设计文档：docs/superpowers/specs/2026-04-15-chat-quick-reply-bar-design.md
//

import SwiftUI

struct ChatQuickReplyBar: View {
    let session: SessionState
    @FocusState.Binding var isFocused: Bool
    var onEscape: () -> Void

    // 组件内部管理文本、发送状态和错误消息，
    // 不向外暴露，避免父视图 ChatView 污染。
    @State private var text: String = ""
    @State private var isSending: Bool = false
    @State private var errorMessage: String? = nil

    /// 与 messageList 衔接的渐变色，等同于原 goToTerminalBar 里那段。
    /// palette 切换时会跟随变化，这里从 ChatView 继承的
    /// `.notchPalette()` environment 读取。
    @Environment(\.colorScheme) private var colorScheme
    private var fadeColor: Color {
        // 与 goToTerminalBar 原 overlay 里保持一致：palette bg 的半透明
        Color.black.opacity(0.0)  // 起点透明
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 输入框本体
            TextField(
                isSending ? L10n.quickReplySending : L10n.quickReplyPlaceholder,
                text: $text
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($isFocused)
            .disabled(isSending)
            .onSubmit { handleSubmit() }
            .onExitCommand { handleEscape() }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    )
            )
            .opacity(isSending ? 0.6 : 1.0)

            // 错误提示行（仅失败时显示）
            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(Color.red.opacity(0.85))
                    .padding(.top, 4)
                    .padding(.leading, 4)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .overlay(alignment: .top) {
            // 消息列表到输入框之间的淡出渐变（原本挂在 goToTerminalBar 上，
            // 现在挪到最上方 bar 即 QuickReplyBar 上）。
            LinearGradient(
                colors: [
                    Color.black.opacity(0),
                    Color.black.opacity(0.7)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: -24)
            .allowsHitTesting(false)
        }
        .onAppear {
            // SwiftUI @FocusState 在 view 刚实例化时直接赋值 true
            // 有时会被后续渲染清掉，加一次短暂 yield 再设以保可靠。
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                isFocused = true
            }
        }
    }

    // MARK: - Actions

    private func handleSubmit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空内容或正在发送：直接丢弃，不产生副作用
        guard !trimmed.isEmpty, !isSending else { return }

        isSending = true
        errorMessage = nil
        let target = session

        Task {
            let ok = await TerminalWriter.shared.sendText(trimmed, to: target)
            await MainActor.run {
                isSending = false
                if ok {
                    text = ""
                    errorMessage = nil
                } else {
                    errorMessage = L10n.quickReplyError
                    DebugLogger.log(
                        "Sync",
                        "QuickReply send failed: text=\(trimmed.prefix(20)) session=\(target.sessionId.prefix(8))"
                    )
                }
                isFocused = true
            }
        }
    }

    private func handleEscape() {
        if text.isEmpty {
            // 空输入时退出 ChatView 回到 session 列表
            onEscape()
        } else {
            // 非空时只清空输入框，焦点保持
            text = ""
            errorMessage = nil
        }
    }
}
```

关键点解释（给代码审查者看）：

- `@FocusState.Binding var isFocused: Bool` — 父视图 `ChatView` 通过 `$isInputFocused` 传入，子组件用 `.focused($isFocused)` 绑定到 TextField。
- `.onAppear` 里的 50ms `Task.sleep` — SwiftUI 的 `@FocusState` 在 view 初始化瞬间直接赋 `true` 有时不生效（view hierarchy 未建立完成），加一个极短 yield 让 SwiftUI 先渲染一轮。50ms 对用户无感。
- `.onExitCommand` — SwiftUI 原生的 Esc 捕获修饰符，在 NSPanel 里预期能工作；如果实测失败，Task 4 验证清单会暴露，届时用 spec §9.4 的 keyDown 兜底方案。
- 发送失败**不清空** `text`，只设 `errorMessage`，用户可直接重试。
- `DebugLogger.log("Sync", ...)` 使用既有 tag，和 `TerminalWriter` 的日志混在一起便于排查。
- fadeColor overlay 从 `ChatView.goToTerminalBar` 迁移到这里的根容器，偏移和渐变色保持原实现一致。

- [ ] **Step 3: 编译验证（此时组件存在但未被引用）**

```bash
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland \
  -configuration Debug -destination 'platform=macOS' build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`。新组件是独立 struct，不被任何地方引用仍然能编译。

**如果失败**：常见原因是 `L10n.quickReplyXxx` 找不到——说明 Task 1 没执行或字符串拼写不一致，回去检查 Localization.swift。

- [ ] **Step 4: Commit**

```bash
git add ClaudeIsland/UI/Views/ChatQuickReplyBar.swift
git commit -m "[feat|UI|ChatQuickReplyBar][公共]新增 ChatView 快速回复输入框组件"
```

---

## Task 3: 在 ChatView 接入 ChatQuickReplyBar

**Files:**
- Modify: `ClaudeIsland/UI/Views/ChatView.swift:18` — 删除 `inputText` 死代码
- Modify: `ClaudeIsland/UI/Views/ChatView.swift:93-96` — goToTerminalBar 分支改 VStack
- Modify: `ClaudeIsland/UI/Views/ChatView.swift:177-179` — 清理过时注释
- Modify: `ClaudeIsland/UI/Views/ChatView.swift:393-402` — 删除 goToTerminalBar 的 fadeColor overlay（已迁到 ChatQuickReplyBar）

- [ ] **Step 1: 删除 `inputText` 死代码**

打开 `ClaudeIsland/UI/Views/ChatView.swift`，定位第 18 行：

```swift
    @State private var inputText: String = ""
```

**整行删除**。这是 fork 自上游 Claude Island 的旧 input bar state，当前没有任何 view 引用它。ChatQuickReplyBar 组件内部管理自己的 `text` state，不需要外部传入。

**不要动** 第 28 行的 `@FocusState private var isInputFocused: Bool`——这个要在 Step 2 里复用作为 ChatQuickReplyBar 的 focus binding。

- [ ] **Step 2: 修改 goToTerminalBar 分支为 VStack + 接入新组件**

定位第 93-96 行当前代码：

```swift
                } else if session.phase != .ended {
                    goToTerminalBar
                        .transition(.opacity)
                }
```

替换为：

```swift
                } else if session.phase != .ended {
                    VStack(spacing: 0) {
                        ChatQuickReplyBar(
                            session: session,
                            isFocused: $isInputFocused,
                            onEscape: { viewModel.exitChat() }
                        )
                        goToTerminalBar
                    }
                    .transition(.opacity)
                }
```

关键：`isFocused: $isInputFocused` 复用 ChatView 第 28 行已有的 `@FocusState private var isInputFocused: Bool`，不新建属性。

- [ ] **Step 3: 删除 goToTerminalBar 的 fadeColor overlay**

定位第 393-402 行（`goToTerminalBar` 内部的 `.overlay(alignment: .top) { LinearGradient ... }` 那一段），具体代码是：

```swift
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [fadeColor.opacity(0), fadeColor.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: -24) // Push above input bar
            .allowsHitTesting(false)
        }
```

**整个 `.overlay(alignment: .top) { ... }` 调用链删除**。原因：QuickReplyBar 现在是最上方的 bar，渐变应该挂在它身上；保持在 `goToTerminalBar` 会让渐变落到 QuickReplyBar 和 goToTerminalBar 的交界处，变成一条多余的装饰线。

同时注意这段代码上面的 `// Push above input bar` 注释也一起删掉了（随 overlay 整体删除）。

**保留**：`.zIndex(1)` 这行不动，它是 goToTerminalBar 相对消息列表的层级，仍然需要。

删除后 `goToTerminalBar` 的结构大致是：

```swift
    private var goToTerminalBar: some View {
        HStack(spacing: 10) {
            Button { ... } label: { ... }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.04))
        .zIndex(1) // Render above message list
    }
```

- [ ] **Step 4: 清理过时的 onAppear 注释**

定位第 177-179 行：

```swift
        .onAppear {
            // No auto-focus needed since input bar is removed
        }
```

**整个 `.onAppear { ... }` 删除**。ChatView 不再需要做任何 onAppear 工作——焦点管理已经下沉到 ChatQuickReplyBar 的 `.onAppear`，而 ChatView 本身没有别的 onAppear 逻辑。

删除后第 176 行的 `}` 和第 180 行的 `}` 会自然合拢，body 结束于 `.onReceive(sessionMonitor.$instances) { ... }`。

**校验**：删除前后，确保 `body` 的 view 修饰符链顺序保持合理，不要意外把 `.onReceive` 和外层大括号搞乱。

- [ ] **Step 5: 编译验证**

```bash
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland \
  -configuration Debug -destination 'platform=macOS' build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`。

**常见失败模式**：

- `cannot find 'ChatQuickReplyBar' in scope` — 说明 Task 2 没执行或文件未落到 `ClaudeIsland/UI/Views/` 目录下
- `cannot find 'inputText' in scope` — 如果有别的地方引用了 `inputText`（虽然我们检查时没发现）会在这里报出来，用 `grep -n inputText ClaudeIsland/UI/Views/ChatView.swift` 找引用点一并清理
- `value of type 'NotchViewModel' has no member 'exitChat'` — 说明项目版本比预期老，`exitChat` 方法名可能不同，grep 一下 `func exitChat\|viewModel.exitChat` 确认

- [ ] **Step 6: Commit**

```bash
git add ClaudeIsland/UI/Views/ChatView.swift
git commit -m "[feat|UI|ChatView][公共]goToTerminalBar 上方接入快速回复输入框 ChatQuickReplyBar"
```

---

## Task 4: 端到端手动验证

本项目没有 wire up 测试 target，必须逐项手动验证。每一项都**真实操作**并打勾或记录失败原因。失败时不要自行"猜测修复"，根据失败表现回到相应 Task 定位问题再改。

- [ ] **Step 1: 部署 Debug build 到 `/Applications/Code Island.app`**

运行 Debug 构建；`CodeLightLocalSupport` 会自动把产物拷贝到 `/Applications/Code Island.app` 以保留 Accessibility 权限。

```bash
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland \
  -configuration Debug -destination 'platform=macOS' build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" 2>&1 | tail -5
```

确认 `** BUILD SUCCEEDED **`，然后：

```bash
# 重启 Code Island 让新二进制生效
osascript -e 'quit app "Code Island"' 2>/dev/null || true
sleep 1
open -a "Code Island"
```

- [ ] **Step 2: 核心功能路径验证**

打开 Ghostty，`cd` 到任一测试目录，运行 `claude`，在灵动岛看到 session 卡片后点开进入 ChatView。

| # | 场景 | 期望 |
|---|---|---|
| 2.1 | **Ghostty 基础发送** — 进入 ChatView 后光标是否自动出现在输入框 | 输入框焦点自动获取，光标闪烁 |
| 2.2 | 在输入框打"1"然后按 Enter | Ghostty 终端出现"1"并被 Claude 提交；灵动岛消息列表随后更新；输入框清空并保持焦点 |
| 2.3 | 在输入框打"继续"（中文）然后按 Enter | 中文正确发送并被 Claude 处理 |
| 2.4 | 连续发送第二条"再写一个单测" | 不需要再次点击输入框，直接可以打字；第二次 Enter 发送成功 |
| 2.5 | **iTerm2 基础发送** — 在 iTerm2 跑一个 Claude 会话重复 2.2 | 相同结果，iTerm2 终端收到文本 |
| 2.6 | **Terminal.app 基础发送** — 同上换 Terminal.app | 相同结果 |
| 2.7 | **cmux 分支** — 在 cmux 容器里跑 Claude 会话，发送文本 | `~/.claude/.codeisland.log` 里看到 "sendViaCmux" 相关日志；终端收到文本 |
| 2.8 | **多 Ghostty 窗口** — 同时开 3 个 Ghostty 窗口 cwd 不同 → 从灵动岛向 session A 发送 | 文字落到会话 A 的窗口，不是最前那个窗口 |

- [ ] **Step 3: 边界行为验证**

| # | 场景 | 期望 |
|---|---|---|
| 3.1 | **空输入 Enter** — 输入框为空按 Enter | 无任何副作用，终端无输入 |
| 3.2 | **空输入 Esc** — 输入框为空按 Esc | 退出 ChatView 回到 session 列表 |
| 3.3 | **非空输入 Esc** — 打字"test"后按 Esc | 输入框清空，仍然在 ChatView，焦点保持 |
| 3.4 | **纯空白字符** — 输入框打三个空格按 Enter | 无副作用（trim 后为空） |
| 3.5 | **连按 Enter** — 打"test"后快速连按两次 Enter | 只发送一次（`isSending` guard 保护） |
| 3.6 | **会话切换不残留** — session A 打字一半不发送 → 点 ChatView 返回箭头回到 session 列表 → 进入 session B | B 的输入框是空的 |

- [ ] **Step 4: 状态互斥验证**

| # | 场景 | 期望 |
|---|---|---|
| 4.1 | **权限请求时隐藏** — 在终端让 Claude 做一个 Edit 工具调用 → ChatView 显示 approvalBar | QuickReplyBar 不可见，只有 Allow/Deny |
| 4.2 | **AskUserQuestion 时隐藏** — 让 Claude 触发 AskUserQuestion → ChatView 显示 interactivePromptBar | QuickReplyBar 不可见，只有"前往终端"按钮 |
| 4.3 | **权限解除后恢复** — 点 Allow 批准权限请求 → approvalBar 消失 → ChatView 回到 goToTerminalBar 状态 | QuickReplyBar 重新出现，**焦点自动获取**（无需再点一次） |
| 4.4 | **ended session** — `/exit` 退出 Claude → 灵动岛显示 session 为已结束 | QuickReplyBar 和 goToTerminalBar 都不显示 |

- [ ] **Step 5: 错误处理验证**

| # | 场景 | 期望 |
|---|---|---|
| 5.1 | **Accessibility 撤销** — System Settings → Privacy & Security → Accessibility，把 Code Island 开关关掉 → 在 Ghostty 会话里发送"test" | 输入框下方出现红色 inline 错误"发送失败，请重试或前往终端"；`text` 未被清空；可以直接再按 Enter 重试 |
| 5.2 | **恢复 Accessibility 后重试** — 打开 Accessibility 开关 → 按 Enter 重试 | 发送成功，错误消息消失，text 清空 |
| 5.3 | **DebugLogger 日志** — 失败发送后，查日志 | `grep QuickReply ~/.claude/.codeisland.log` 能看到 `QuickReply send failed: text=...` 这一条 |
| 5.4 | **cmux 未安装降级**（可选，依赖机器配置） — 临时重命名 `/Applications/cmux.app/Contents/Resources/bin/cmux` → 发送到非 cmux 会话 | 降级到 Ghostty/Terminal 分支仍能发送成功 |

- [ ] **Step 6: 回归保护验证**

| # | 场景 | 期望 |
|---|---|---|
| 6.1 | **fadeColor 渐变** — 观察消息列表底部到 QuickReplyBar 之间的视觉衔接 | 渐变可见且和迁移前视觉一致（稍微从透明到深色淡出） |
| 6.2 | **notchPalette 主题切换** — 打开 Notch Customization，切换主题（比如 Classic → Mono）再切回来 | QuickReplyBar 的 TextField 背景/文字随主题变色，不残留旧主题颜色 |
| 6.3 | **灵动岛点击外部合拢** — 灵动岛打开 ChatView 状态下点击屏幕其他区域 | 灵动岛正常合拢，不会因为 TextField 是 firstResponder 阻塞 |
| 6.4 | **多 session FocusState 切换** — 连续点开 3 个不同 session 的 ChatView（先 A 再 B 再 C） | 每次进入都自动获焦成功，不会"第二次进入没自动获焦" |
| 6.5 | **AskUser 选项按钮仍然工作** — 让 Claude 触发 AskUserQuestion → 点一个选项按钮（编号 1/2/3） | 数字被发送到终端（既有 `sendOptionToTerminal` 功能不回归） |
| 6.6 | **灵动岛审批按钮仍然工作** — 触发权限请求 → 点 Allow | 权限被批准，Claude 继续工作（既有 approval 流程不回归） |

- [ ] **Step 7: 汇总验证结果**

如果上述所有条目全部通过：

```bash
echo "All manual E2E checks passed"
```

如果有条目失败，**不要提交**。根据失败场景回溯到对应 Task：
- 编译错误 → Task 1/2/3 代码有问题
- 自动获焦失败（2.1/4.3/6.4）→ ChatQuickReplyBar 的 `.onAppear` 策略有问题
- Esc 键不响应（3.2/3.3）→ `.onExitCommand` 在 NSPanel 里不生效，启用 spec §9.4 兜底方案（NotchWindow keyDown override）
- fadeColor 视觉异常（6.1）→ Task 3 Step 3 的 overlay 迁移有误
- 发送到错误窗口（2.8）→ 这是既有 Ghostty bug 的回归，检查 `TerminalWriter.swift` 的 Ghostty 分支是否被意外触碰

- [ ] **Step 8: 最终 commit（如 Step 1-7 全部通过）**

Task 1-3 已经各自 commit 过，Task 4 只是验证不产生代码变更。这一步不需要 commit；如果过程中发现小问题做了修复，按修复内容单独 commit。

验证通过后：

```bash
git log --oneline -5
```

应该看到三个本次功能的 commit（Task 1/2/3）加上之前的历史。

---

## Self-Review 结果

写完后我按 writing-plans skill 的要求回头检查了一遍：

### 1. Spec 覆盖检查

| Spec 要求 | 对应 Task |
|---|---|
| §2.1 新组件 `ChatQuickReplyBar` | Task 2 |
| §2.2 插入位置 `goToTerminalBar` 分支 VStack | Task 3 Step 2 |
| §2.3 复用 `TerminalWriter.sendText` | Task 2 Step 2（handleSubmit 内部） |
| §3.1 自动获焦（onAppear）| Task 2 Step 2（组件内部 `.onAppear` + 50ms yield）|
| §3.2 Enter 发送 + 空内容跳过 | Task 2 Step 2（`handleSubmit` guard）|
| §3.3 Esc 两段处理 | Task 2 Step 2（`handleEscape`）|
| §3.4 会话切换不保留 | Task 2 Step 2（`@State var text` 天然随组件销毁）|
| §4.1 发送时序 | Task 2 Step 2 完整实现 |
| §4.2 并发保护（isSending）| Task 2 Step 2（guard + disabled）|
| §4.3 Claude 回应通过既有 JSONL 监听 | 无需额外代码，Task 4 2.2 验证 |
| §5.1 错误分层 | Task 2 Step 2 |
| §5.2 inline 错误样式 | Task 2 Step 2（errorMessage Text）|
| §5.3 DebugLogger 日志 | Task 2 Step 2 |
| §6 视觉规范 | Task 2 Step 2 + Task 3 Step 3（fadeColor 迁移）|
| §7 本地化三字符串 | Task 1 |
| §9.2 手动验证清单 | Task 4 Step 2-6 |
| §9.4 Esc 兜底方案 | Task 4 Step 7 失败指引里引用 |
| §11 回滚路径 | 各 Task 天然可回滚（三个独立 commit 可独立 revert）|

所有 spec 要求都有对应任务。

### 2. 占位符扫描

本 plan 无 TBD / TODO / "implement later" / "add appropriate error handling" / "similar to Task N" 等红旗词。所有代码块都是完整可落地的实现。

### 3. 类型/命名一致性

- `ChatQuickReplyBar` 在 Task 2 和 Task 3 Step 2 完全一致
- `isFocused` 作为 `@FocusState.Binding var` 在 Task 2 接口定义和 Task 3 Step 2 调用参数一致
- `onEscape` 闭包签名在 Task 2 接口和 Task 3 Step 2 调用一致
- `L10n.quickReplyPlaceholder` / `L10n.quickReplySending` / `L10n.quickReplyError` 在 Task 1 定义和 Task 2 使用一致
- `handleSubmit` / `handleEscape` 为 Task 2 内部 private 方法，外部无引用
- `TerminalWriter.shared.sendText(_:to:)` 签名与现有 `ClaudeIsland/Services/Sync/TerminalWriter.swift:25` 一致
- `DebugLogger.log("Sync", ...)` 使用既有 API，tag 复用
