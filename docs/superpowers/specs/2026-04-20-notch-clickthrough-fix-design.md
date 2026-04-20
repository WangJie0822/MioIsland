# Notch 展开态面板外点击穿透修复 · 设计

**日期**：2026-04-20
**适用版本**：当前 main (9883696 起)
**相关文件**：`ClaudeIsland/UI/Window/NotchWindow.swift`、`NotchWindowController.swift`、`NotchViewController.swift`、`ClaudeIsland/Core/NotchViewModel.swift`、`NotchGeometry.swift`、`ClaudeIsland/Events/EventMonitor.swift`、`EventMonitors.swift`

## 1. 问题

Notch 展开态下，用户点击面板实际可见矩形**之外**的屏幕区域（例如展开"暂无消息"时点击 Finder 窗口），点击被应用吞掉，下层 App 无响应。滚轮、右键、拖拽等事件同样受影响。

## 2. 根因

`NotchPanel` 窗口覆盖屏幕**全宽 × 750pt 高**（`NotchWindowController.swift:34-41`）。展开时 `ignoresMouseEvents = false`（`NotchWindowController.swift:84`），整个 750pt 区域接收事件。

事件进入 `NotchPanel.sendEvent`（`NotchWindow.swift:76-106`），通过 `contentView.hitTest(locationInWindow) == nil` 决定是否穿透。`PassThroughHostingView.hitTest` 在 opened 态直接 `return super.hitTest(point)`（`NotchViewController.swift:21-23`），NSHostingView 默认 hitTest 对 bounds 内任意点返回视图 → `sendEvent` 判定"有视图要此事件" → 事件被 SwiftUI 吞。

现有"面板外点击关闭 notch + CGEvent 重投递"路径（`NotchViewModel.handleMouseDown` + `repostClickAt`，`NotchViewModel.swift:263-316`）只覆盖 `leftMouseDown`，且通过 50ms 延迟 + CGEvent 重投递，对滚轮/右键/拖拽不适用，体感延迟明显。

## 3. 决策

**方案**：展开态下根据鼠标实时位置动态切换 `ignoresMouseEvents`。

- 鼠标在面板矩形内（含 notch 本体）→ `ignoresMouseEvents = false`，按钮响应
- 鼠标在外 → `ignoresMouseEvents = true`，**所有事件类型**（左键/右键/滚轮/拖拽/hover）直接穿透到下层 App
- 点击面板外关闭 notch 的逻辑由 `global monitor` 触发的 `handleMouseDown` 继续承担（本就存在，修复后才真正生效）

**对比备选**：
- 扩展 `sendEvent` + 每事件类型 CGEvent 重投递：滚轮/拖拽 CGEvent 无法完整复现；每次 50ms 延迟肉眼可感
- SwiftUI `contentShape`：只能让 SwiftUI 不响应，**无法**让事件到达下层 App

## 4. 架构

### 4.1 新增信号

`NotchViewModel` 暴露 `@Published var isMouseInsideInteractiveArea: Bool`，语义：鼠标当前是否位于"窗口应接收事件的区域"。

计算逻辑复用 `handleMouseMove` 中已有的矩形判定（`NotchViewModel.swift:230-239`）：

- `status == .opened`：`geometry.isPointInOpenedPanel(location, size: openedSize, horizontalOffset:)` 为 true → 内
- 其他状态：`geometry.isPointInNotch(location, expansionWidth:, horizontalOffset:)` 为 true → 内

默认值 `false`。

### 4.2 新增订阅

`NotchWindowController` 用 `Publishers.CombineLatest(viewModel.$status, viewModel.$isMouseInsideInteractiveArea)` 合并决定 `notchWindow.ignoresMouseEvents`：

| status | mouse inside | ignoresMouseEvents |
|---|---|---|
| closed / popping | — | **true**（维持现状） |
| opened | true | **false**（按钮响应） |
| opened | false | **true**（面板外全穿透） |

原 `viewModel.$status` 单独 sink（`NotchWindowController.swift:78-99`）中的 "opened → false / closed → true" 分支由合并决策替代，但**保留** `opened` 分支里 `NSApp.activate` + `makeKeyAndOrderFront` 的焦点管理逻辑（与鼠标位置无关）。

### 4.3 数据流

```
events.mouseLocation (全局 mouseMoved, 无 throttle)
      │
      ▼
NotchViewModel.handleMouseMove
      │  计算 inOpened / inNotch
      ▼
NotchViewModel.isMouseInsideInteractiveArea (@Published)
      │
      ├─────┐
      ▼     ▼
hover 自动展开逻辑     Publishers.CombineLatest ← viewModel.$status
                             │
                             ▼
                  NotchWindow.ignoresMouseEvents
```

## 5. 代码改动清单

### 5.1 删除

| 文件 | 位置 | 内容 |
|---|---|---|
| `NotchWindow.swift` | 76-106 | `NotchPanel.sendEvent` 整段 override |
| `NotchWindow.swift` | 108-133 | `NotchPanel.repostMouseEvent` 私有方法 |
| `NotchWindow.swift` | 14-19 | `restoreIgnoresMouseEventsAfterRepost` property |
| `NotchWindowController.swift` | 104-111 | 给该闭包赋值的代码段 |
| `NotchViewModel.swift` | 287-316 | `repostClickAt(_:)` 方法 |
| `NotchViewModel.swift` | 278 | `handleMouseDown` 中 `repostClickAt(location)` 的调用 |

