# Socket Server 自愈机制实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 HookSocketServer 能自动检测并恢复静默死亡的 socket 监听，同时让 hook 脚本在连接失败时输出可见错误。

**Architecture:** 在现有 `HookSocketServer` 中新增定时自检 timer（每 60s 自连接测试），失败时自动 teardown + rebuild socket server。hook 脚本的 `send_event` 异常处理改为输出 stderr 而非静默吞掉。

**Tech Stack:** Swift 5 / GCD DispatchSource / Unix Domain Socket / Python 3

---

## 文件清单

| 操作 | 文件 | 职责 |
|------|------|------|
| Modify | `ClaudeIsland/Services/Hooks/HookSocketServer.swift` | 新增自检 timer、teardown、自愈、healthcheck 过滤 |
| Modify | `ClaudeIsland/Resources/codeisland-state.py` | send_event 异常写 stderr |

---

### Task 1: Healthcheck 事件过滤

**Files:**
- Modify: `ClaudeIsland/Services/Hooks/HookSocketServer.swift:404-415`

在 `handleClient` 中 JSON 解码成功后、任何业务逻辑之前，插入 healthcheck 检查。这是后续自检 timer 的前置条件——timer 发送的 `__healthcheck__` 包必须被过滤掉，不能传递给 `eventHandler`。

- [ ] **Step 1: 在 `handleClient` 中添加 healthcheck 过滤**

在 `HookSocketServer.swift` 的 `handleClient` 方法中，找到 JSON 解码成功后的位置（第 417 行 `logger.debug("Received:...` 之前），插入过滤逻辑：

```swift
        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            logger.warning("Failed to parse event: \(String(data: data, encoding: .utf8) ?? "?", privacy: .public)")
            close(clientSocket)
            return
        }

        // 健康检查事件：直接关闭连接，不传递给业务逻辑
        if event.event == "__healthcheck__" {
            close(clientSocket)
            return
        }

        logger.debug("Received: \(event.event, privacy: .public) for \(event.sessionId.prefix(8), privacy: .public)")
```

即在现有的 `guard let event = ...` 之后、`logger.debug("Received:..."` 之前插入 3 行 healthcheck 过滤。

- [ ] **Step 2: 构建验证**

```bash
cd /Users/wj/Work/OpenSource/CodeIsland
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland \
  -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

预期：`BUILD SUCCEEDED`

- [ ] **Step 3: 提交**

```bash
git add ClaudeIsland/Services/Hooks/HookSocketServer.swift
git commit -m "[feat|Hooks|HookSocketServer][公共]handleClient过滤__healthcheck__事件"
```

---

### Task 2: startServer 支持重启（teardown + rebuild）

**Files:**
- Modify: `ClaudeIsland/Services/Hooks/HookSocketServer.swift:140-202`

现有 `startServer` 在 `serverSocket >= 0` 时直接 return，不支持重启。改为：若已在运行，先执行完整 teardown 再重建。同时新增 `teardownServer()` 私有方法，供自愈流程复用。

- [ ] **Step 1: 新增 `teardownServer` 方法**

在 `HookSocketServer` 的 `// MARK: - Private` 区域之前（`cleanupCache` 方法之后、`acceptConnection` 方法之前），添加：

```swift
    /// 完整清理 socket server 资源（在 queue 上调用）
    private func teardownServer() {
        acceptSource?.cancel()
        acceptSource = nil

        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }

        unlink(Self.socketPath)

        // 关闭所有 pending permission 的 client socket 并通知失败
        permissionsLock.lock()
        let allPending = pendingPermissions
        pendingPermissions.removeAll()
        permissionsLock.unlock()

        for (_, pending) in allPending {
            close(pending.clientSocket)
            permissionFailureHandler?(pending.sessionId, pending.toolUseId)
        }
    }
```

- [ ] **Step 2: 修改 `startServer` 开头的 guard 为 teardown**

将 `startServer` 方法开头的：

```swift
    private func startServer(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler?) {
        guard serverSocket < 0 else { return }

        eventHandler = onEvent
        permissionFailureHandler = onPermissionFailure
```

