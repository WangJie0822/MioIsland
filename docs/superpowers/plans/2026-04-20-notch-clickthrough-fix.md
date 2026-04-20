# Notch 展开态面板外点击穿透修复 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Notch 展开态下面板矩形之外的屏幕区域，对左键/右键/滚轮/拖拽等所有事件类型直接穿透到下层 App。

**Architecture:** 在 `NotchViewModel` 暴露 `isMouseInsideInteractiveArea` 信号，`NotchWindowController` 用 `Publishers.CombineLatest($status, $isMouseInsideInteractiveArea)` 动态切换 `notchWindow.ignoresMouseEvents`；同步清理旧的 `sendEvent` hitTest + CGEvent 重投递路径。

**Tech Stack:** Swift 5, SwiftUI, AppKit, Combine（仓库不含 test target，以 `xcodebuild build` + 手动验证为质量门槛）。

**Spec:** `docs/superpowers/specs/2026-04-20-notch-clickthrough-fix-design.md`

---

## 文件结构

| 操作 | 文件 | 责任 |
|---|---|---|
| 修改 | `ClaudeIsland/Core/NotchViewModel.swift` | 新增 `@Published var isMouseInsideInteractiveArea`；`handleMouseMove` 同步写入；去掉 `events.mouseLocation` 的 50ms throttle；删除 `repostClickAt` 及其调用点 |
| 修改 | `ClaudeIsland/UI/Window/NotchWindowController.swift` | `$status` sink 仅保留焦点管理；新增 `CombineLatest` 订阅驱动 `ignoresMouseEvents`；删除 `restoreIgnoresMouseEventsAfterRepost` 闭包赋值 |
| 修改 | `ClaudeIsland/UI/Window/NotchWindow.swift` | 删除 `restoreIgnoresMouseEventsAfterRepost` property、`sendEvent` override、`repostMouseEvent` 私有方法 |

---

## Task 1：NotchViewModel 改造

**Files:**
- Modify: `ClaudeIsland/Core/NotchViewModel.swift`

### Step 1.1 新增 `isMouseInsideInteractiveArea` @Published 属性

- [ ] **Edit** — 在 `isHovering` 之后插入新属性

**Old string**:
```swift
    @Published var isHovering: Bool = false

    /// Session counts for dynamic panel sizing
    @Published var sessionCount: Int = 0
```

**New string**:
```swift
    @Published var isHovering: Bool = false

    /// 鼠标当前是否位于窗口应接收事件的区域：
    /// - opened 态：位于面板矩形内（含 notch 本体）
    /// - closed / popping 态：位于 notch 本体或 wings 区域
    /// NotchWindowController 订阅该信号与 $status 合并驱动 notchWindow.ignoresMouseEvents，
    /// 实现展开态下面板外点击/滚轮/右键/拖拽直接穿透到下层 App。
    @Published var isMouseInsideInteractiveArea: Bool = false

    /// Session counts for dynamic panel sizing
    @Published var sessionCount: Int = 0
```

### Step 1.2 去掉 mouseLocation 的 50ms throttle

- [ ] **Edit** — `setupEventHandlers` 中订阅链

**Old string**:
```swift
        events.mouseLocation
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)
```

**New string**:
```swift
        // 不再 throttle：flag 切换必须紧跟鼠标位置，否则鼠标飞入面板的首次点击会穿透。
        // AppKit 已对 mouseMoved 事件做 ≤60Hz 合并；hover 逻辑靠
        // `guard newHovering != isHovering` 去重，不依赖这里的 throttle。
        events.mouseLocation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)
```

### Step 1.3 `handleMouseMove` 同步 `isMouseInsideInteractiveArea`

- [ ] **Edit** — live edit 提前 return 分支 + `newHovering` 计算后