### 5.2 调整

| 文件 | 位置 | 改动 |
|---|---|---|
| `NotchViewModel.swift` | 179 | `events.mouseLocation` 的 `.throttle(for: .milliseconds(50))` 去除。rationale：flag 切换必须紧跟鼠标位置；hover 逻辑靠 `guard newHovering != isHovering` 去重（245 行），不依赖 throttle |
| `NotchViewModel.swift` | `handleMouseMove` 内 | 计算 `inOpened || inNotch` 后同步写入新增的 `isMouseInsideInteractiveArea @Published`；`isEditing` 提前 return 时把 `isMouseInsideInteractiveArea` 置 false |
| `NotchWindowController.swift` | `init` 尾部 | 新增 `Publishers.CombineLatest($status, $isMouseInsideInteractiveArea)` 订阅，驱动 `ignoresMouseEvents` |
| `NotchWindowController.swift` | 78-99 | 保留 status sink 中 `NSApp.activate` + `makeKeyAndOrderFront` 焦点管理；移除其中直接写 `ignoresMouseEvents` 的两行（由 CombineLatest 接管） |

### 5.3 保持不变

- `PassThroughHostingView.hitTest`（`NotchViewController.swift:19-31`）：闭合态顶部 44pt 判定保留；opened 态 `super.hitTest(point)` 保留（窗口层 flag 已是主路径，再加几何判定仅增加坐标转换出错风险）
- `handleMouseDown` 中 `isPointOutsidePanel → notchClose()`（`NotchViewModel.swift:274-279`）
- `EventMonitor` 的 global + local 监听（`EventMonitor.swift:25-36`）

## 6. 边界情况

1. **首帧穿透风险**：去 throttle 后 mouseMoved 频率由 AppKit 合并（≤60Hz）。极端情况下鼠标瞬移 + 立刻点击时首次点击可能穿到下层。本设计不加 `NSTrackingArea`，先靠无 throttle 流兜底；若实测有问题再迭代（备用方案：`mouseEntered/Exited` 精确触发）
2. **多屏**：`NSEvent.mouseLocation` 是全局坐标；`openedScreenRect` 只覆盖 notch 所在屏；副屏上 `isPointInOpenedPanel` 恒 false → `ignoresMouseEvents=true`，正确
3. **过渡动画**：status 变化会立即通过 CombineLatest 触发 flag 更新；opened 首次触发时若鼠标已在面板内，flag 立即 false；若鼠标在外，flag 立即 true
4. **Live edit 模式**：`isEditing` 时 `handleMouseMove` 提前 return（`NotchViewModel.swift:222-228`）；`isMouseInsideInteractiveArea` 被置 false；status 必为 closed → ignoresMouseEvents=true，与现状一致
5. **键盘焦点**：面板外点击直达下层 App，macOS 自动把 key focus 给该 App，键盘快捷键不会被 notch panel 截获
6. **handleMouseDown 触发源**：opened + 面板外时窗口穿透 → local monitor 不触发 → global monitor 仍触发（下层 App 收到事件） → `isPointOutsidePanel` → `notchClose()`。链路闭合
7. **初始化**：`NotchWindowController.init` 初始 `ignoresMouseEvents = true`（102 行）保留作为安全默认

## 7. 验证计划

`ClaudeIslandTests/` 未 wire up，`xcodebuild test` 不可用（项目 CLAUDE.md 明确）。本修复依赖**手动验证清单**。

构建 Debug 版本后，按表逐项验证：

| # | 场景 | 预期 |
|---|---|---|
| 1 | 展开态左键点 Finder 空白 | Finder 激活 + notch 关闭 |
| 2 | 展开态在 Finder 上滚轮 | Finder 列表滚动 |
| 3 | 展开态右键点 Finder | 上下文菜单出现 |
| 4 | 展开态在 Finder 拖选文件 | 拖选正常完成 |
| 5 | 面板内点按钮（Allow/Deny 等） | 按钮响应（回归） |
| 6 | 悬停面板上 | hover 维持，不关闭 |
| 7 | 展开态点顶部菜单栏（时间/输入法/状态栏图标） | 菜单栏响应 |
| 8 | 副屏点击 | 不受影响（回归） |
| 9 | 关闭态点 notch / wings | 展开（回归） |
| 10 | 关闭态 hover 进 notch → 1s | 自动展开（回归） |
| 11 | Live edit 模式下点面板外 | 无异常（回归） |
| 12 | 鼠标快速飞入面板立即点击 | 按钮响应；失败则记录并考虑 TrackingArea 增强 |

## 8. 性能

- 去 throttle 后 mouseMoved 事件频率 ≤60Hz（AppKit 合并）
- 单事件开销：两次矩形 `contains` 判定 + 最多一次 `notchWindow.ignoresMouseEvents` 写入
- 可忽略

## 9. 回滚策略

方案隔离在 4 个文件；若线上出现严重问题（按钮完全失灵、事件全穿透等），可 `git revert` 单笔 commit 回到修复前状态，无数据迁移或配置兼容问题。