改为：

```swift
    private func startServer(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler?) {
        // 若已在运行，先完整清理再重建
        if serverSocket >= 0 {
            teardownServer()
        }

        eventHandler = onEvent
        permissionFailureHandler = onPermissionFailure
```

- [ ] **Step 3: 构建验证**

```bash
cd /Users/wj/Work/OpenSource/CodeIsland
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland \
  -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

预期：`BUILD SUCCEEDED`

- [ ] **Step 4: 提交**

```bash
git add ClaudeIsland/Services/Hooks/HookSocketServer.swift
git commit -m "[refactor|Hooks|HookSocketServer][公共]startServer支持重启：teardown+rebuild替代guard"
```

---

### Task 3: 健康检查 Timer 与自愈逻辑

**Files:**
- Modify: `ClaudeIsland/Services/Hooks/HookSocketServer.swift`

新增定时 timer（每 60s）执行自连接测试，失败时调用 `startServer` 重建。

- [ ] **Step 1: 新增实例变量**

在 `HookSocketServer` 的现有实例变量区（`private let permissionsLock = NSLock()` 之后），添加：

```swift
    /// 定时健康检查
    private var healthCheckTimer: DispatchSourceTimer?
    private static let healthCheckInterval: TimeInterval = 60

    /// 累计重启次数
    private var restartCount = 0
```

- [ ] **Step 2: 新增 `startHealthCheck` 方法**

在 `teardownServer()` 方法之后添加：

```swift
    /// 启动定时健康检查（在 queue 上调用）
    private func startHealthCheck() {
        healthCheckTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.healthCheckInterval,
            repeating: Self.healthCheckInterval
        )
        timer.setEventHandler { [weak self] in
            self?.performHealthCheck()
        }
        timer.resume()
        healthCheckTimer = timer
    }
