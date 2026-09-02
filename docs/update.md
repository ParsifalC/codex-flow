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

`stable`、`beta`、`nightly` 使用同一套 manifest 协议。CLI / App 启动时先读本地缓存；缓存过期后由独立静默进程刷新，因此 GitHub 网络延迟不会阻塞主界面。

## 安全与事务模型

OTA 安装流程为：

1. 获取 Release 中的 `codex-flow-update.json`。
2. 按当前平台选择 artifact。
3. 下载到临时 staging 目录。
4. 校验 SHA-256，并拒绝 archive path traversal / link 注入。
5. 保存当前 policy、runtime、hooks、agents、skill、迁移状态与可执行文件快照。
6. 在 staging 版本上执行增量 migration，再原子替换受管理文件。
7. 运行 `doctor` 健康检查。
8. 只有健康检查成功后才提交 migration 状态与当前版本元数据。
9. 任一步骤失败都恢复升级前快照；checksum、并发锁、migration 或 doctor 失败不会绕过 OTA 去执行 Git fallback。

首次 OTA 升级会捕获现有安装作为 rollback package。`codex-flow rollback` 会恢复上一版本 runtime 以及该次升级前保存的用户配置快照。

## Release 协议

每个 OTA Release 发布：

- 各平台 archive；
- 对应 SHA-256；
- `codex-flow-update.json` manifest；
- Release notes。

当前正式打包目标为 `linux-x86_64`、`windows-x86_64`、`darwin-arm64`。macOS artifact 在 Release workflow 中重新编译原生 FlowPilot。

`VERSION` 是唯一版本源，同时决定 release channel：

- `1.8.0` → `stable`
- `1.8.0-beta.1` / `1.8.0-rc.1` → `beta`
- 包含 `nightly` 的 prerelease，例如 `1.8.0-nightly.20260903` → `nightly`

Git tag 必须严格等于 `v$VERSION`。beta / nightly GitHub Release 会被标记为 prerelease，确保 stable 客户端不会误收预发布版本。

## 重启语义

更新完成后 CLI 与 App 会写入 `restart_required=true`。新的 CLI、updater、telemetry 与 FlowPilot binary 已落盘，但 Codex 对 Skill / Agent / Hook / policy snapshot 的加载需要完整重启 Codex 才能保证全部生效，因此 UI 会持续提醒直到用户完成重启后的下一轮状态更新。
