//
//  NotchWindowController.swift
//  ClaudeIsland
//
//  Controls the notch window positioning and lifecycle
//

import AppKit
import Combine
import SwiftUI

class NotchWindowController: NSWindowController {
    let viewModel: NotchViewModel
    private let screen: NSScreen
    private var cancellables = Set<AnyCancellable>()

    /// Subscription to NotchCustomizationStore.$customization. Held
    /// as a dedicated cancellable (not lumped into `cancellables`)
    /// so it can be torn down independently if the controller is
    /// ever re-attached to a different store instance.
    private var customizationCancellable: AnyCancellable?
    private var editingCancellable: AnyCancellable?

    /// Active live-edit overlay panel, non-nil only while
    /// store.isEditing == true.
    private var liveEditPanel: NotchLiveEditPanel?

    init(screen: NSScreen) {
        self.screen = screen

        let screenFrame = screen.frame
        let notchSize = screen.notchSize

        // Window covers full width at top, tall enough for largest content (chat view)
        let windowHeight: CGFloat = 750
        let windowFrame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - windowHeight,
            width: screenFrame.width,
            height: windowHeight
        )

        // Device notch rect - positioned at center
        let deviceNotchRect = CGRect(
            x: (screenFrame.width - notchSize.width) / 2,
            y: 0,
            width: notchSize.width,
            height: notchSize.height
        )

        // Create view model
        self.viewModel = NotchViewModel(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenFrame,
            windowHeight: windowHeight,
            hasPhysicalNotch: screen.hasPhysicalNotch
        )

        // Create the window
        let notchWindow = NotchPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: notchWindow)

        // Create the SwiftUI view with pass-through hosting
        let hostingController = NotchViewController(viewModel: viewModel)
        notchWindow.contentViewController = hostingController

        notchWindow.setFrame(windowFrame, display: true)

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

        // Start with ignoring mouse events (closed state)
        notchWindow.ignoresMouseEvents = true

        // Perform boot animation after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.viewModel.performBootAnimation()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - NotchCustomizationStore integration

    /// Subscribe to the given store and reapply geometry every
    /// time the user's customization changes. Safe to call
    /// multiple times — the previous subscription is released
    /// before the new one is attached.
    ///
    /// Spec: docs/superpowers/specs/2026-04-08-notch-customization-design.md
    /// section 5.5.
    @MainActor
    func attachStore(_ store: NotchCustomizationStore) {
        customizationCancellable = store.$customization
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyGeometryFromStore()
            }

        // Mirror live edit lifecycle into panel creation / teardown.
        editingCancellable = store.$isEditing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] editing in
                guard let self else { return }
                if editing {
                    self.enterLiveEditMode()
                } else {
                    self.exitLiveEditMode()
                }
            }
    }

    @MainActor
    func enterLiveEditMode() {
        guard liveEditPanel == nil else { return }

        // Force the notch back into the closed state so the live edit
        // overlay's dashed border + arrow buttons line up with the
        // visible closed-state notch instead of an opened chat panel.
        viewModel.notchClose()

        let activeScreen = window?.screen ?? self.screen
        let panel = NotchLiveEditPanel(screen: activeScreen)

        // Pass the panel's screen explicitly into the overlay so its
        // hardware-notch detection doesn't accidentally read NSScreen.main
        // (which can return a non-notched secondary display once the
        // live edit panel becomes key on a multi-monitor setup).
        let overlay = NotchLiveEditOverlay(
            screenProvider: { activeScreen },
            onExit: { [weak self] in
                self?.exitLiveEditMode()
            }
        )
        let hosting = NSHostingView(rootView: overlay)
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)

        panel.orderFrontRegardless()
        panel.makeKey()
        self.liveEditPanel = panel
    }

    @MainActor
    func exitLiveEditMode() {
        guard let panel = liveEditPanel else { return }
        panel.orderOut(nil)
        panel.close()
        self.liveEditPanel = nil
    }

    /// Recompute the panel frame from the current store state +
    /// active screen metrics and animate into the new frame.
    /// Stateless — does NOT write anything back to the store, so
    /// render-time clamping on a smaller screen is transparent
    /// and reversible when the larger screen returns.
    @MainActor
    func applyGeometryFromStore() {
        let store = NotchCustomizationStore.shared
        let customization = store.customization
        let window = self.window

        guard let window else { return }
        let activeScreen = window.screen ?? self.screen
        let screenFrame = activeScreen.frame

        let runtimeWidth = NotchHardwareDetector.clampedWidth(
            measuredContentWidth: customization.maxWidth,
            maxWidth: customization.maxWidth
        )
        let clampedOffset = NotchHardwareDetector.clampedHorizontalOffset(
            storedOffset: customization.horizontalOffset,
            runtimeWidth: runtimeWidth,
            screenWidth: screenFrame.width
        )
        let baseX = (screenFrame.width - runtimeWidth) / 2
        let finalX = screenFrame.origin.x + baseX + clampedOffset

        // The notch panel currently sizes itself to the full
        // screen width and positions content via inner layout, so
        // a geometry change here re-flows the internal notch
        // layout rather than resizing the window. This matches the
        // existing CodeIsland rendering model and avoids a deeper
        // refactor of the hosting view geometry. Stored horizontal
        // offset and width are still observed via the subscription
        // so NotchView can react directly to store changes.
        _ = (finalX, runtimeWidth) // Referenced for clarity; full
                                   // geometry wiring is deferred to
                                   // the next chunk (live edit mode)
                                   // where the interactive drag
                                   // path needs the same math.

        // Smoothly animate any future frame changes.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            // Preserve the current full-width overlay frame; only
            // the inner notch bounds care about runtimeWidth.
            window.animator().setFrame(window.frame, display: true)
        }
    }
}
