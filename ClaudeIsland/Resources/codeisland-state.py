#!/usr/bin/env python3
"""
Code Island Hook
- Sends session state to CodeIsland.app via Unix socket
- For PermissionRequest: waits for user decision from the app
"""
import json
import os
import socket
import sys

SOCKET_PATH = "/tmp/codeisland.sock"
TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions


def get_tty():
    """Get the TTY of the Claude process (parent)"""
    import subprocess

    # Get parent PID (Claude process)
    ppid = os.getppid()

    # Try to get TTY from ps command for the parent process
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2
        )
        tty = result.stdout.strip()
        if tty and tty != "??" and tty != "-":
            # ps returns just "ttys001", we need "/dev/ttys001"
            if not tty.startswith("/dev/"):
                tty = "/dev/" + tty
            return tty
    except Exception:
        pass

    # Fallback: try current process stdin/stdout
    try:
        return os.ttyname(sys.stdin.fileno())
    except (OSError, AttributeError):
        pass
    try:
        return os.ttyname(sys.stdout.fileno())
    except (OSError, AttributeError):
        pass
    return None


def probe_ghostty_terminal_id(tty):
    """在 SessionStart 时通过 title-probe 探测 Ghostty terminal UUID。

    原理：hook 脚本的 stdout 被 Claude Code 管道捕获，但可以直接写入
    tty 设备路径设置终端标题，然后通过 AppleScript 按标题定位 terminal
    并取得其唯一 ID。

    仅在 TERM_PROGRAM == "ghostty" 且 tty 可用时执行。
    """
    import subprocess
    import uuid
    import time

    # 仅 Ghostty 终端执行
    if os.environ.get("TERM_PROGRAM") != "ghostty":
        return None
    if not tty:
        return None

    nonce = uuid.uuid4().hex[:8]

    # 写 OSC 2 到 tty 设备（绕过被管道捕获的 stdout）
    try:
        with open(tty, 'w') as f:
            f.write(f'\033]2;ci-probe-{nonce}\007')
            f.flush()
    except OSError:
        return None

    # 等 Ghostty 处理转义序列
    time.sleep(0.05)

    # 查询 Ghostty 找到带 nonce 标题的 terminal
    terminal_id = None
    try:
        result = subprocess.run(
            ['osascript', '-e',
             f'tell application "Ghostty" to id of first terminal '
             f'whose name contains "ci-probe-{nonce}"'],
            capture_output=True, text=True, timeout=2
        )
        if result.returncode == 0 and result.stdout.strip():
            terminal_id = result.stdout.strip()
    except Exception:
        pass

    # 恢复标题（重置为空，shell/Claude Code 会在下次 prompt 时恢复）
    try:
        with open(tty, 'w') as f:
            f.write('\033]2;\007')
            f.flush()
    except OSError:
        pass

    return terminal_id


def send_event(state):
    """Send event to app, return response if any"""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())

        # For permission requests, wait for response
        if state.get("status") == "waiting_for_approval":
            response = sock.recv(4096)
            sock.close()
            if response:
                return json.loads(response.decode())
        else:
            sock.close()

        return None
    except (socket.error, OSError) as e:
        if isinstance(e, ConnectionRefusedError):
            msg = "socket server not responding"
        elif isinstance(e, FileNotFoundError):
            msg = "Code Island not running"
        else:
            msg = str(e)
        print(f"[codeisland-hook] {msg}", file=sys.stderr)
        return None
    except json.JSONDecodeError:
        return None


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")
    tool_input = data.get("tool_input", {})

    # Get process info
    claude_pid = os.getppid()
    tty = get_tty()

    # Build state object
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": claude_pid,
        "tty": tty,
    }

    # Map events to status
    if event == "UserPromptSubmit":
        # User just sent a message - Claude is now processing
        state["status"] = "processing"

    elif event == "PreToolUse":
        state["status"] = "running_tool"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id to Swift for caching
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id so Swift can cancel the specific pending permission
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PermissionRequest":
        # This is where we can control the permission
        state["status"] = "waiting_for_approval"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # tool_use_id lookup handled by Swift-side cache from PreToolUse

        # Send to app and wait for decision
        response = send_event(state)

        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")

            if decision == "allow":
                # Output JSON to approve
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow"},
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "deny":
                # Output JSON to deny
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via CodeIsland",
                        },
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

        # No response or "ask" - let Claude Code show its normal UI
        sys.exit(0)

    elif event == "Notification":
        notification_type = data.get("notification_type")
        # Skip permission_prompt - PermissionRequest hook handles this with better info
        if notification_type == "permission_prompt":
            sys.exit(0)
        elif notification_type == "idle_prompt":
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"
        state["notification_type"] = notification_type
        state["message"] = data.get("message")

    elif event == "Stop":
        state["status"] = "waiting_for_input"

    elif event == "SubagentStop":
        # SubagentStop fires when a subagent completes - usually means back to waiting
        state["status"] = "waiting_for_input"

    elif event == "SessionStart":
        # New session starts waiting for user input
        state["status"] = "waiting_for_input"
        # 探测 Ghostty terminal ID（仅 Ghostty + 有 tty 时执行）
        ghostty_id = probe_ghostty_terminal_id(tty)
        if ghostty_id:
            state["ghostty_terminal_id"] = ghostty_id

    elif event == "SessionEnd":
        state["status"] = "ended"

    elif event == "PreCompact":
        # Context is being compacted (manual or auto)
        state["status"] = "compacting"

    else:
        state["status"] = "unknown"

    # Send to socket (fire and forget for non-permission events)
    send_event(state)


if __name__ == "__main__":
    main()
