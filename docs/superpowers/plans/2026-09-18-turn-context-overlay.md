# FlowPilot 轮次上下文浮窗 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为每个真实宿主 turn 保存可验证的本轮目标、实际 ExecutionPlan、父 Agent final 结果和完整发布快照，并在 macOS 原生浮窗及历史中按 `session_id + turn_id` 展示。

**Architecture:** Hook 只用宿主实际提供的 `session_id`、`turn_id` 登记本轮 receipt（本轮可重复使用，Stop 后封存）；宿主能够在同一轮传递该 receipt 时，父 Agent 通过 UTF-8 文件参数写入 turn sidecar。父 Stop 在锁外读取 transcript/app-server，在同一 run 锁与发布锁顺序内合并最新事实、目标、完整计划和父 final，原子写 run 后稳定更新 `last.json`，watcher/IPC 只消费带 publication 的完整快照。Swift 模型直接解码可选的新字段，旧 schema 仍可读；UI 先用可点击 HTML 仿真确认，再实现 macOS 原生毛玻璃界面。

**Tech Stack:** Python 3.8+ 标准库（`json`、`hashlib`、`unittest`、文件锁/原子替换），现有 `codex-flow telemetry` CLI 与 Hook，Swift/SwiftUI/AppKit（`NSVisualEffectView`），macOS `swiftc` 纯模型/query 测试，Windows 兼容的 Python/PowerShell CLI 验收。

**Spec:** `docs/superpowers/specs/2026-09-18-turn-context-overlay-design.md`

## Global Constraints

- 用户原始消息与 transcript 不得因需求提炼而改写。
- 目标归属 `session_id + turn_id`；不新增 chat 目标版本管理。
- 仅父 Stop 发布本轮详情；不新增运行中进度展示。
- 结果文案固定为“结果”；缺失提炼或结果显示“未记录”。
- 保存 planner 的完整 ExecutionPlan；不另造策略引擎，不重置已有任务预算。
- `telemetry.enabled=false` 时不得新增凭证、sidecar、run、last 或 IPC 写入；主任务正常继续。
- `strategy.enabled=false` 或本任务 bypass 时不伪造计划；已有历史照常可读。
- 本期只记录 FlowPilot 参与的轮次；本期原生 UI 只实现 macOS。
- Python 数据层和 CLI 保持 Windows 兼容；不提高现有 Python 最低版本声明，不新增第三方运行时依赖。
- 政策 schema v4、ExecutionPlan schema v11、task-ledger schema v2 保持原有语义；新增元数据单独 version。
- 构建和安装验收必须使用临时 `CODEX_HOME`，不得覆盖开发者已安装的运行时或浮窗。
- 保留四个 tab 与现有主要操作；仅删除五小时额度 UI，不删除对应底层采集。

补充实施约束：目标按 1–80 个 Unicode 码点、最多两句话校验；轮次以宿主 turn_id 为准；同任务后续轮次保留原计划与 ledger，记录 origin=reused；只记录可验证编排配置，不记录模型内部推理。

---

## 文件与接口地图

先按职责保持小模块边界：`turn_context.py` 只负责 receipt、sidecar 和元数据校验；`turn_result.py` 只负责指定 turn 的父 final 提取；`publication.py` 只负责 Stop 快照、修订、last 选择、崩溃恢复和通知判定。`collector.py` 负责 Hook 生命周期和昂贵读取，`telemetry.py` 负责 CLI 路由与兼容包装。Swift `TelemetryData.swift` 只负责 Codable 模型，`TelemetryQueryEngine.swift` 只负责已发布快照读取和历史分组，视图文件只负责呈现和已有操作。

实施顺序为 Task 1 → 2 → 3 → 4 → 5（仿真确认）→ 6 → 7 → 8。每个代码任务先运行本任务列出的测试命令，确认新增断言因缺少功能而失败，再实现并跑到通过；通过后按该任务 Files 单独审查、形成独立提交。不要混入本次功能之外的 README 和开发上手指南既有改动。文档中的接口省略号仅表示函数签名声明，不是实现占位。

跨任务固定 Python 接口如下，后续任务不得改名或改变字段含义：

```python
# 接口声明；实现沿用 from __future__ import annotations，并导入 dataclasses/pathlib/typing。
# scripts/telemetry_core/turn_context.py
class ReceiptError(ValueError):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code

@dataclass(frozen=True)
class TurnReceipt:
    schema_version: int
    session_id: str
    turn_id: str
    receipt_id: str
    role: str

def receipt_digest(session_id: str, turn_id: str) -> str: ...
def register_receipt(event: Mapping[str, Any], *, state_root: Path = STATE_ROOT) -> TurnReceipt: ...
def load_receipt(path: Path) -> TurnReceipt: ...
def validate_receipt(receipt: TurnReceipt, *, state_root: Path = STATE_ROOT) -> None: ...
def seal_receipt(receipt: TurnReceipt, *, state_root: Path = STATE_ROOT) -> None: ...
def validate_execution_plan(plan: Mapping[str, Any]) -> None: ...
def context_path(session_id: str, turn_id: str, state_root: Path = STATE_ROOT) -> Path: ...
def write_goal(*, receipt_file: Path, text_file: Path,
               state_root: Path = STATE_ROOT,
               clock: Callable[[], int] = now_ms) -> dict[str, Any]: ...
def write_plan(*, receipt_file: Path, plan_file: Path, origin: str,
               state_root: Path = STATE_ROOT,
               clock: Callable[[], int] = now_ms) -> dict[str, Any]: ...
def load_context(session_id: str, turn_id: str,
                 state_root: Path = STATE_ROOT) -> dict[str, Any] | None: ...

# scripts/telemetry_core/turn_result.py
def extract_parent_final(transcript_path: str | None, turn_id: str | None,
                         *, session_id: str, max_chars: int = 0) -> dict[str, Any] | None: ...

# scripts/telemetry_core/publication.py
@dataclass(frozen=True)
class PublicationResult:
    published: bool
    changed: bool
    revision: int | None
    last_updated: bool
    notify: bool
    reason: str | None
    snapshot: dict[str, Any] | None

def publish_parent_stop(*, run_key: str, observed: Mapping[str, Any],
                        result: Mapping[str, Any] | None,
                        completed_at_ms: int,
                        state_root: Path = STATE_ROOT) -> PublicationResult: ...
def publish_late_worker(*, run_key: str, observed: Mapping[str, Any],
                        state_root: Path = STATE_ROOT) -> PublicationResult: ...
def recover_last(*, state_root: Path = STATE_ROOT) -> PublicationResult: ...

# scripts/telemetry_core/common.py
def telemetry_writes_enabled() -> bool: ...
# state_lock 是 contextmanager；yield bool，沿用现有调用方式。
def state_lock(key: str, *, state_root: Path = STATE_ROOT): ...
```

