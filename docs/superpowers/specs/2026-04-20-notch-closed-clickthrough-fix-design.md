# Notch 折叠态点击穿透到桌面修复 · 设计

**日期**：2026-04-20
**适用版本**：当前 main（b3fa9d8 起）
**相关文件**：`ClaudeIsland/UI/Window/NotchWindowController.swift`、`NotchWindow.swift`、`NotchViewController.swift`、`ClaudeIsland/Core/NotchViewModel.swift`

## 1. 问题

Notch 折叠态（`.closed`/`.popping`）下，用户点击 notch 本体或 wings 展开面板时，同一次点击事件会同时穿透到下层——若下层为 Finder 桌面、且 macOS 开启"点按墙纸以显示桌面"（Sonoma+ 默认），所有窗口被隐藏，桌面被暴露。视觉上表现为：点击灵动岛 → notch 展开 + 当前所有窗口消失。

## 2. 根因

`NotchWindowController.swift:105-112` 中 `shouldIgnore` 计算对 `.closed`/`.popping` 恒返回 `true`：

```swift
case .closed, .popping:
    return true
```

NotchPanel 因此始终 `ignoresMouseEvents = true`，原生行为就是把所有鼠标事件穿透给下层窗口。同时 `EventMonitors.shared.mouseDown` 是通过 `NSEvent.addGlobalMonitorForEvents` 旁听（`EventMonitor.swift:27-28`）——**只能只读监听，无法阻断事件**。

事件流：
```
点击 notch (折叠态)
   │
   ├─► NotchPanel 忽略事件 → 事件穿到 Finder 桌面 → 触发 "点按墙纸显示桌面"
   │
   └─► Global mouseDown monitor 捕获位置 → isPointInNotch → notchOpen(.click)
```

这就是用户看到的"展开 + 显示桌面"同时发生的原因。

## 3. 决策

**方案**：把 `.closed`/`.popping` 态的 `ignoresMouseEvents` 也接入已有的 `isMouseInsideInteractiveArea` 动态信号，与 `.opened` 态共用一套逻辑。

- 鼠标在 notch 几何（含 wings ≈ 460pt × 37pt）→ `ignoresMouseEvents = false` → 点击被 NotchPanel 独占接收，不穿透
- 鼠标在外 → `ignoresMouseEvents = true` → 菜单栏/其他应用照常点击穿透

对比备选：
- **保留旁听 global monitor + 注入阻断**：`addGlobalMonitorForEvents` 语义上不支持阻断；改成 `CGEventTap` 需要辅助功能权限升级且全系统影响面大，成本不对等
- **让 hitTest 在 notch 几何内 `return self`**：前提仍是窗口层 `ignoresMouseEvents = false`，最终还是要走动态切换路径，不如直接在窗口层统一

## 4. 架构

### 4.1 `isMouseInsideInteractiveArea` 语义（已具备，无改动）

`NotchViewModel.handleMouseMove` 已同时计算 `inNotch` 与 `inOpened` 并写入该 `@Published`（`NotchViewModel.swift:263-280`）：

- 折叠态：`geometry.isPointInNotch(location, expansionWidth:, horizontalOffset:)` → notch + wings 矩形 ± 内缩/外扩
- 展开态：`geometry.isPointInOpenedPanel(...)`
- Live edit 模式：强制为 false（`NotchViewModel.swift:252-260`）

### 4.2 `shouldIgnore` 决策表

现有 CombineLatest 订阅（`NotchWindowController.swift:102-118`）的 switch 改为对三种状态统一按 `!insideInteractive`：

| status | mouse inside | ignoresMouseEvents |
|---|---|---|
| opened | true | **false** |
| opened | false | **true** |
| closed | true | **false**（修复） |
| closed | false | **true** |
| popping | true | **false**（修复） |
| popping | false | **true** |

写成代码即：`let shouldIgnore = !insideInteractive`。

### 4.3 数据流（无新增订阅）

```
events.mouseLocation (全局 mouseMoved)
      │
      ▼
NotchViewModel.handleMouseMove
      │ inNotch || inOpened
      ▼
NotchViewModel.isMouseInsideInteractiveArea (@Published)
      │
      ▼
Publishers.CombineLatest ← viewModel.$status
      │
      ▼
NotchWindow.ignoresMouseEvents ← !isMouseInsideInteractiveArea
```

## 5. 代码改动清单

### 5.1 调整

| 文件 | 位置 | 改动 |
|---|---|---|
| `NotchWindowController.swift` | 105-112 | `shouldIgnore` 的 switch 移除，统一为 `!insideInteractive`；注释更新说明三态同构 |

### 5.2 保持不变

