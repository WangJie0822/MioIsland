//
//  NotchViewModel.swift
//  ClaudeIsland
//
//  State management for the dynamic island
//

import AppKit
import Combine
import SwiftUI

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason {
    case click
    case hover
    case notification
    case boot
    case unknown
}

enum NotchContentType: Equatable {
    case instances
    case menu
    case chat(SessionState)

    var id: String {
        switch self {
        case .instances: return "instances"
        case .menu: return "menu"
        case .chat(let session): return "chat-\(session.sessionId)"
        }
    }
}

@MainActor
class NotchViewModel: ObservableObject {
    // MARK: - Published State

    @Published var status: NotchStatus = .closed
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .instances
    @Published var isHovering: Bool = false

    /// 鼠标当前是否位于窗口应接收事件的区域：
    /// - opened 态：位于面板矩形内（含 notch 本体）
    /// - closed / popping 态：位于 notch 本体或 wings 区域
    /// NotchWindowController 订阅该信号与 $status 合并驱动 notchWindow.ignoresMouseEvents，
    /// 实现展开态下面板外点击/滚轮/右键/拖拽直接穿透到下层 App。
    @Published var isMouseInsideInteractiveArea: Bool = false

    /// Session counts for dynamic panel sizing
    @Published var sessionCount: Int = 0
    @Published var activeSessionCount: Int = 0
    @Published var isInstancesExpanded: Bool = false

    // MARK: - Dependencies

    private let screenSelector = ScreenSelector.shared
    private let soundSelector = SoundSelector.shared

    // MARK: - Geometry

    let geometry: NotchGeometry
    let spacing: CGFloat = 12
    let hasPhysicalNotch: Bool

