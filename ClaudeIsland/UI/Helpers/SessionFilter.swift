//
//  SessionFilter.swift
//  ClaudeIsland
//
//  Extracted filtering logic for session display list.
//  Separated for testability.
//

import Foundation

enum SessionFilter {
    /// 过滤交互式会话用于主列表：排除后台会话，隐藏短命 ended 会话噪音
    static func filterForDisplay(_ sessions: [SessionState]) -> [SessionState] {
        sessions.filter { session in
            // 后台会话不在主列表展示
            if session.isBackground { return false }
            if session.phase == .ended {
                let duration = Date().timeIntervalSince(session.createdAt)
                return duration >= 30
            }
            return true
        }
    }

    /// 后台会话列表（claude -p 等无 TTY 进程）
    static func backgroundSessions(_ sessions: [SessionState]) -> [SessionState] {
        sessions.filter { $0.isBackground }
    }
}
