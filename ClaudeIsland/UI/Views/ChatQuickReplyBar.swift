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