    /// Current expansion width from NotchView (synced for hit testing)
    @Published var currentExpansionWidth: CGFloat = 240

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }

    /// Height contributed by the DailyReportCard inside the notch menu.
    /// DailyReportCard writes this when it hides, shows, or expands — so
    /// the notch menu can size itself naturally instead of being stuck at
    /// a fixed 440px with a big empty strip underneath.
    @Published var dailyReportState: DailyReportState = .hidden

    /// Discrete height buckets for the daily report card. Hard-coded
    /// instead of measured via GeometryReader / PreferenceKey to avoid
    /// feedback loops between content size and window size.
    enum DailyReportState: Equatable {
        case hidden       // Card is not shown (no activity or not loaded)
        case loading      // First-launch scan, shows the neon cat
        case collapsed    // Hero line + context line only
        case expandedDay  // Hero + day details (pills + breakdowns)
        case expandedWeek // Hero + week details (sparkline + highlights + ...)

        var height: CGFloat {
            switch self {
            case .hidden:       return 0
            case .loading:      return 80
            case .collapsed:    return 118
            case .expandedDay:  return 230
            case .expandedWeek: return 400
            }
        }
    }

    /// Dynamic opened size based on content type
    var openedSize: CGSize {
        switch contentType {
        case .chat:
            // Chat view: width fixed, height is max (actual height adapts to content)
            return CGSize(
                width: min(screenRect.width * 0.5, 600),
                height: 580
            )
        case .menu:
            // Lean notch menu — now that all the toggles/pickers moved to
            // the floating SystemSettings window, the menu is just:
            //   DailyReportCard + PairPhoneRow + SystemSettingsRow
            // The report card height varies (hidden / loading / collapsed /
            // expanded), so we add its dailyReportState.height onto a small
            // base that covers the header, two rows, and padding.
            let baseHeight: CGFloat = 200
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: baseHeight + dailyReportState.height
            )
        case .instances:
            let baseHeight: CGFloat = 100
            let perSession: CGFloat = 65
            let contentHeight = baseHeight + CGFloat(sessionCount) * perSession
            // ≤4 sessions: fit content + room for buddy; >4: capped unless expanded
            let compactMax: CGFloat = 360
            let expandedMax: CGFloat = min(screenRect.height * 0.65, 600)
            let height: CGFloat
            if sessionCount <= 4 {
                height = min(contentHeight, expandedMax)
            } else {
                height = isInstancesExpanded ? expandedMax : compactMax
            }
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: max(height, 200)
            )
        }
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let events = EventMonitors.shared
    private var hoverTimer: DispatchWorkItem?

    // MARK: - Initialization

    init(deviceNotchRect: CGRect, screenRect: CGRect, windowHeight: CGFloat, hasPhysicalNotch: Bool) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        setupEventHandlers()
        observeSelectors()
    }

    private func observeSelectors() {
        screenSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        soundSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        // 不再 throttle：flag 切换必须紧跟鼠标位置，否则鼠标飞入面板的首次点击会穿透。
        // AppKit 已对 mouseMoved 事件做 ≤60Hz 合并；hover 逻辑靠
        // `guard newHovering != isHovering` 去重，不依赖这里的 throttle。
        events.mouseLocation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)

        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleMouseDown()
            }
            .store(in: &cancellables)
    }

    /// Whether we're in chat mode (sticky behavior)
    private var isInChatMode: Bool {
        if case .chat = contentType { return true }
        return false
    }

    /// The chat session we're viewing (persists across close/open)
    private var currentChatSession: SessionState?

    /// Pull the user's saved horizontal offset, clamped against the
    /// current screen + visible notch width so a value persisted on
    /// a wider external display doesn't push hit-testing off-screen
    /// when the smaller built-in is the active one. Mirrors the same
    /// clamp NotchView applies for `.offset(x:)` rendering.
    private var currentHorizontalOffset: CGFloat {
        let stored = NotchCustomizationStore.shared.customization.horizontalOffset
        let runtime: CGFloat = status == .opened ? openedSize.width : (geometry.deviceNotchRect.width + currentExpansionWidth)
        return NotchHardwareDetector.clampedHorizontalOffset(
            storedOffset: stored,
            runtimeWidth: runtime,
            screenWidth: geometry.screenRect.width
        )
    }

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

        // Cancel any pending hover timer
        hoverTimer?.cancel()
        hoverTimer = nil

        // Start hover timer to auto-expand after 1 second
        if isHovering && (status == .closed || status == .popping) {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isHovering else { return }
                self.notchOpen(reason: .hover)
            }
            hoverTimer = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        }
    }

    private func handleMouseDown() {
        // Same lock-out as mouseMove — clicks on the notch (or anywhere
        // else) should not open the panel while live edit is active.
        // The live edit panel has its own click routing.
        if NotchCustomizationStore.shared.isEditing {
            return
        }
        let location = NSEvent.mouseLocation

        let offset = currentHorizontalOffset
        switch status {
        case .opened:
            // 展开态下 `ignoresMouseEvents` 在鼠标离开面板矩形时已被动态置 true，
            // 面板外的点击事件由下层 App 直接接收，本分支仅负责收起面板。
            if geometry.isPointOutsidePanel(location, size: openedSize, horizontalOffset: offset) {
                notchClose()
            }
        case .closed, .popping:
            if geometry.isPointInNotch(location, expansionWidth: currentExpansionWidth, horizontalOffset: offset) {
                notchOpen(reason: .click)
            }
        }
    }

    // MARK: - Actions

    /// Whether the current open was triggered by user action (should steal focus)
    var shouldActivateOnOpen: Bool = false

    func notchOpen(reason: NotchOpenReason = .unknown) {
        openReason = reason
        // Only steal focus when user explicitly clicked
        shouldActivateOnOpen = (reason == .click)
        status = .opened

        // Don't restore chat on notification - show instances list instead
        if reason == .notification {
            currentChatSession = nil
            return
        }

        // Restore chat session if we had one open before
        if let chatSession = currentChatSession {
            // Avoid unnecessary updates if already showing this chat
            if case .chat(let current) = contentType, current.sessionId == chatSession.sessionId {
                return
            }
            contentType = .chat(chatSession)
        }
    }

    func notchClose() {
        // Save chat session before closing if in chat mode
        if case .chat(let session) = contentType {
            currentChatSession = session
        }
        status = .closed
        contentType = .instances
    }

    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }

    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }

    func toggleMenu() {
        contentType = contentType == .menu ? .instances : .menu
    }

    func showChat(for session: SessionState) {
        // Avoid unnecessary updates if already showing this chat
        if case .chat(let current) = contentType, current.sessionId == session.sessionId {
            return
        }
        contentType = .chat(session)
    }

    /// Go back to instances list and clear saved chat state
    func exitChat() {
        currentChatSession = nil
        contentType = .instances
    }

    /// Perform boot animation: expand briefly then collapse
    func performBootAnimation() {
        notchOpen(reason: .boot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.openReason == .boot else { return }
            self.notchClose()
        }
    }
}
