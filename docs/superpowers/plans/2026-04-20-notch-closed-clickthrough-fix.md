# Notch 折叠态点击穿透到桌面修复 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复折叠态（closed/popping）下点击 notch/wings 时事件同时穿透到桌面，触发 macOS "点按墙纸以显示桌面"暴露桌面的问题。

**Architecture:** 复用 `NotchViewModel.isMouseInsideInteractiveArea` 现有信号。`NotchWindowController` 的 CombineLatest 订阅不再对 closed/popping 态硬编码 `true`，而是与 opened 态一样按 `!insideInteractive` 输出。鼠标进入 notch+wings 几何范围时窗口接收事件（不穿透），离开时穿透。

**Tech Stack:** Swift 5, SwiftUI, AppKit, Combine。仓库不含 wired-up test target，以 `xcodebuild build` + 手动验证为质量门槛。

**Spec:** `docs/superpowers/specs/2026-04-20-notch-closed-clickthrough-fix-design.md`

---

## 文件结构

| 操作 | 文件 | 责任 |
|---|---|---|
| 修改 | `ClaudeIsland/UI/Window/NotchWindowController.swift` | `shouldIgnore` 的 switch 改为 `!insideInteractive`；注释同步更新 |

---

## Task 1：NotchWindowController 改动

**Files:**
- Modify: `ClaudeIsland/UI/Window/NotchWindowController.swift`

### Step 1.1 统一 shouldIgnore 为 `!insideInteractive`

- [ ] **Edit** — 移除 closed/popping 分支的硬编码 `true`

**Old string**:
```swift
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

**New string**:
```swift
        // 动态 ignoresMouseEvents：鼠标在交互区域（notch+wings 或展开面板内）
        // 时窗口接收事件，否则事件（左键/右键/滚轮/拖拽）穿透到下层 App。
        // 折叠态下也按此信号切换：若恒 true，点击 notch 会同时穿到桌面触发
        // macOS "点按墙纸以显示桌面"隐藏所有窗口；global mouseDown monitor
        // 是只读旁听无法阻断，只能靠窗口层独占事件。Live edit 模式下
        // `isMouseInsideInteractiveArea` 被强制为 false，自然维持穿透。
        Publishers.CombineLatest(viewModel.$status, viewModel.$isMouseInsideInteractiveArea)
            .receive(on: DispatchQueue.main)
            .sink { [weak notchWindow] _, insideInteractive in
                let shouldIgnore = !insideInteractive
                guard let window = notchWindow else { return }
                if window.ignoresMouseEvents != shouldIgnore {
                    window.ignoresMouseEvents = shouldIgnore
                }
            }
            .store(in: &cancellables)
```

**Notes:**
- `status` 参数改为 `_` 占位：CombineLatest 仍需订阅 `$status` 以便状态变化时立即重算（例如 opened→closed 时若鼠标正好在面板内，insideInteractive 值不变但 notch 几何变了；`handleMouseMove` 后续会把信号刷新到准确值）
- 属性名 `isMouseInsideInteractiveArea` 与 `NotchViewModel.swift:54` 一致，无需新增
- Combine 已在 `NotchWindowController.swift:9` import

---

## Task 2：编译验证

**Files:** 无

### Step 2.1 Debug 构建

- [ ] **Bash**

```bash
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland \
    -configuration Debug -destination 'platform=macOS' \
    build 2>&1 | tail -40
```

**Expected:** 末尾 `** BUILD SUCCEEDED **`。

---

## Task 3：Intel 架构 Release 构建

**Files:** 无（产物落在 `build/intel/`）

### Step 3.1 Archive 强制 `ARCHS=x86_64`

- [ ] **Bash**

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

**Expected:** `ARCHIVE SUCCEEDED`；`build/intel/ClaudeIsland.xcarchive/Products/Applications/Code Island.app` 存在。

### Step 3.2 Export .app

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

### Step 3.3 校验 x86_64 架构

- [ ] **Bash**

```bash
APP="build/intel/export/Code Island.app/Contents/MacOS/Code Island"
file "$APP"
lipo -info "$APP"
```

**Expected:**
- `file` 含 `Mach-O 64-bit executable x86_64`
- `lipo -info` 含 `architecture: x86_64`（non-fat 或只列 x86_64）

---

## Task 4：安装到 /Applications

**Files:** 无

### Step 4.1 关闭旧进程 + 替换

- [ ] **Bash** — Rosetta 运行需先关闭旧实例避免 "in use" 错误

```bash
osascript -e 'tell application "Code Island" to quit' 2>/dev/null || true
sleep 1
pkill -x "Code Island" 2>/dev/null || true
sleep 1
rm -rf "/Applications/Code Island.app"
cp -R "build/intel/export/Code Island.app" "/Applications/Code Island.app"
codesign -vv "/Applications/Code Island.app" 2>&1 | tail -5
```

**Expected:** 替换成功；`codesign -vv` 不报 `invalid signature`。

### Step 4.2 启动新版本

- [ ] **Bash** — Rosetta 2 若未安装，系统会提示安装后自动重试

```bash
open "/Applications/Code Island.app"
sleep 3
pgrep -f "Code Island" | head -3
```

**Expected:** `pgrep` 输出非空（新进程已运行）。

---

## Task 5：原子化提交

**Files:** 无

### Step 5.1 Docs 提交

- [ ] **Bash**

```bash
git add docs/superpowers/specs/2026-04-20-notch-closed-clickthrough-fix-design.md \
        docs/superpowers/plans/2026-04-20-notch-closed-clickthrough-fix.md
git commit -m "[docs|UI|NotchWindow][公共]折叠态点击穿透到桌面修复设计与实施计划"
```

### Step 5.2 Fix 提交

- [ ] **Bash**

```bash
git add ClaudeIsland/UI/Window/NotchWindowController.swift
git commit -m "[fix|UI|NotchWindow][公共]折叠态动态 ignoresMouseEvents，避免点击穿透到桌面"
```

---

## Task 6：手动验证清单（用户重启后执行）

按 spec §7 表格核心 4 项最低要求：

- [ ] 启用"点按墙纸以显示桌面" + 桌面可见时点击 notch → notch 展开且所有窗口保留
- [ ] 折叠态点击菜单栏图标 → 菜单栏响应（回归）
- [ ] 折叠态 hover 1s → 自动展开（回归）
- [ ] 展开态点击面板外 → 面板关闭 + 下层响应（回归）

若核心 4 项通过则修复确认；任一失败按 spec §6 边界情况排查。

---

## 自审结论（plan 对 spec 的覆盖）

| Spec 要求 | 对应 Task |
|---|---|
| §3 决策：closed/popping 也接入动态信号 | Task 1.1 |
| §4.2 shouldIgnore 决策表 | Task 1.1 |
| §5.1 调整清单（单文件单处） | Task 1.1 |
| §5.2 保持不变项 | 未触及（ViewModel、hitTest、EventMonitor 均无改动） |
| §7 验证计划 | Task 2（编译）+ Task 3/4（构建安装）+ Task 6（手动清单） |

**无占位符**；每个 Step 均含精确 old/new 代码或可执行命令。