`context_path()` 只计算 `[session_id, turn_id]` 的规范 JSON 的 SHA-256 路径 `turn-context/<digest>.json`，不创建目录； 只有非敏感的 `session_id/turn_id/schema_version` 进入公开元数据；`receipt_id/role` 等凭证内容不得进入 sidecar、run、`last.json`、复制摘要、日志或统计。 CLI 错误在 stderr 输出 JSON `ok=false,error=<稳定错误码>` 并 exit 2；遥测关闭时输出 `ok=false,status="disabled",reason="telemetry_disabled"` 并 exit 0。skill 明确任何记录失败都不阻断主任务。

### Task 1: 真实宿主凭证绑定与兼容性闸门

**Files:**
- Create: `scripts/telemetry_core/turn_context.py`
- Modify: `scripts/telemetry_core/common.py`（共享遥测写入守卫和可注入 state_root 的 OS 锁）
- Create: `tests/test_lock_recovery.py`
- Create: `tests/test_turn_context.py`
- Create: `tests/turn-context-host.sh`
- Create after the real host probe: `tests/fixtures/turn-context/host-validation.json`（脱敏 fixture；`status` 为 `supported`、`unsupported` 或 `unverified`）
- Modify: `scripts/telemetry_core/collector.py:850-946`（仅接入已验证 transport，不改变现有 worker 归属算法）
- Modify: `tests/telemetry-core.sh`（补充 receipt 缺失/错轮次/子 Agent 拒绝断言）

**Interfaces:**
- Consumes: Hook event 的实际 `session_id`、`turn_id`、`hook_event_name`；真实宿主文档或行为验证出的同轮上下文传输方式。
- Produces: `TurnReceipt`、`load_receipt()`、`receipt_digest()` 以及 fail-closed 的 `receipt_missing`、`receipt_mismatch`、`receipt_expired`、`receipt_role_forbidden` 错误码。

- [ ] **Step 1: 在真实宿主中验证传输，不用合成 stdin 代替。** 先检查当前宿主版本的真实 Hook 上下文协议，在临时安装内接入最小 receipt 登记/传递探针，然后运行下列连通性检查；命令本身不证明 receipt 已送达。目标宿主为 Codex 桌面时必须单独验证桌面入口，CLI 验证只支持 CLI 的兼容性声明。使用临时安装目录，保持开发者 home 隔离：

```bash
set -euo pipefail
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
export CODEX_HOME="$TMP_HOME/codex-home"
export CODEX_FLOW_BIN_DIR="$TMP_HOME/bin"
export CODEX_FLOW_SHELL=none
mkdir -p "$CODEX_HOME"
rtk proxy bash install.sh >/dev/null
rtk proxy which codex
rtk proxy codex login status
rtk proxy codex exec --json --skip-git-repo-check "输出一个固定 marker：turn-context-host-probe" >"$TMP_HOME/host-output.jsonl"
```

若临时 home 缺认证、Hook 未获信任、版本无法启动或目标宿主不可用，立即记 `unverified` 并停止探针；不复制真实用户的认证文件，不把环境失败当成协议不支持。认证和 Hook 信任就绪后，记录真实 Hook 收到的字段、receipt 是否经支持协议传入**同一次**父 turn、父 Agent 是否能调用最小凭证校验器而不改用户消息。Task 2 完成后用同一宿主再跑 write-goal/write-plan 到 Stop 全链路，才允许 `supported`。只接受宿主明确支持的上下文注入/传递协议；不能把 `systemMessage`、任意 JSON 输出、`CODEX_THREAD_ID`、`CODEX_SESSION_ID` 或“唯一活动 turn”推断成支持证据。协议确实不支持则记 `unsupported`；未证明支持时一律关闭自动写入，显示“未记录”。

- [ ] **Step 2: 为 receipt 做纯 Python 单测，覆盖结构和值域。** 生成的 receipt 必须满足以下形状，并拒绝伪造或跨轮使用：

```python
receipt = {
    "schema_version": 1,
    "session_id": "chat-a",
    "turn_id": "turn-2",
    "receipt_id": "opaque-random-id",
    "role": "parent",
}
loaded = load_receipt(receipt_file)
assert loaded.session_id == "chat-a"
assert loaded.turn_id == "turn-2"
assert receipt_digest("chat-a", "turn-2") != receipt_digest("chat-a", "turn-3")
with self.assertRaises(ReceiptError) as exc:
    load_receipt(child_receipt_file)
self.assertEqual(exc.exception.code, "receipt_role_forbidden")
```

校验 `schema_version == 1`、非空字符串 ID、`role == "parent"`。`load_receipt` 只解析输入；`validate_receipt` 必须在写入锁内比对 hook 侧 `turn-receipts/<digest>.json` 登记的随机 `receipt_id`、两项 ID 和 active 状态；不能仅相信调用方 JSON 自称 parent。重复 UserPromptSubmit 返回同一凭证；Stop 将其 sealed，旧凭证、未知凭证或被替换的凭证报 `receipt_expired`。身份验证是正确关联边界，不宣称抵抗恶意 Agent。不要从 `last.json`、最近文件、唯一活动轮次或全局环境补任何缺失字段。

