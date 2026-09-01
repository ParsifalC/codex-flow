# codex-flow MCP 服务

这是一个读取本地 FlowPilot telemetry 的 MCP 服务。服务入口是仓库根目录下的
`bin/codex-flow-mcp`，MCP HTTP endpoint 是 `/mcp`，健康检查 endpoint 是
`/healthz`。

## 手动启动与健康检查

在仓库根目录执行：

```bash
./bin/codex-flow-mcp --host 127.0.0.1 --port 8787
```

另开终端检查服务：

```bash
curl -fsS http://127.0.0.1:8787/healthz
```

wrapper 会定位当前仓库根目录并执行 `apps/chatgpt-mcp/server.py`，命令行参数会
原样传给服务，因此也可以使用其他 `--host` 或 `--port`。服务读取
`CODEX_HOME` 下的 telemetry 状态；不设置时由服务按代码使用默认的 Codex home。

实现只使用 Python 标准库，不需要 `npm install`。当前实现尽量兼容 Python 3.7；
如果运行环境中的 `server.py` 明确要求更高版本，应以该文件的实际报错为准。

## 接入 Codex CLI

把下面的 MCP server 配置加入 Codex CLI 的 `~/.codex/config.toml`（或你的
`CODEX_HOME/config.toml`）后，重启或重新加载 Codex CLI。示例只展示 URL，不会由
本项目自动修改用户配置：

```toml
[mcp_servers.codex_flow]
url = "http://127.0.0.1:8787/mcp"
```

该地址只适用于与服务运行在同一台机器上的本地 Codex CLI。服务必须保持运行，
并且 CLI 使用与 telemetry 相同的 `CODEX_HOME` 才能读到对应数据。

## 接入 ChatGPT App

ChatGPT App 的云端不能直接访问本机的 `localhost` 或 `127.0.0.1`。先在本机
启动服务，再使用一个 Secure MCP Tunnel 将本地 `/mcp` 暴露为稳定、可从公网通过
HTTPS 访问的 endpoint，例如：

```text
https://your-stable-tunnel.example/mcp
```

在 ChatGPT App 的 MCP server 设置中填写该 HTTPS URL。Tunnel 必须持续运行，且
应保持稳定的地址和必要的访问控制；本项目不提供 tunnel，也不会替用户配置
ChatGPT 或本地 Codex。

在会话中调用 `flowpilot_get_telemetry` 后，若客户端展示该服务的 UI resource，
使用 UI 中的 `Pin` 进入 PiP。`Refresh` 重新读取当前 telemetry resource，
实际调用 `flowpilot_get_telemetry` 的 `target = "last"`；`Details / expand` 请求
客户端的 expanded/fullscreen 展示并打开详情面板，客户端不支持时仍显示可用的
详情面板。这里的 PiP 是 ChatGPT 会话内的展示能力，不是
能够覆盖其他应用的系统级悬浮窗；不能据此承诺跨应用显示或由计划任务直接推送
系统级 PiP。

## 限制

- 本地服务是手动启动的 HTTP 进程；本项目不会把它加入现有安装器，也不会自动
  修改用户的 `~/.codex` 或 MCP 配置。
- ChatGPT App 的接入依赖外部 Secure MCP Tunnel、HTTPS 可达性和对应的认证策略；
  本地 loopback 地址本身不能作为 ChatGPT 云端 endpoint。
- UI 展示依赖 `CODEX_HOME` 中已有的 telemetry 数据（包括最近一次运行的
  `codex-flow/telemetry/last.json`）；本服务不会生成虚假的任务数据，也不负责
  计划任务或主动推送。

## 协议 smoke 测试

从仓库根目录运行：

```bash
tests/chatgpt-mcp.sh
```

测试会创建临时 `CODEX_HOME` 和代表性的 `last.json`，在临时 loopback 端口启动
服务，并验证 `/healthz`、MCP `initialize`、`tools/list`、
`tools/call(flowpilot_get_telemetry)`、`resources/list`、`resources/read`，以及
未知方法和未知工具的 JSON-RPC 错误。测试不会连接真实 ChatGPT，也不会读写用户
真实的 `~/.codex`；结束时会清理临时服务和目录。