```

- [ ] **Step 3: 新增 `performHealthCheck` 方法**

紧接 `startHealthCheck` 之后添加：

```swift
    /// 自连接测试：尝试连接自己的 socket，失败则重建
    private func performHealthCheck() {
        let testSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard testSocket >= 0 else {
            DebugLogger.log("Socket", "Health check: failed to create test socket")
            restartServer()
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(testSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult == 0 {
            // 连接成功，发送 healthcheck 包让 handleClient 过滤掉
            let payload = "{\"event\":\"__healthcheck__\",\"session_id\":\"_hc\",\"cwd\":\"\",\"status\":\"ok\"}"
            _ = payload.withCString { ptr in
                write(testSocket, ptr, strlen(ptr))
            }
            close(testSocket)
            // 健康，不记录日志（避免噪音）
        } else {
            close(testSocket)
            DebugLogger.log("Socket", "Health check failed (errno=\(errno)), restarting server")
            restartServer()
        }
    }
```

- [ ] **Step 4: 新增 `restartServer` 方法**

紧接 `performHealthCheck` 之后添加：

```swift
    /// 重建 socket server
    private func restartServer() {
        guard let onEvent = eventHandler else {
            DebugLogger.log("Socket", "Server restart failed: no event handler")
            return
        }
        let onFailure = permissionFailureHandler

        startServer(onEvent: onEvent, onPermissionFailure: onFailure)

        if serverSocket >= 0 {
            restartCount += 1
            DebugLogger.log("Socket", "Server restarted successfully (restart #\(restartCount))")
        } else {
            DebugLogger.log("Socket", "Server restart failed: startServer did not bind")
            if restartCount >= 3 {
                logger.error("Socket server restart failed after \(self.restartCount) previous restarts")
            }
        }
    }
```

- [ ] **Step 5: 在 `startServer` 末尾启动 timer**

在 `startServer` 方法末尾的 `acceptSource?.resume()` 之后添加启动 timer 和日志：

```swift
        acceptSource?.resume()

        DebugLogger.log("Socket", "Server started, listening on \(Self.socketPath)")
        startHealthCheck()
    }
```

- [ ] **Step 6: 在 `stop` 方法中取消 timer**

在 `stop()` 方法开头添加 timer 取消：

```swift
    func stop() {
        healthCheckTimer?.cancel()
        healthCheckTimer = nil

        acceptSource?.cancel()
```

- [ ] **Step 7: 构建验证**

```bash
cd /Users/wj/Work/OpenSource/CodeIsland
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland \
  -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

预期：`BUILD SUCCEEDED`

- [ ] **Step 8: 提交**

```bash
git add ClaudeIsland/Services/Hooks/HookSocketServer.swift
git commit -m "[feat|Hooks|HookSocketServer][公共]定时健康检查与socket自愈机制"
```

---

### Task 4: Hook 脚本错误可观测性

**Files:**
- Modify: `ClaudeIsland/Resources/codeisland-state.py:109-128`

修改 `send_event` 的异常处理，区分错误类型并输出到 stderr。

- [ ] **Step 1: 修改 `send_event` 异常处理**

将 `codeisland-state.py` 中 `send_event` 函数的 except 块：

```python
    except (socket.error, OSError, json.JSONDecodeError):
        return None
```

改为：

```python
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
```

- [ ] **Step 2: 语法验证**

```bash
python3 -c "import py_compile; py_compile.compile('/Users/wj/Work/OpenSource/CodeIsland/ClaudeIsland/Resources/codeisland-state.py', doraise=True)"
```

预期：无输出（编译成功）

- [ ] **Step 3: 模拟连接失败验证 stderr 输出**

先确保没有 Code Island 在监听（如果当前 socket 可用则跳过此步），然后：

```bash
echo '{"hook_event_name":"SessionStart","session_id":"test","cwd":"/tmp"}' | python3 /Users/wj/Work/OpenSource/CodeIsland/ClaudeIsland/Resources/codeisland-state.py 2>&1 >/dev/null
```

预期 stderr 输出包含 `[codeisland-hook]` 和错误描述。

- [ ] **Step 4: 提交**

```bash
git add ClaudeIsland/Resources/codeisland-state.py
git commit -m "[fix|Hooks|codeisland-state.py][公共]socket连接失败时输出stderr而非静默吞掉"
```

---

### Task 5: 端到端验证

验证完整自愈流程：正常运行 → 模拟故障 → 自动恢复。

- [ ] **Step 1: 构建并启动应用**

```bash
cd /Users/wj/Work/OpenSource/CodeIsland
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland \
  -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

启动应用后，确认日志中出现启动记录：

```bash
grep "\[Socket\]" ~/.claude/.codeisland.log | tail -5
```

预期：`[Socket] Server started, listening on /tmp/codeisland.sock`

- [ ] **Step 2: 验证正常 socket 连接**

```bash
python3 -c "
import socket, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('/tmp/codeisland.sock')
s.sendall(json.dumps({'event':'__healthcheck__','session_id':'_hc','cwd':'','status':'ok'}).encode())
s.close()
print('OK')
"
```

预期：输出 `OK`，日志中不出现 healthcheck 相关条目（被过滤）。

- [ ] **Step 3: 验证健康检查定时运行**

等待 60+ 秒后确认无异常日志（健康时不记录）：

```bash
grep "\[Socket\] Health check" ~/.claude/.codeisland.log
```

预期：无输出（健康检查通过时不写日志）。

- [ ] **Step 4: 验证 hook 脚本 stderr 输出**

用一个不存在的 socket 路径测试（临时修改脚本或直接测试现有行为）：

```bash
# 确认当前 socket 可用时不输出 stderr
echo '{"hook_event_name":"Stop","session_id":"test","cwd":"/tmp"}' | python3 ~/.claude/hooks/codeisland-state.py 2>&1 >/dev/null | head -1
```

预期：无 stderr 输出（连接成功）。

- [ ] **Step 5: 确认已有会话未受影响**

打开一个新的 Claude Code 终端会话，确认 Code Island 能检测到：

```bash
tail -f ~/.claude/.codeisland.log | grep "new=true"
```

预期：出现 `[Hook] SessionStart ... new=true` 日志。