**Old string**:
```swift
    private func handleMouseMove(_ location: CGPoint) {
        // While the user is in live edit mode, the notch is locked
        // closed and may not auto-open from hover. The live edit
        // overlay panel handles its own clicks; the notch itself
        // should be inert so opening the chat panel doesn't blow
        // away the alignment of the dashed editing frame.
        if NotchCustomizationStore.shared.isEditing {
            isHovering = false
            hoverTimer?.cancel()
            hoverTimer = nil
            return
        }
        let offset = currentHorizontalOffset
        let inNotch = geometry.isPointInNotch(
            location,
            expansionWidth: currentExpansionWidth,
            horizontalOffset: offset
        )
        let inOpened = status == .opened && geometry.isPointInOpenedPanel(
            location,
            size: openedSize,
            horizontalOffset: offset
        )

        let newHovering = inNotch || inOpened

        // Only update if changed to prevent unnecessary re-renders
        guard newHovering != isHovering else { return }

        isHovering = newHovering
```

**New string**:
```swift
    private func handleMouseMove(_ location: CGPoint) {
        // While the user is in live edit mode, the notch is locked
        // closed and may not auto-open from hover. The live edit
        // overlay panel handles its own clicks; the notch itself
        // should be inert so opening the chat panel doesn't blow
        // away the alignment of the dashed editing frame.
        if NotchCustomizationStore.shared.isEditing {
            isHovering = false
            // live edit 期间 notch window 应完全穿透，让编辑覆盖层独占交互
            if isMouseInsideInteractiveArea {
                isMouseInsideInteractiveArea = false
            }
            hoverTimer?.cancel()
            hoverTimer = nil
            return
        }
        let offset = currentHorizontalOffset
        let inNotch = geometry.isPointInNotch(
            location,
            expansionWidth: currentExpansionWidth,
            horizontalOffset: offset
        )
        let inOpened = status == .opened && geometry.isPointInOpenedPanel(
            location,
            size: openedSize,
            horizontalOffset: offset
        )

        let newHovering = inNotch || inOpened

        // 同步给 NotchWindowController 驱动 ignoresMouseEvents 切换。
        // 放在 hover 早退前更新，避免 hover 值无变化时漏发信号。
        if newHovering != isMouseInsideInteractiveArea {
            isMouseInsideInteractiveArea = newHovering
        }

        // Only update if changed to prevent unnecessary re-renders
        guard newHovering != isHovering else { return }

        isHovering = newHovering
```

### Step 1.4 删除 `handleMouseDown` 中 `repostClickAt` 调用

- [ ] **Edit** — 事件已直达下层 App，无需重投递

**Old string**:
```swift
        case .opened:
            // Close if click is outside the panel content area
            if geometry.isPointOutsidePanel(location, size: openedSize, horizontalOffset: offset) {
                notchClose()
                repostClickAt(location)
            }
```

**New string**:
```swift
        case .opened:
            // 展开态下 `ignoresMouseEvents` 在鼠标离开面板矩形时已被动态置 true，
            // 面板外的点击事件由下层 App 直接接收，本分支仅负责收起面板。
            if geometry.isPointOutsidePanel(location, size: openedSize, horizontalOffset: offset) {
                notchClose()
            }
```

### Step 1.5 删除 `repostClickAt` 整个方法

- [ ] **Edit** — 将其替换为空

**Old string**:
```swift
    /// Re-posts a mouse click at the given screen location so it reaches windows behind us
    private func repostClickAt(_ location: CGPoint) {
        // Small delay to let the window's ignoresMouseEvents update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Convert to CGEvent coordinate system (screen coordinates with Y from top-left)
            guard let screen = NSScreen.main else { return }
            let screenHeight = screen.frame.height
            let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)

            // Create and post mouse down event
            if let mouseDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseDown.post(tap: .cghidEventTap)
            }

            // Create and post mouse up event
            if let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseUp.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Actions
```

**New string**:
```swift
    // MARK: - Actions
```

---

## Task 2：NotchWindowController 改造

**Files:**
- Modify: `ClaudeIsland/UI/Window/NotchWindowController.swift`

### Step 2.1 改造 `$status` sink 并新增 CombineLatest 订阅

