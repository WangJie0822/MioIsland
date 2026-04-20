//
//  NotchViewController.swift
//  ClaudeIsland
//
//  Hosts the SwiftUI NotchView in AppKit with click-through support
//

import AppKit
import SwiftUI

/// Custom NSHostingView that passes through clicks on transparent/empty areas.
///
/// opened 态下的护栏：NotchWindowController 会通过 `openedPanelSize` /
/// `openedPanelHorizontalOffset` 注入当前可见面板的尺寸和偏移，我们在 hitTest
/// 里直接判定点击点是否落在面板矩形内——不在就返回 nil，事件穿透到下层 App。
/// 这样即使 Combine 链路驱动的 `ignoresMouseEvents` 还没切到 true（异步时序
/// 慢于用户点击），hitTest 层仍能保证面板外点击不被 NSHostingView 拦截。
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var isOpened: () -> Bool = { false }
    var openedPanelSize: () -> CGSize = { .zero }
    var openedPanelHorizontalOffset: () -> CGFloat = { 0 }

    deinit {
        isOpened = { false }
        openedPanelSize = { .zero }
        openedPanelHorizontalOffset = { 0 }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isOpened() {
            // 计算当前面板在 hostingView 坐标系下的矩形。
            // PassThroughHostingView 填满 750pt 高度的 NotchPanel contentView，
            // NSView 默认 bottom-left 原点，面板视觉上贴屏幕顶部 → 矩形位于 bounds.maxY 处。
            let size = openedPanelSize()
            if size.width > 0, size.height > 0 {
                let panelX = (bounds.width - size.width) / 2 + openedPanelHorizontalOffset()
                let panelY = bounds.height - size.height
                // 向外扩 8px 容忍阴影边缘点击
                let panelRect = CGRect(x: panelX, y: panelY, width: size.width, height: size.height)
                    .insetBy(dx: -8, dy: -8)
                if !panelRect.contains(point) {
                    // 面板外点击 → return nil，事件穿透到下层窗口
                    return nil
                }
            }
            return super.hitTest(point)
        }
        // When closed, accept clicks in the top band (notch height)
        // so the left/right wings are clickable even on transparent areas
        // NotchViewModel.handleMouseDown does the precise geometry check
        if point.y >= bounds.height - 44 {
            return self
        }
        return nil
    }
}

class NotchViewController: NSViewController {
    private let viewModel: NotchViewModel
    private var hostingView: PassThroughHostingView<NotchView>!

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // NotchView reads NotchCustomizationStore.shared directly via
        // an @ObservedObject on the singleton (see NotchView.swift).
        // Because the store is a MainActor singleton, there is no need
        // to cross an @EnvironmentObject boundary here — direct
        // observation avoids the generic type mismatch that
        // `environmentObject(_:)` would introduce into the
        // strictly-typed PassThroughHostingView<NotchView>.
        hostingView = PassThroughHostingView(rootView: NotchView(viewModel: viewModel))

        hostingView.isOpened = { [weak self] in
            self?.viewModel.status == .opened
        }

        // 注入 opened 面板几何：NotchView 渲染时会把内容框限制在 openedSize 内，
        // 并按 NotchHardwareDetector.clampedHorizontalOffset 偏移；hitTest 需要
        // 同样的几何才能准确判定"面板外"。
        hostingView.openedPanelSize = { [weak self] in
            self?.viewModel.openedSize ?? .zero
        }
        hostingView.openedPanelHorizontalOffset = { [weak self] in
            guard let self = self else { return 0 }
            let size = self.viewModel.openedSize
            return NotchHardwareDetector.clampedHorizontalOffset(
                storedOffset: NotchCustomizationStore.shared.customization.horizontalOffset,
                runtimeWidth: size.width,
                screenWidth: self.viewModel.screenRect.width
            )
        }

        self.view = hostingView
    }
}