- [ ] **Step 3: 实现确定性 digest、路径和 fail-closed 错误。** 用 `json.dumps([session_id, turn_id], ensure_ascii=False, separators=(",", ":"))` 编码后 SHA-256；只允许安全的已校验字符串进入摘要，只有已启用遥测且通过凭证校验的写入路径才创建目录。`telemetry.enabled=false` 在调用入口直接返回 disabled，不创建 receipt、sidecar、run、last 或 IPC。

此任务先实现 `common.telemetry_writes_enabled()`，读取现有策略文件 `[telemetry].enabled`，所有 hook、receipt/sidecar、publication、repair/recover 和通知写入入口都先调用它，锁目录创建也在守卫之后。保留读取历史能力。`state_lock` 在本任务落地：POSIX `fcntl.flock`，Windows `msvcrt.locking` 首字节锁，固定 `.lck` 文件不删除，进程退出自动释放；超时或平台不支持 yield False，禁止裸写。用 subprocess 持锁后退出测试恢复；之后 Task 2 才能依赖其 `state_root` 参数。

`register_receipt()` 在父 UserPromptSubmit 的 `turn-<digest>` 锁内生成 `secrets.token_urlsafe(32)`，登记 receipt 与 `state="active"`；重复同 turn 幂等，已封存不重开。过期按轮次状态判断，不随意设短的墙钟 TTL；Stop、已确认中止及 retention 清理使凭证失效。新 run 写 `publication_required=true`，供 UI 区分未发布新数据与旧历史。凭证缺失不妨碍 Stop 发布“未记录”。

- [ ] **Step 4: 把真实宿主结果写入脱敏 fixture，并执行宿主 gate。** `tests/turn-context-host.sh` 运行同一临时安装流程和真实宿主命令；成功时断言 receipt 的 session/turn 与该次 Stop 的两字段相同且父 Agent 能读取，失败时断言自动写入拒绝并输出结构化兼容性原因。`tests/fixtures/turn-context/host-validation.json` 只保留字段名、状态、脱敏 ID 和验证日期，不保存 prompt、transcript、receipt secret 或模型输出。单元测试通过不能替代此 gate。

Run:

```bash
set -euo pipefail
rtk proxy python3 -m unittest tests/test_turn_context.py
rtk proxy bash tests/turn-context-host.sh
```

Expected: 单测 PASS；宿主验证脚本只有完整链路证实支持时 exit 0。`unsupported`/`unverified` 可以通过拒绝写入测试，但功能发布门不通过（exit 2）；不能把安全降级包装成支持。首次探针后继续实现 Task 2 用于全链路验证，依然禁止对未证实宿主启用生产写入。

### Task 2: sidecar、CLI 与 FlowPilot 写入顺序

**Files:**
- Modify: `scripts/telemetry_core/turn_context.py`（实现元数据写入与完整计划校验）
- Modify: `scripts/telemetry.py:198-390`（新增 `context` 子命令路由，保留现有 latency/last/list/show/stats/repair）
- Modify: `templates/flow-pilot-instructions.md`（全局指令中的本轮字段与写入顺序）
- Modify: `templates/skills/flow-pilot/SKILL.md`（源码模板；不得直接编辑个人 `CODEX_HOME/skills/flow-pilot/SKILL.md`）
- Modify: `tests/telemetry-core.sh`（CLI 文件参数与幂等/冲突测试）
- Create: `tests/test_turn_context_cli.py`

**Interfaces:**
- Consumes: Task 1 的 receipt 登记/校验接口、已验证的传递协议与共享锁；本任务实现 `write_goal/write_plan()`。
- Produces: `codex-flow telemetry context write-goal --receipt-file <path> --text-file <utf8-path>`；`codex-flow telemetry context write-plan --receipt-file <path> --plan-file <json-path> --origin compiled|reused|replanned`。

- [ ] **Step 1: 先写 CLI 失败测试，确认参数必须是文件路径。** 用 `subprocess.run([sys.executable, telemetry.py, "context", ...])`，目标文本通过 UTF-8 临时文件传入；断言缺参数、重复参数、未知 origin、非法 JSON、空文本、401 个 Unicode 码点均返回 2 和 JSON `error`，而不是 shell 插值后的截断文本。

```python
def run_cli(*args):
    # self.home 在 setUp 中使用 TemporaryDirectory；设置环境后再启动全新 Python 进程。
    return subprocess.run(
        [sys.executable, str(ROOT / "scripts/telemetry.py"), *args],
        env={**os.environ, "CODEX_HOME": str(self.home)},
        text=True, capture_output=True, check=False,
    )

proc = run_cli("context", "write-goal", "--receipt-file", str(receipt), "--text-file", str(text_file))
self.assertEqual(proc.returncode, 0)
payload = json.loads(proc.stdout)
self.assertEqual(payload["session_id"], "chat-a")
self.assertEqual(payload["turn_id"], "turn-2")

bad = run_cli("context", "write-goal", "--receipt-file", str(receipt), "--text-file", str(empty_file))
self.assertEqual(bad.returncode, 2)
self.assertEqual(json.loads(bad.stderr)["error"], "goal_empty")
```

- [ ] **Step 2: 实现 sidecar 合并规则。** `write_goal()` 只允许首次写入或与现有 `goal.text` 完全相同的幂等写入；不同文本返回 `goal_conflict`，不覆盖首次成功目标。`write_plan()` 调用 `validate_execution_plan()`：只接受 JSON object，要求 `schema_version == 11` 且包含 `dataclasses.fields(strategy_runtime.ExecutionPlan)` 定义的全部字段，复用现有 StagePolicy 与 task budget 合约校验嵌套结构/枚举/数值/direct-delegate 约束，缺字段（如只传 schema_version）必须报 `invalid_execution_plan`；不能凭一个版本号认定完整。`origin` 只允许 `compiled/reused/replanned`；规范化 JSON 相同则幂等，不同则递增 `orchestration.revision`，保存完整原始对象而非只摘录策略名。两个操作与 Stop 使用同一个 `turn-<digest>` run 锁；锁内校验 active receipt、重读 sidecar、执行幂等/冲突校验，再调用 `atomic_json()`，防止 goal 与 plan 并发互相覆盖。允许独立部分缺失；不把 recorded_at_ms 的重新计算当作内容变更。