- [ ] **Edit** — 移除 status sink 中直接写 `ignoresMouseEvents` 的两行；追加动态切换订阅

**Old string**:
```swift
        // Dynamically toggle mouse event handling based on notch state:
        // - Closed: ignoresMouseEvents = true (clicks pass through to menu bar/apps)
        // - Opened: ignoresMouseEvents = false (buttons inside panel work)
        viewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak notchWindow, weak viewModel] status in
                switch status {
                case .opened:
                    // Accept mouse events when opened so buttons work
                    notchWindow?.ignoresMouseEvents = false
                    notchWindow?.acceptsMouseMovedEvents = true
                    // Only steal focus on user-initiated opens (click)
                    // Hover/notification opens should not interrupt typing in other apps
                    if viewModel?.shouldActivateOnOpen == true {
                        NSApp.activate(ignoringOtherApps: false)
                        notchWindow?.makeKeyAndOrderFront(nil)
                    } else {
                        notchWindow?.orderFrontRegardless()
                    }
                case .closed, .popping:
                    // Ignore mouse events when closed so clicks pass through
                    notchWindow?.ignoresMouseEvents = true
                }
            }
            .store(in: &cancellables)
```

**New string**:
```swift
        // Status sink：仅负责 opened 时的窗口焦点管理；ignoresMouseEvents 的切换
        // 交由下面的 CombineLatest(status, isMouseInsideInteractiveArea) 统一处理，
        // 让展开态下鼠标位于面板外时，点击/滚轮/右键/拖拽直接穿透到下层 App。
        viewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak notchWindow, weak viewModel] status in
                switch status {
                case .opened:
                    notchWindow?.acceptsMouseMovedEvents = true
                    // Only steal focus on user-initiated opens (click)
                    // Hover/notification opens should not interrupt typing in other apps
                    if viewModel?.shouldActivateOnOpen == true {
                        NSApp.activate(ignoringOtherApps: false)
                        notchWindow?.makeKeyAndOrderFront(nil)
                    } else {
                        notchWindow?.orderFrontRegardless()
                    }
                case .closed, .popping:
                    break
                }
            }
            .store(in: &cancellables)

        // 动态 ignoresMouseEvents：
        // - closed / popping：恒 true（事件穿透到菜单栏/下层 App，维持现状）
        // - opened + 鼠标在面板内：false（按钮可点）
        // - opened + 鼠标在面板外：true（点击/滚轮/右键/拖拽穿透到下层 App）
        Publishers.CombineLatest(viewModel.$status, viewModel.$isMouseInsideInteractiveArea)
            .receive(on: DispatchQueue.main)
            .sink { [weak notchWindow] status, insideInteractive in
                let shouldIgnore: Bool = {
                    switch status {
                    case .opened:
                        return !insideInteractive
                    case .closed, .popping:
                        return true
                    }
                }()
                guard let window = notchWindow else { return }
                if window.ignoresMouseEvents != shouldIgnore {
                    window.ignoresMouseEvents = shouldIgnore
                }
            }
            .store(in: &cancellables)
```

### Step 2.2 删除 `restoreIgnoresMouseEventsAfterRepost` 闭包赋值

- [ ] **Edit** — 闭包已无调用点

**Old string**:
```swift
        // Start with ignoring mouse events (closed state)
        notchWindow.ignoresMouseEvents = true

        // 当 NotchPanel.sendEvent 为穿透点击临时把 ignoresMouseEvents 置为 true 后，
        // 必须按当前 notch 状态恢复，否则窗口会被永久锁在忽略事件，
        // 导致 opened 面板里的按钮（如审批 Allow/Deny）完全没响应
        notchWindow.restoreIgnoresMouseEventsAfterRepost = { [weak notchWindow, weak viewModel] in
            guard let window = notchWindow else { return }
            let shouldIgnore = (viewModel?.status != .opened)
            window.ignoresMouseEvents = shouldIgnore
        }

        // Perform boot animation after a brief delay
```

