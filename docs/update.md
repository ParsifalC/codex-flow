# codex-flow OTA 更新

codex-flow 的更新通道由 GitHub Release 驱动。安装后的 CLI 与 FlowPilot App 共用同一份本地更新状态，不依赖最初的 Git checkout，也不会在启动 CLI / App 时同步阻塞网络请求。

## 用户操作

```bash
# 查看缓存并按检查周期检查更新
codex-flow update --check

# 强制刷新远端版本状态
codex-flow update --check --force

# 下载、校验并安装可用更新
codex-flow update

# 回退到上一版本
codex-flow rollback
```

终端交互菜单会直接在“更新”选项中显示“已是最新”或“vX.Y.Z 可用”。FlowPilot 顶栏提供更新按钮；有更新或已安装但仍需要重启 Codex 时显示角标。App 与 CLI 都读取 `~/.codex/codex-flow/state/update.json`。

更新安装完成后会写入 `restart_required=true`。用户完整重启 Codex 后，可在 FlowPilot 更新面板点击“我已重启 Codex”，或使用 `codex-flow update --ack-restart` 清除提醒。Updater 无法可靠跨平台证明 Codex 宿主进程是否已经完整重启，因此不伪造自动确认。

## 默认配置

```toml
[update]
channel = "stable"
check = true
check_interval_hours = 24
notify_cli = true
notify_app = true
auto_install = false
```

`stable`、`beta`、`nightly` 使用同一套 manifest 协议。CLI / App 启动时先读本地缓存；缓存过期后由独立静默进程刷新，因此 GitHub 网络延迟不会阻塞主界面。当前默认交互仍是“自动检查 + 明确提醒 + 用户主动安装”；不会静默自动升级。

## 安全与事务模型

OTA 安装流程为：

1. 获取 Release 中的 `codex-flow-update.json`。
2. 按当前 OS / CPU 架构选择 artifact。
3. 下载到临时 staging 目录。
4. 校验 SHA-256，并拒绝 archive path traversal、link 注入以及 tar device/FIFO 等特殊成员。
5. 保存当前 `config.toml`、policy、runtime、hooks、agents、skill、迁移状态、CLI 与 FlowPilot 可执行文件快照。
6. 在 staging 版本上执行增量 migration，并只增量同步 codex-flow 管理的 `config.toml [agents]` 字段；未知及用户自有配置保持不变。
7. 原子替换受管理 runtime 文件，并按 telemetry 配置安装或移除 codex-flow 自己的 hooks。
8. 运行 `doctor` 健康检查。
9. 只有健康检查成功后才提交 migration 状态、当前版本和 source 元数据。
10. 任一步骤失败都恢复升级前快照；checksum、并发锁、migration、配置同步或 doctor 失败不会绕过 OTA 去执行 Git fallback。

更新和 rollback 共用写入锁。锁文件包含持锁 PID：只有确认原持锁进程已经退出后才允许回收，不能因为一次较长的下载/安装超过时间阈值就抢占仍在工作的 updater。

首次 OTA 升级会捕获现有安装作为 rollback package；同时每次升级都保存精确的 pre-update snapshot。`codex-flow rollback` 优先恢复该次升级前的精确 snapshot，包括原 `source` 指向；只有没有可用精确 snapshot 时才使用上一版本 package 重建受管理 runtime。

## Release 发布内容

每个 OTA Release 最终对用户公开：

- `codex-flow-<version>-linux-x86_64.tar.gz`
- `codex-flow-<version>-linux-arm64.tar.gz`
- `codex-flow-<version>-windows-x86_64.zip`
- `codex-flow-<version>-windows-arm64.zip`
- `codex-flow-<version>-darwin-arm64.tar.gz`
- `codex-flow-<version>-darwin-x86_64.tar.gz`
- 每个 archive 对应的 `.sha256` 文件
- `codex-flow-update.json` manifest
- GitHub Release notes（Release body）

macOS 两个 artifact 都在对应架构的 GitHub runner 上重新编译原生 FlowPilot：Apple Silicon 使用 `darwin-arm64`，Intel 使用 `darwin-x86_64`。

### Archive 内部包含

通用平台 package 是“安装后完整运行时”，而不是只够 updater 自己工作的最小包，主要包含：

- `VERSION`、`LICENSE`、`README.md`、`README.en.md`
- `install.sh`、`install.ps1`（首次安装/恢复场景；正常 OTA 不重新跑 installer）
- `bin/`：`codex-flow`、`codex-flow.ps1`、`codex-flow.cmd`、`codex-flow-mcp`
- `scripts/`：updater、runtime config reconciler、migration、telemetry、doctor、strategy、benchmark 等运行脚本
- `templates/`：Agent 模板与 FlowPilot Skill
- `completions/`
- `policy/`
- `benchmark/`：benchmark corpus / profile 等运行数据
- `apps/chatgpt-mcp/`：MCP server、adapter 与 widget 运行资源

macOS package 额外包含完整 `apps/macos-overlay/`，包括 Swift Sources、`build.sh`、README 以及该架构新构建的 `FlowPilot` / `codex-flow-overlay`。这样 OTA 后即使 `source` 已切换到 `~/.codex/codex-flow/versions/<version>`，CLI benchmark、ChatGPT MCP 和 FlowPilot rebuild 仍然可用。

Release package 不包含 `.git`、`.github/`、`tests/` 等开发/CI 元数据。归档过程排除 `__pycache__`、`.pyc/.pyo` 和 symlink；tar/gzip 元数据固定，以提高同输入构建的可重复性。

## Release 发布原子性

Release workflow 先创建 **Draft Release**，完成全部平台构建、SHA-256、manifest 生成和六平台完整性校验后，才把 Release 从 draft 切换为公开状态。因此 updater 不会看到一个“Release 已公开但 manifest / artifact 尚未上传完整”的中间状态。

已经公开的 Release 被视为不可变：workflow 不允许重新 `--clobber` 已发布版本的 OTA 资产；需要修复时必须提升 `VERSION` 并发布新版本。只有仍处于 draft 的同版本 Release 可以被构建任务覆盖重试。

## Release channel

`VERSION` 是唯一版本源，同时决定 release channel：

- `1.8.0` → `stable`
- `1.8.0-beta.1` / `1.8.0-rc.1` → `beta`
- 包含 `nightly` 的 prerelease，例如 `1.8.0-nightly.20260903` → `nightly`

Git tag 必须严格等于 `v$VERSION`。beta / nightly GitHub Release 会被标记为 prerelease，确保 stable 客户端不会误收预发布版本。

## 重启语义

新的 CLI、updater、telemetry 和 FlowPilot binary 在 OTA 成功后已经落盘，但 Codex 对 Skill / Agent / Hook / policy snapshot 的加载需要完整重启 Codex 才能保证全部生效。因此 CLI / App 会明确保持 restart reminder，直到用户完成重启并主动确认，而不是把“文件已安装”和“Codex 已激活新 snapshot”混为一个状态。