- `NotchViewModel.handleMouseMove`：几何判定与 `isMouseInsideInteractiveArea` 写入逻辑已到位
- `NotchViewModel.handleMouseDown` closed 分支：通过 `isPointInNotch` 触发 `notchOpen(.click)`，展开链路复用
- `NotchViewController.PassThroughHostingView.hitTest`：closed 态顶部 44pt `return self` 保留——当 `ignoresMouseEvents=false` 时，该区域吞事件交给本窗口处理
- `EventMonitor` global + local 监听
- 初始化默认 `notchWindow.ignoresMouseEvents = true`（安全默认）

## 6. 边界情况

1. **点击同时触发 `notchOpen`**
   `ignoresMouseEvents=false` 时事件被 NotchPanel 接收 → local monitor 触发 `handleMouseDown` → closed 分支 `isPointInNotch=true` → `notchOpen(.click)`。state 变 opened 后 CombineLatest 继续输出 `shouldIgnore = !true = false`，无抖动。

2. **Global monitor 与 local monitor 重复触发**
   `EventMonitors.mouseDown` 的 handler 由 `addGlobalMonitorForEvents` 和 `addLocalMonitorForEvents` 同一回调实现（`EventMonitor.swift:27-35`）。改为 `ignoresMouseEvents=false` 后：
   - 点击 notch 内：local 触发；global 不触发（事件未到其他 App）
   - 点击外：global 触发；local 不触发
   两路互斥，`handleMouseDown` 不会被重复调用。

3. **hitTest 覆盖范围 vs. `isPointInNotch` 范围**
   `hitTest` 顶部 44pt × 全屏宽度 `return self`，大于 `isPointInNotch` 的 460pt × 37pt 带。但只有在鼠标位于 `isPointInNotch` 区域时窗口才 `ignoresMouseEvents=false`，hitTest 只会在该区域被调用——不会拦截到中央 460pt 之外的菜单栏点击。

4. **Live edit 模式**
   `handleMouseMove` 提前 return 并把 `isMouseInsideInteractiveArea` 置 false（`NotchViewModel.swift:252-260`），无论 status 如何都 `ignoresMouseEvents=true`，维持现状。

5. **副屏**
   `NSEvent.mouseLocation` 是全局坐标；notch/panel 几何只覆盖主屏 notch，副屏上两个判定恒 false → `isMouseInsideInteractiveArea=false` → 穿透，正确。

6. **Hover 自动展开**
   鼠标进入 notch：`isMouseInsideInteractiveArea=true` → `ignoresMouseEvents=false`（此时仍 closed）。1s hover timer 到期后 `notchOpen(.hover)` 将 status 切 opened，CombineLatest 输出 `shouldIgnore` 仍为 false（因为鼠标仍在内）——过渡期不再出现事件穿透。

7. **首帧时序**
   去 throttle 后 mouseMoved 由 AppKit 合并至 ≤60Hz（`NotchViewModel.swift:204-212` 注释）。极端快速飞入 + 立即点击的首次事件仍可能在 `insideInteractive` 尚未更新时被穿透一次。现有设计在展开态已接受这个风险；折叠态的首次点击即便穿透一次，后果与展开态一致：一次桌面误触。

## 7. 验证计划

`ClaudeIslandTests/` 未 wire up，依赖手动验证。构建 Intel Release → 替换 `/Applications/Code Island.app` → 重启应用后按表逐项验证：

| # | 场景 | 预期 |
|---|---|---|
| 1 | 启用"点按墙纸以显示桌面" + 桌面可见时点击 notch | notch 展开；所有窗口保留原状 |
| 2 | 折叠态点击 wings 区域 | notch 展开；下层不触发 |
| 3 | 折叠态点击菜单栏（时间/输入法/状态栏图标） | 菜单栏响应（回归） |
| 4 | 折叠态点击 Finder 桌面非 notch 区域 | 桌面响应；notch 保持折叠（回归） |
| 5 | 展开态点面板内按钮 | 按钮响应（回归） |
| 6 | 展开态点面板外 | 面板关闭 + 下层响应（回归） |
| 7 | 折叠态 hover 进 notch → 1s | 自动展开（回归） |
| 8 | 副屏点击 | 不受影响（回归） |
| 9 | Live edit 模式下点面板外 | 无异常（回归） |
| 10 | 鼠标快速飞入 notch 立即点击 | 多数情况下不穿透；偶发首次穿透可接受 |

## 8. 性能

新方案没有新增订阅或新增计算；`handleMouseMove` 的 AppKit 合并频率 ≤60Hz 不变，单事件开销（两次矩形 `contains` + 条件写入 `ignoresMouseEvents`）不变。

## 9. 回滚策略

单文件单处改动，`git revert` 单笔 commit 即可回到修复前状态。无数据迁移或配置兼容问题。