**New string**:
```swift
        // Start with ignoring mouse events (closed state)
        notchWindow.ignoresMouseEvents = true

        // Perform boot animation after a brief delay
```

---

## Task 3：NotchWindow 清理

**Files:**
- Modify: `ClaudeIsland/UI/Window/NotchWindow.swift`

### Step 3.1 删除 `restoreIgnoresMouseEventsAfterRepost` property

- [ ] **Edit**

**Old string**:
```swift
// Use NSPanel subclass for non-activating behavior
class NotchPanel: NSPanel {
    /// 由 NotchWindowController 注入：当 sendEvent 为了点击穿透临时把
    /// `ignoresMouseEvents` 置为 true 后，必须由它根据当前 notch
    /// 状态把窗口恢复到正确的事件接收模式。
    /// - opened: false（按钮可点）
    /// - closed/popping: true（点击穿透到下层）
    var restoreIgnoresMouseEventsAfterRepost: (() -> Void)?

    override init(
```

**New string**:
```swift
// Use NSPanel subclass for non-activating behavior
class NotchPanel: NSPanel {
    override init(
```

### Step 3.2 删除 `sendEvent` override + `repostMouseEvent` 方法

- [ ] **Edit** — 整段 click-through 重投递已被窗口层动态 flag 替代

**Old string**:
```swift
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Click-through for areas outside the panel content

    override func sendEvent(_ event: NSEvent) {
        // For mouse events, check if we should pass through
        if event.type == .leftMouseDown || event.type == .leftMouseUp ||
           event.type == .rightMouseDown || event.type == .rightMouseUp {
            // Get the location in window coordinates
            let locationInWindow = event.locationInWindow

            // Check if any view wants to handle this event
            if let contentView = self.contentView,
               contentView.hitTest(locationInWindow) == nil {
                // No view wants this event - pass it through to windows behind
                // by temporarily ignoring mouse events and re-posting
                let screenLocation = convertPoint(toScreen: locationInWindow)
                ignoresMouseEvents = true

                // Re-post the event after a tiny delay, then恢复 ignoresMouseEvents
                // 避免窗口被永久卡在忽略状态导致 opened 面板里的按钮失效
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.repostMouseEvent(event, at: screenLocation)
                    // 给重投递事件留出穿过窗口的时间，再按当前 notch 状态恢复
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.restoreIgnoresMouseEventsAfterRepost?()
                    }
                }
                return
            }
        }

        super.sendEvent(event)
    }

    private func repostMouseEvent(_ event: NSEvent, at screenLocation: NSPoint) {
        // Convert to CGEvent coordinate system (Y from top of screen)
        guard let screen = NSScreen.main else { return }
        let screenHeight = screen.frame.height
        let cgPoint = CGPoint(x: screenLocation.x, y: screenHeight - screenLocation.y)

        let mouseType: CGEventType
        switch event.type {
        case .leftMouseDown: mouseType = .leftMouseDown
        case .leftMouseUp: mouseType = .leftMouseUp
        case .rightMouseDown: mouseType = .rightMouseDown
        case .rightMouseUp: mouseType = .rightMouseUp
        default: return
        }

        let mouseButton: CGMouseButton = event.type == .rightMouseDown || event.type == .rightMouseUp ? .right : .left

        if let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseType,
            mouseCursorPosition: cgPoint,
            mouseButton: mouseButton
        ) {
            cgEvent.post(tap: .cghidEventTap)
        }
    }
}
```

**New string**:
```swift
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
```

---

## Task 4：编译验证

**Files:** 无

### Step 4.1 运行 xcodebuild Debug

- [ ] **Bash**

```bash
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland \
    -configuration Debug -destination 'platform=macOS' \
    build 2>&1 | tail -80
```

**Expected:** 末尾输出 `** BUILD SUCCEEDED **`；无 Swift 编译错误。

如失败：按编译器提示定位错误（常见原因：属性名拼写、`Publishers.CombineLatest` 未 import Combine 等）。Combine 已在 `NotchWindowController.swift:9` 和 `NotchViewModel.swift:9` import，无需新增。