```python
with state_lock("turn-" + receipt_digest(receipt.session_id, receipt.turn_id),
                state_root=state_root) as acquired:
    if not acquired:
        raise ReceiptError("locked")
    validate_receipt(receipt, state_root=state_root)
    context = load_context(receipt.session_id, receipt.turn_id, state_root) or {
        "schema_version": 1, "session_id": receipt.session_id, "turn_id": receipt.turn_id
    }
    existing = context.get("goal")
    if existing and existing["text"] != text:
        raise ReceiptError("goal_conflict")
    if not existing:
        context["goal"] = {"text": text, "source": "flow-pilot", "recorded_at_ms": clock()}
        atomic_json(context_path(receipt.session_id, receipt.turn_id, state_root), context)
```


- [ ] **Step 3: 在指令模板中固定父 Agent 顺序与边界。** 先完成现有 FlowPilot 入口 gate：读取 skill、`show --json`，仅新任务且策略启用时消费一次 bypass；同任务后续轮次沿用 receipt/计划/ledger。只有本任务参与 FlowPilot 且遥测启用时，才以宿主 receipt 的 `session_id + turn_id` 记录目标，再进行 TaskProfile/planner 工作并写入实际返回的完整 ExecutionPlan。入口顺序不得因元数据写入而倒置。后续同任务轮次沿用原计划与 ledger 时写 `origin=reused`，不得重复消费 bypass、重置预算或把 receipt 放进 worker handoff；目标成功后同轮不得改写。关闭策略或 bypass 时不伪造计划。模板只说明 CLI/已验证宿主上下文，不把 receipt 注入用户原文。

- [ ] **Step 4: 运行 CLI、安装副本和 Python 兼容检查。** 完成后重跑 Task 1 的真实宿主链路，必须看到同一父 turn 使用收到的 receipt 成功执行 write-goal/write-plan，且 Stop 合并到相同两项 ID；此时才能把 host fixture 改为 supported。

```bash
set -euo pipefail
rtk proxy python3 -m unittest tests/test_turn_context_cli.py
rtk proxy bash tests/telemetry-core.sh
FLOW_TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$FLOW_TEST_ROOT"' EXIT
CODEX_HOME="$FLOW_TEST_ROOT/home" CODEX_FLOW_BIN_DIR="$FLOW_TEST_ROOT/bin" CODEX_FLOW_SHELL=none rtk proxy bash install.sh
```

安装验证要从临时 `CODEX_HOME/codex-flow/telemetry_core/turn_context.py` 运行同样的 CLI；不手工复制个人安装 skill。重复 `write-goal`/相同 plan 不改变文件或 revision，不同目标返回 `goal_conflict`。

### Task 3: 轮次限定的父 Agent final 提取

**Files:**
- Create: `scripts/telemetry_core/turn_result.py`
- Modify: `scripts/telemetry_core/app_server.py:967-1132`（保留 skills/tools/trajectory/logs 提取，移除按 transcript 最后一条 assistant 代替本轮结果的路径）
- Modify: `scripts/telemetry.py:64-78,182-195`（改用 `extract_parent_final()`，不直接取 Stop 参数猜结果）
- Create: `tests/test_turn_result.py`
- Modify: `tests/telemetry-core.sh`（多 turn/commentary/worker fixture）

**Interfaces:**
- Consumes: run 中的精确 `transcript_path`、`turn_id`；Task 1 的轮次键；真实 transcript 的父 final 事件格式。
- Produces: `extract_parent_final()` 返回 `{"text": str, "source": "parent_final", "turn_id": target, "truncated": bool}` 或 `None`；只写入本轮 `result`。

- [ ] **Step 1: 写 transcript fixture 测试。** fixture 必须包含旧 turn 的父 final、指定 turn 的 user、commentary、worker assistant、指定 turn 的父 assistant final 和下一 turn 的父 final；断言返回指定 turn 的父 final，多条 commentary/worker/下一轮内容都不进入结果。

```python
result = extract_parent_final(str(transcript), "turn-2", session_id="chat-a")
self.assertEqual(result, {
    "text": "本轮最终结果",
    "source": "parent_final",
    "turn_id": "turn-2",
    "truncated": False,
})
self.assertIsNone(extract_parent_final(str(transcript_without_final), "turn-2", session_id="chat-a"))
```

- [ ] **Step 2: 实现严格扫描算法。** 顺序读取 JSONL，先以真实宿主 fixture 中的 session metadata 核对父 transcript 归属 `session_id`（拒绝 worker transcript）。复用现有 `transcript_turn_metadata/transcript_turn_usage` 的 `turn_context/task_started/task_complete` 边界思想：显式 turn ID 优先，否则只在无歧义的当前 turn 区间归属 response_item；切换/结束时清空区间。不能要求每条 response_item 都重复携带 turn_id，也不能扫描整段后取最后一条。目标区间中只选父 assistant 且宿主明确标记 `final` 的文本片段；字段名与结束事件名必须来自 Task 1 的真实宿主脱敏 fixture，未识别格式返回 None。显式 `truncated` 原样带出；`max_chars > 0` 时只为 UI 读取截断并标记 `truncated=true`，sidecar/run 中默认保存源文本。缺少 turn、final 标记或父角色证明时返回 `None`，不使用上一条 assistant、commentary、worker 回复、用户输入或 `last_assistant_message` 作为替代。

- [ ] **Step 3: 扩展 run 可选字段并保持旧读取兼容。** Stop 合并时设置 `result`，字段只含 `text/source/turn_id/truncated`，不复制 receipt；目标和计划仍来自 sidecar。`extract_transcript_insights()` 的 `summary_info.goal/conclusion` 不能再驱动本轮目标/结果显示；历史旧 run 缺字段时 UI 各自显示“未记录”。

- [ ] **Step 4: 验证多轮与原文不变。**

