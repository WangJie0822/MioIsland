# Socket Server 自愈机制设计

> 日期: 2026-04-16
> 状态: approved
> 影响文件: `HookSocketServer.swift`, `codeisland-state.py`

## 问题

`HookSocketServer` 的 `DispatchSourceRead` 在长时间运行后可能静默停止接受连接。Socket 文件仍然存在（进程持有 FD），但 `accept()` 不再被调用。同时 hook 脚本捕获所有 socket 异常后静默返回 `None`（exit 0），导致问题完全不可见——新的 Claude Code 会话无法被 Code Island 发现。

### 诊断证据

- Code Island 进程运行 ~3 小时后，socket server 停止接受连接
- `python3 -c "sock.connect('/tmp/codeisland.sock')"` → `Connection refused`
- `lsof /tmp/codeisland.sock` 显示 Code Island 仍持有 FD
- DebugLogger 仅有 RateLimit 定时条目，无 hook 事件
- 无崩溃日志、无 os.log 错误

## 方案：Socket Server 自检自愈 + Hook 脚本可观测性

### 模块 1：Socket Server 自检与自愈（HookSocketServer.swift）

#### 定时自检

- 新增 `DispatchSourceTimer`，每 **60 秒**触发一次
- 自检逻辑：创建临时 Unix socket client，连接 `/tmp/codeisland.sock`，发送 `{"event":"__healthcheck__"}`
- 连接成功 → 健康，close client socket
- 连接失败（ECONNREFUSED / timeout）→ 触发自愈

#### 自愈流程

1. 取消旧 `acceptSource`（`cancel()` → 触发 cancelHandler 关闭 FD）
2. `unlink` 旧 socket 文件
3. 重新执行 `socket()` → `bind()` → `listen()` → 创建新 `DispatchSourceRead`
4. 实现方式：将现有 `startServer()` 的 `guard serverSocket < 0` 守卫改为显式 teardown：若 `serverSocket >= 0`，先执行完整清理再重建

#### 健康检查事件过滤

- `handleClient` 解码 JSON 后，若 `event == "__healthcheck__"`，直接 close client socket 并 return
- 不传递给 `eventHandler`，不计入任何会话

#### 重启计数器

- 记录累计重启次数 `restartCount`
- 每次重启成功后自检验证
- 连续失败 3 次以上记录 error 级别日志

### 模块 2：Hook 脚本可观测性（codeisland-state.py）

#### send_event 错误报告

现有代码：
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

- 输出到 stderr：不影响 Claude Code 读取 stdout 的 hook JSON 输出
- 不改变 exit code：仍然 exit 0，避免 Claude Code 将 hook 标记为失败
- 用户在终端可看到错误提示

### 模块 3：DebugLogger 集成

- 自检失败记录：`[Socket] Health check failed: <reason>`
- 重启成功记录：`[Socket] Server restarted successfully (restart #N)`
- 重启失败记录：`[Socket] Server restart failed: <reason>`
- 启动记录：`[Socket] Server started, listening on /tmp/codeisland.sock`
- 自检成功时不记录（避免日志噪音）

## 不改动的部分

- `SessionStore`、`ClaudeSessionMonitor`、`SessionPhase` 等不变
- Hook 安装逻辑（`HookInstaller`）不变
- `settings.json` hook 配置不变
- Socket 路径 `/tmp/codeisland.sock` 不变
- 现有 `handleClient` 的数据读取逻辑不变
- 现有 `pendingPermissions` 管理不变

## 影响评估

- **向后兼容**：完全兼容，新增的自检/自愈对外部无感知
- **性能**：每 60 秒一次 socket 连接测试，开销可忽略
- **风险**：自愈重建期间（毫秒级）的 hook 事件会丢失，但比永久失联好
- **清理**：自愈时已有的 `pendingPermissions` 中的 client socket 需要 close 并通知 failure handler