---

## Task 5：原子化提交

**Files:** 无

### Step 5.1 Stage + commit

- [ ] **Bash**

```bash
git add \
    ClaudeIsland/Core/NotchViewModel.swift \
    ClaudeIsland/UI/Window/NotchWindowController.swift \
    ClaudeIsland/UI/Window/NotchWindow.swift && \
git commit -m "[fix|UI|NotchWindow][公共]展开态面板外点击穿透：动态 ignoresMouseEvents 替代 CGEvent 重投递"
```

**Expected:** commit 创建成功；`git status` 工作区干净（本次修改只涉及上述 3 个文件）。

---

## Task 6：Intel 架构 Release 构建

**Files:** 无（产物落在 `build/intel/`）

### Step 6.1 Archive 为 Intel-only

- [ ] **Bash** — 仿照 `scripts/build.sh` 但强制 `ARCHS=x86_64`

```bash
rm -rf build/intel && mkdir -p build/intel && \
xcodebuild archive \
    -project ClaudeIsland.xcodeproj \
    -scheme ClaudeIsland \
    -configuration Release \
    -archivePath build/intel/ClaudeIsland.xcarchive \
    -destination 'generic/platform=macOS' \
    ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_STYLE=Automatic \
    2>&1 | tail -40
```

**Expected:** 末尾 `ARCHIVE SUCCEEDED`；产物 `build/intel/ClaudeIsland.xcarchive/Products/Applications/Code Island.app` 存在。

### Step 6.2 Export .app

- [ ] **Bash**

```bash
cat > build/intel/ExportOptions.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
    -archivePath build/intel/ClaudeIsland.xcarchive \
    -exportPath build/intel/export \
    -exportOptionsPlist build/intel/ExportOptions.plist \
    2>&1 | tail -30
```

**Expected:** `build/intel/export/Code Island.app` 存在。

### Step 6.3 校验架构并输出路径

- [ ] **Bash**

```bash
APP="build/intel/export/Code Island.app/Contents/MacOS/Code Island"
file "$APP"
lipo -info "$APP"
echo "---"
echo "Intel 版本 .app 路径: $(cd build/intel/export && pwd)/Code Island.app"
```

**Expected:**
- `file` 输出包含 `Mach-O 64-bit executable x86_64`
- `lipo -info` 输出 `Non-fat file: ... is architecture: x86_64`
- 打印可用路径

### Step 6.4 手动验证清单（交付用户）

按 spec §7 表格执行下列 12 项（核心 4 项最低要求）：

- [ ] 展开态左键点 Finder 空白 → Finder 激活 + notch 关闭
- [ ] 展开态在 Finder 上滚轮 → Finder 列表滚动
- [ ] 展开态右键点 Finder → 上下文菜单出现
- [ ] 展开态内点按钮（Allow/Deny 等）→ 按钮响应（回归）

如核心 4 项通过则修复确认；失败则按 spec §6 边界情况排查（首帧穿透风险可能需要 `NSTrackingArea` 增强）。

---

## 自审结论（plan 对 spec 的覆盖）

| Spec 要求 | 对应 Task |
|---|---|
| §4.1 新增 `isMouseInsideInteractiveArea` | Task 1.1、1.3 |
| §4.2 CombineLatest 订阅驱动 flag | Task 2.1 |
| §4.3 去 throttle | Task 1.2 |
| §5.1 删除清单 | Task 1.4、1.5、2.2、3.1、3.2 |
| §5.2 调整清单 | Task 1.2、1.3、2.1 |
| §5.3 保持不变项 | 未改动（PassThroughHostingView、`handleMouseDown` 主体、EventMonitor） |
| §7 验证计划 | Task 4 编译 + Task 6.4 手动验证 |

**一致性**：`isMouseInsideInteractiveArea` 属性名在 Task 1.1/1.3/2.1 保持一致；`Publishers.CombineLatest` 在 Task 2.1 唯一引用。

**无占位符**：每个 Step 均含精确 old/new 代码或可执行命令。