```bash
set -euo pipefail
rtk proxy python3 -m unittest tests/test_turn_result.py
rtk proxy bash tests/telemetry-core.sh
```

Expected: 指定 `turn_id` 才能得到父 final；同 chat 连续两轮的结果互不覆盖，补充消息若宿主仍给同一个 turn 必须继续归入该 turn，代码不得按消息数量创建新键。

### Task 4: Stop 完整快照、并发和恢复发布

**Files:**
- Create: `scripts/telemetry_core/publication.py`
- Modify: `scripts/telemetry_core/common.py:state_lock`（保留既有调用兼容性，新增可选 keyword-only `state_root`，使用可在进程退出时释放的 OS 锁）
- Modify: `scripts/telemetry_core/repair.py`（修复写入遵循相同锁、revision、last 排序，不能旁路覆盖快照）
- Modify: `tests/test_lock_recovery.py`（Task 1 已创建；增加发布全局锁恢复场景）
- Modify: `scripts/telemetry_core/collector.py:850-1247`（把父 Stop 发布交给 publication；worker 事实更新保持 run 锁）
- Modify: `scripts/telemetry.py:64-78,124-126,182-195`（删除重复 `_persist_enriched_run()` 的裸写 last/run 路径）
- Create: `tests/test_publication.py`
- Modify: `tests/telemetry-core.sh`, `tests/telemetry-repair.sh`（乱序/重复/锁超时/崩溃恢复）

**Interfaces:**
- Consumes: collector 在锁外取得的 transcript/app-server 事实、`turn_context.load_context()`、`turn_result.extract_parent_final()`；现有 `state_lock()`、`load_run()`、`atomic_json()`。
- Produces: `PublicationResult`（含持久化 snapshot）；run 中 `publication={"revision": int, "completed_at_ms": int}`；只在完整发布后更新 `last.json` 和 IPC 通知。

- [ ] **Step 1: 先写发布行为测试。** 覆盖两个 chat 并行、同 chat 两 turn、重复 Stop、乱序 Stop、迟到 worker、锁超时和写 run 后崩溃模拟；断言完整文件、不回滚 last、相同内容 revision 不变且不重复通知、真实迟到 worker 仅在仍为 last 时刷新。

```python
first = publish_parent_stop(run_key="chat-a--turn-2", observed=observed, result=result, completed_at_ms=200, state_root=self.root)
repeat = publish_parent_stop(run_key="chat-a--turn-2", observed=observed, result=result, completed_at_ms=200, state_root=self.root)
self.assertEqual(first.revision, 1)
self.assertFalse(repeat.changed)
self.assertFalse(repeat.notify)
self.assertEqual(json.loads((self.root / "last.json").read_text())["publication"]["revision"], 1)
```

- [ ] **Step 2: 把昂贵读取移到 run 锁外。** Stop 入口先解析 transcript final、读取 app-server/thread/usage、计算 quota 和 worker 事实；随后 `publish_parent_stop()` 在统一 `turn-<digest>` run 锁内重新加载最新 run、将 receipt 标记 sealed、读取 sidecar，再合并观察值。磁盘 worker map 是合并基底，不能用锁外 observed 整体覆盖；复用现有 execution/agent 归属，逐 worker/execution 保留较新终态与 usage，禁止重复累加重放数据；observed 不得覆盖 turn_context/result/publication。当前 run 文件若其 session/turn 与参数不一致，返回 `run_identity_mismatch`，不得覆盖。Stop 以后迟到目标/计划被拒绝，worker 事实补充由 publish_late_worker 完成。任何 `state_lock()` 返回 `False` 都立即返回 `locked`，不能裸写。

SubagentStop 明确分流：父轮次未发布时仅在同一 run 锁内保存 worker 事实；已发布时必须调用 `publish_late_worker()`，不得再执行 collector 旧的裸写 run/last 路径。`repair_history` 同样在锁内重读最新 run 再应用缺失字段修复，已发布记录使用同一 revision/last 规则；不补猜测的目标或结果、不凭修复推断父 Stop。

- [ ] **Step 3: 验证锁恢复并固定锁顺序。** 复用 Task 1 的 OS 锁实现，增加全局发布锁的进程退出测试。所有会修改同一 run 的路径统一使用 `run lock -> global publish lock`，没有反向顺序。部署验收时结束旧版本 hook writer，避免新 `.lck` 与旧 mkdir 锁同时工作。Windows 先写入一个锁字节再 seek(0)，锁定期间保留句柄，释放不删除 lock file。

- [ ] **Step 4: 实现指纹 revision。** 用去掉 `publication.revision` 的规范 JSON（`sort_keys=True,separators=(",", ":")`）做内容指纹；相同指纹不递增、不通知；变化递增 revision。`completed_at_ms` 优先取本轮宿主完成事件时间，缺失时取首次成功 Stop 记录时间，一旦保存永不随重试变化，`last.json` 只按 `(completed_at_ms, session_id, turn_id)` 稳定选择，迟到旧轮次不能回滚。

- [ ] **Step 5: 原子发布和恢复。** 完整快照先 `atomic_json(run_path, run)`，成功后再按稳定排序写 `last.json`；两个文件之间崩溃不宣称跨文件事务，`recover_last()` 选择最新已有 publication 快照并修复 last，不触发完成通知；新增 `codex-flow telemetry recover-last` CLI 作为显式入口，Swift watcher 启动第一次读取前调用它，`telemetry repair` 收尾也调用。恢复在全局发布锁内选择并重读候选，不反向获取 run 锁；不会把半成品 run 提升为已完成。watcher/IPC 的读取只接受 `(session_id, turn_id, publication.revision)` 去重键。

通知调用方以 PublicationResult 为准。`snapshot` 为这次实际持久化的完整值；重复 Stop 返回 `changed=false,notify=false`，恢复与 late worker 永远 `notify=false`。只有 `last_updated=true` 才发 IPC，只有首次父 Stop 完成且成为当前 last 才发系统完成通知。删除 `_localized_send_system_notification` 内的再次持久化/IPC；通知开关只控制提醒，不阻断落盘或 IPC。

```python
if publication.last_updated:
    _notify_overlay_safely()
if publication.notify and publication.snapshot is not None:
    send_system_notification(publication.snapshot)
```

测试通过 monkeypatch/socket fake 断言各调用次数，尤其 `changed=false`、恢复、late worker 和 `telemetry.enabled=false`，不能只检查 JSON 文件内容。

- [ ] **Step 6: 运行并发与回归测试。**

```bash
set -euo pipefail
rtk proxy python3 -m unittest tests/test_lock_recovery.py tests/test_publication.py
rtk proxy bash tests/telemetry-core.sh
rtk proxy bash tests/telemetry-repair.sh
rtk proxy bash tests/telemetry.sh
```

Expected: Stop 前 run/last 不出现目标、计划、结果快照；父 Stop 后三者同读；`telemetry.enabled=false` 不写任何新 telemetry/IPC；旧历史可读但缺失字段显示“未记录”。

### Task 5: 可点击修正仿真与用户确认门

**Files:**
- Create: `apps/macos-overlay/flowpilot-overlay-navigation.html`（从 spec 链接的已批准外部仿真复制，不重新设计导航）
- Create: `apps/macos-overlay/Preview/fixtures/turn-context.json`
- Create: `apps/macos-overlay/Preview/fixtures/turn-context-missing.json`
- Create: `apps/macos-overlay/Preview/fixtures/turn-context-long.json`

**Interfaces:**
- Consumes: Task 4 发布 JSON 契约；Task 6 依赖此任务，不反向依赖 Swift 实现；不连接真实 telemetry，不宣称原生效果已验证。
- Produces: 可点击四 tab、更多菜单、任务切换、历史 chat/turn、置顶/收起交互和缺失/长文本状态的单文件仿真。

- [ ] **Step 1: 先创建 fixture，展示本轮目标、结果、实际计划配置和运行事实。** `turn-context.json` 包含两个 chat、每个 chat 至少两 turn，字段使用真实 JSON key；`turn-context-missing.json` 分别缺 goal/result/orchestration；`turn-context-long.json` 的目标不超过 80 码点且最多两句话，结果可包含多段超过 400 码点的文本；无效超长目标属于后端拒绝测试，不作为有效显示 fixture。不得把用户原文自动变成目标。

- [ ] **Step 2: 实现单文件导航与状态。** 仿真必须保留 Inspector/History/Analytics/Account 四 tab；更多菜单的更新、隐私、GitHub、控制台、复制摘要动作可点击；任务切换、历史入口、置顶、收起、长文本展开可操作。执行详情默认折叠，计划人数和实际参与人数分开；没有 publication 时只显示“尚无已完成轮次”，不画空进度条或实时进度。

- [ ] **Step 3: 删除仿真中的五小时额度卡片并写 Windows 降级样式。** 账户保留身份、其他额度/重置事实、全局策略和自启动；五小时卡片、进度条、提示全部消失。Windows 预览只表达高不透明度亚克力/高对比纯色降级，不能作为 Windows 原生验证。

- [ ] **Step 4: 交付可点击绝对路径并暂停生产 UI。** 提供并让用户确认这个实际文件：`[flowpilot-overlay-navigation.html](/Users/zcj/Documents/WebProject/codex-flow/apps/macos-overlay/flowpilot-overlay-navigation.html)`。在用户确认前不得进入 SwiftUI 生产改造；确认记录只包含界面反馈，不改本计划的数据契约。

验证：先检查 HTML/JS 语法，再使用当前宿主提供的浏览器工具打开该本地文件或本地预览地址，逐项点击四 tab、更多、历史、筛选、切换、置顶、收起和复制。不要用脚本后台驱动浏览器替代获支持的浏览器工具。

### Task 6: macOS 模型/query 与原生四 tab 毛玻璃

**Files:**
- Modify: `apps/macos-overlay/Sources/Models/TelemetryData.swift:497-650`
- Modify: `apps/macos-overlay/Sources/Services/TelemetryQueryEngine.swift:42-140,230-300`
- Modify: `apps/macos-overlay/Sources/Services/TelemetryWatcher.swift`
- Modify: `apps/macos-overlay/Sources/Services/IPCServer.swift`
- Modify: `apps/macos-overlay/Sources/Views/SummaryView.swift`
- Modify: `apps/macos-overlay/Sources/Views/HistoryView.swift`
- Modify: `apps/macos-overlay/Sources/Views/AccountView.swift`
- Modify: `apps/macos-overlay/Sources/Views/AnalyticsView.swift`（视觉统一，保留 7/30 天统计逻辑）
- Modify: `apps/macos-overlay/Sources/Localization.swift`（中英文“结果”/“未记录”与编排标签）
- Create: `apps/macos-overlay/Sources/Views/TurnDetailView.swift`（任务和历史复用详情，避免两套规则漂移）
- Modify: `apps/macos-overlay/Sources/Controllers/OverlayWindowController.swift`
- Create: `apps/macos-overlay/Sources/Views/VisualEffectBackground.swift`
- Create: `apps/macos-overlay/Tests/TelemetryTurnContextTests.swift`
- Modify: `.github/workflows/macos-overlay.yml`（加入纯 model/query `swiftc` 测试命令）

**Interfaces:**
- Consumes: Task 4 的 `turn_context`、`result`、`publication` JSON；Task 5 用户确认后的布局和操作清单。
- Produces: Codable `TurnContext`, `OrchestrationInfo`, `TurnResult`, `PublicationInfo` 可选属性；`TaskRun.id == session_id--turn_id`；query/watcher/IPC 使用 `(sessionId, turnId, publicationRevision)` 去重。

- [ ] **Step 1: 为 Swift Codable 模型写失败测试。** 用 JSONDecoder 解码新快照和旧 schema v1；断言旧 JSON 不抛错，新字段按 snake_case 映射，`TaskRun` 的 `id` 仍由 session+turn 组成，缺 goal/result/orchestration 分别得到 nil。

测试沿用仓库纯 Swift 可执行程序风格，不能只写 XCTest 断言却不运行测试：
```swift
import Foundation
func L(_ english: String, _ chinese: String) -> String { english }

@main
struct TelemetryTurnContextTests {
    static func main() throws {
        let json = """
        {"session_id":"chat-a","turn_id":"turn-2",
         "turn_context":{"schema_version":1,"session_id":"chat-a","turn_id":"turn-2",
           "goal":{"text":"本轮目标","source":"flow-pilot","recorded_at_ms":100}},
         "result":{"text":"结果","source":"parent_final","turn_id":"turn-2"},
         "publication":{"revision":1,"completed_at_ms":200}}
        """
        let run = try JSONDecoder().decode(TaskRun.self, from: Data(json.utf8))
        precondition(run.id == "chat-a--turn-2")
        precondition(run.turnContext?.goal?.text == "本轮目标")
        precondition(run.result?.source == "parent_final")
        precondition(run.publication?.revision == 1)
        print("Turn context model tests passed")
    }
}
```

- [ ] **Step 2: 添加模型并限制 transcript 富化。** `TaskRun` 增加可选 `turnContext: TurnContext?`、`result: TurnResult?`、`publication: PublicationInfo?`；`OrchestrationInfo` 保留 `origin/revision/executionPlan`，以新增递归 `JSONValue: Codable` 的 object/array/string/number/bool/null 案例承载完整 JSON，而不是只解码少量已知字段。补齐 TaskRun 的 CodingKeys、自定义 decode、encode 和现有便捷 initializer 默认 nil 参数，保证 round-trip 保留字段。目标/结果显示只读新字段；effectiveGoal/effectiveConclusion 的原文/summary 回退不能再供新视图使用。`TelemetryQueryEngine.enrichRunIfNeeded` 只能补 skills/tools/trajectory/logs，不能再从整份 transcript 的最后 assistant 补 `summaryInfo.goal/conclusion`。

- [ ] **Step 3: 让 watcher、IPC 和 query 只读完整发布。** `TelemetryWatcher` 与 `IPCServer` 收到目录/IPC 更新时重新读取 `last.json`，无 publication 或 revision 已处理则不更新 UI；IPC 丢失时目录 watcher 可恢复。历史查询排除 `publication_required=true` 且无 publication 的新 run；旧的已结束 run 继续可浏览，缺目标/结果显示“未记录”，运行中旧 run 不作为完成详情。普通 revision 更新只刷新，不自动展开；首次收到新完成轮次才按现有通知设置展开，恢复/启动读取不重复提醒。

- [ ] **Step 4: 实现 macOS 原生视觉与操作保留。** 用新 `VisualEffectBackground` 包装 `NSVisualEffectView`（`material` 与 `blendingMode` 明确设置），文本卡片使用足够实的底色；保留约 384px 宽度、拖动、吸附、收起/展开、多屏、键盘和 VoiceOver。详情默认折叠，长目标/结果可展开；Inspector 顺序为目标→结果→耗时/token/参与者事实→折叠执行详情。保留四 tab、更多、pin/collapse/switch/history/copy 等现有动作。账户移除五小时 UI 的所有入口，但不删 `QuotaWindow` 底层字段或统计采集。

五小时过滤覆盖 `SummaryView`、`HistoryView` 的 `QuotaWindowsView` 和 `AccountView`：仅在展示投影中过滤 `windowDurationMins == 300` 的窗口，不能删除未知窗口、其他周期和原始额度数据。中文/英文均不出现五小时行、卡片、进度条或提示。`TurnDetailView` 同时服务任务与历史详情，复制摘要也使用本轮新字段。

```swift
// VisualEffectBackground.makeNSView：正常材质；减少透明度时由外层改用不透明颜色。
let view = NSVisualEffectView()
view.material = .hudWindow
view.blendingMode = .behindWindow
view.state = .active
return view
```

- [ ] **Step 5: 运行 Swift 纯模型/query 测试和真机检查。**

```bash
set -euo pipefail
FLOW_BUILD_ROOT="$(mktemp -d)"
trap 'rm -rf "$FLOW_BUILD_ROOT"' EXIT
export CODEX_HOME="$FLOW_BUILD_ROOT/codex-home"
rtk proxy swiftc \
  apps/macos-overlay/Sources/Models/TelemetryData.swift \
  apps/macos-overlay/Sources/Services/TelemetryQueryEngine.swift \
  apps/macos-overlay/Tests/TelemetryTurnContextTests.swift \
  -o "$FLOW_BUILD_ROOT/telemetry-turn-context-tests"
rtk proxy "$FLOW_BUILD_ROOT/telemetry-turn-context-tests"
rtk proxy bash apps/macos-overlay/build.sh
```

真机检查默认材质、系统“减少透明度”、系统“减少动态效果”、长文本、小屏、多屏、键盘焦点和 VoiceOver；这一步只在 Task 5 仿真已确认后执行。

### Task 7: 安装、打包与 Windows CLI 兼容验收

**Files:**
- Modify: `tests/smoke.sh`（临时安装后断言新 `telemetry_core` 模块、模板指令和 CLI 可用）
- Create: `tests/turn-context-install.sh`
- Create: `tests/turn-context-install.ps1`
- Modify: `tests/telemetry.sh`（纳入 Task 1/2/3/4 单测和 shell 验收）
- Modify: `.github/workflows/ci.yml`（Linux/Windows 执行新增测试）
- Modify: `docs/telemetry.md`, `docs/telemetry.en.md`, `docs/overlay.md`, `docs/overlay.en.md`（记录字段、兼容性状态、平台范围与 Windows 材质降级规范）
- Verify without changing: `install.sh:284-288`, `install.ps1:280-285`, `MANIFEST.in`, `setup.py`, `scripts/package-release.py`

**Interfaces:**
- Consumes: Task 1–6 的 Python 模块、模板和 Swift build output。
- Produces: 临时 `CODEX_HOME` 的 POSIX/Windows 安装可用证据；不增加运行时依赖，安装复制整个 `scripts/telemetry_core`，OTA/PyPI 收集目录时包含新模块。

- [ ] **Step 1: 保持安装器的目录复制策略。** 不新增脆弱的单文件拷贝清单；确认现有 `install.sh`/`install.ps1` 的递归复制已包含 `turn_context.py`、`turn_result.py`、`publication.py`，`MANIFEST.in`/`setup.py`/`package-release.py` 的目录收集已包含它们。若校验发现打包遗漏，只改对应测试/打包配置并保留 Python 3.8 兼容。

- [ ] **Step 2: 运行 POSIX 隔离安装和 CLI。**

```bash
set -euo pipefail
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
export CODEX_HOME="$TMP_HOME/codex-home"
export CODEX_FLOW_BIN_DIR="$TMP_HOME/bin"
export CODEX_FLOW_SHELL=none
rtk proxy bash install.sh >/dev/null
rtk proxy test -f "$CODEX_HOME/codex-flow/telemetry_core/turn_context.py"
rtk proxy python3 "$CODEX_HOME/codex-flow/telemetry.py" context --help
rtk proxy bash tests/turn-context-install.sh
```

`turn-context-install.sh` 必须验证 telemetry 关闭时没有 sidecar/run/last/IPC 写入，并验证安装副本与仓库副本的 CLI 输出一致。

- [ ] **Step 3: 运行 Windows 兼容脚本。** `tests/turn-context-install.ps1` 用 `[System.IO.Path]::GetTempPath()` 下的临时 `CODEX_HOME`，调用 `install.ps1` 后通过 `python3` 运行 `telemetry.py context write-goal/write-plan`，检查 UTF-8、多语言文本、幂等 revision 和结构化错误；不调用 macOS binary、不写用户 profile、自启动或真实 home。

- [ ] **Step 4: 在临时 `CODEX_HOME` 构建 macOS binary。** `build.sh` 会同步 `CODEX_HOME/codex-flow/bin`，因此始终显式传临时 home；构建输出若写回仓库 `apps/macos-overlay/bin`，只保留构建需要的现有行为，不把开发者已安装 binary 当测试目标。

### Task 8: 端到端发布门与最终回归

**Files:**
- Modify: `tests/telemetry-core.sh`, `tests/telemetry-repair.sh`, `tests/telemetry.sh`
- Modify: `.github/workflows/macos-overlay.yml`
- Create: `tests/fixtures/turn-context/e2e-two-chats.jsonl`

**Interfaces:**
- Consumes: 所有前置任务的固定接口和已确认的真实宿主 fixture。
- Produces: 可复核的本期验收记录；真实宿主绑定不通过时结论必须标记兼容性阻塞，不能用单元测试替代支持声明。

- [ ] **Step 1: 用 e2e fixture 验证关键场景。** 顺序执行两个 chat 各两轮、两个 chat 并行、确认承接上下文、重复/乱序 Stop、迟到 worker、锁超时、IPC 丢失、写 run 后崩溃恢复；检查用户原文逐字保持、轮次目标/结果不串、publication revision 去重、last 稳定排序和无重复完成提醒。

- [ ] **Step 2: 分别验证两个开关。** 覆盖 UserPromptSubmit、SubagentStart、SubagentStop、父 Stop、write-goal、write-plan、repair、recover-last 和 IPC 各入口；测试对完全空目录与已有历史两种初始状态都成立。 `telemetry.enabled=false` 下比较调用前后的临时 telemetry 目录文件清单、内容和 mtime（目录可以不存在），确认无本次新增或修改文件；`strategy.enabled=false` 或 bypass 下不生成伪造 direct 计划，已有历史仍能解码读取。

- [ ] **Step 3: 执行完整窄回归。**

```bash
set -euo pipefail
rtk proxy bash tests/telemetry-core.sh
rtk proxy bash tests/telemetry.sh
rtk proxy bash tests/telemetry-repair.sh
rtk proxy python3 tests/test_hook_trust.py
rtk proxy python3 tests/test_instructions.py
rtk proxy bash tests/smoke.sh
```

`.github/workflows/macos-overlay.yml` 由 macOS CI runner 执行其中的 swiftc/build/smoke steps；本地不要把 YAML 当 shell 执行，也不要直接执行其中含 LaunchAgents 的段落。

macOS CI smoke 需要沿用 workflow 的临时 `CODEX_HOME`；涉及真实 `$HOME/Library/LaunchAgents` 的自启动步骤只能在隔离 CI runner 执行，本地回归显式排除该段，避免污染用户环境。

- [ ] **Step 4: 生成父 Agent 最终复核证据。** 列出真实 host binding fixture 状态、每个验收场景的命令和结果、Swift 真机检查结果、Windows CLI 结果及任何兼容性限制。若宿主不支持 receipt 传递，发布门保持失败/未支持，UI 对该轮只显示“未记录”，禁止猜最近或唯一活动 turn。

## Self-review checklist

- [ ] 同一 chat 连续两轮和两个 chat 并行均以 `session_id + turn_id` 隔离；没有 chat 总目标或按消息数生成 turn。
- [ ] `turn_context.py`、`turn_result.py`、`publication.py` 的签名、字段名和锁顺序在所有任务中一致。
- [ ] 目标/计划写入顺序、完整 ExecutionPlan、`compiled/reused/replanned`、bypass/ledger 语义都有实现任务和测试。
- [ ] final 提取只接受指定 turn 的父 Agent final；没有使用 transcript 最后一条 assistant、commentary、worker 或用户原文兜底。
- [ ] Stop 前不发布详情；重复/乱序/迟到/锁超时/崩溃/IPC 丢失均有测试和恢复策略。
- [ ] 四 tab、更多、pin/collapse/switch/history/copy 仍在；仅删除五小时额度 UI；编排默认折叠。
- [ ] 先交付并确认绝对路径仿真，再改生产 Swift UI；Windows 只有 CLI 和视觉降级规范。
- [ ] 无占位步骤、未定义接口或依赖未声明测试框架的命令；所有命令可在临时 `CODEX_HOME` 下运行。
