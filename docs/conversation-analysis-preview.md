# 对话分析预览

此分支提供独立的原生预览窗口，用于试用三项能力：

- **需求提炼**：每条真实用户发言（含同轮补充）触发一次分析，参考此前会话，结果归属当前轮次，仅供展示和核对。
- **回复摘要**：主 AI 的最终回复出现后生成简短摘要，原文可以展开。
- **技能提炼**：用户点击按钮后，分析会话开始到所选轮次的内容，生成可编辑、可导出的 `SKILL.md` 草稿。

它不向主 AI 反馈分析结果，也不安装生成的技能。预览复用项目主题，但没有接入正式浮窗的目标发布流程。

## 启动

需要 macOS、Xcode、Python 3、支持本分支所用 `codex exec` 参数的 Codex CLI，以及现有 Codex 登录。首次运行或 Swift 源码变化时会构建本分支的原生程序。

从此 worktree 执行，明确指定一个 Desktop 会话文件及其 `session_meta.payload.id`：

```bash
python3 scripts/preview-analysis.py start \
  --state-dir /tmp/flowpilot-my-preview \
  --transcript /absolute/path/to/rollout.jsonl \
  --session-id SESSION_ID \
  --model gpt-5.6-luna \
  --auth-home "$HOME/.codex"
```

`--state-dir` 应为空目录或本预览已配置的目录。后续可以只传同一个目录继续：

```bash
python3 scripts/preview-analysis.py start --state-dir /tmp/flowpilot-my-preview
python3 scripts/preview-analysis.py status --state-dir /tmp/flowpilot-my-preview
python3 scripts/preview-analysis.py stop --state-dir /tmp/flowpilot-my-preview
```

关闭预览窗口也会停止该预览的后台分析。分析结果保留在私有状态目录；退出时删除临时登录凭据副本。启动器通过本地验证口令控制自身进程，不会按记录中的旧 PID 杀进程。

## 试用方法

1. 默认打开最新轮次；在左侧选历史轮次，再点“分析此轮”，可补充历史需求和摘要。
2. 在原对话继续发言，查看新需求。浏览历史时不会自动跳走，点“最新”返回最新轮次。
3. 点击“提炼技能”，等待草稿，编辑后导出。尚未结束的轮次也可以作为截止位置；模型会说明缺少的验证证据。
4. 隐私开关隐藏原文、派生文本，并禁止分析、导出等操作。**它只隐藏界面，不暂停后台分析**；需要停止时关闭窗口。

## 初版边界

- 仅验证了带稳定消息 ID、轮次 ID 和父会话标识的 Codex Desktop transcript。其他来源会显示错误，不猜测归属。
- 初次启动只自动分析最新用户消息及最新最终回复，历史内容用作上下文；不会批量补跑历史。没有最终回复就不会伪造摘要。
- 模型输入上限为 32,000 字符，截断状态会显示。分析只使用真实用户文字和主 AI 最终回复，不读取工具执行记录，所以技能里的执行证据仍需人工核对。
- 默认每个任务最多尝试两次，单次超时 90 秒；失败后由用户重试。普通重复扫描不会重复入队。进程在外部模型调用与结果保存之间崩溃时，恢复可能重新调用，不能保证服务端恰好执行一次。
- 额外分析消耗同一 Codex 账户额度。界面显示的是尝试调用次数，不是 token 数或精确费用；不会改写原来的 telemetry/goal/publication。
- 不运行安装脚本，不替换已安装应用、hooks 或全局配置。启动、停止和构建均在独立路径下进行。

## 验证

```bash
python3 -m unittest discover -s tests -p 'test_analysis_*.py'
bash tests/overlay-analysis.sh
```

Swift 测试如需指定 Xcode，可在命令前设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。测试使用临时目录、模拟模型和模拟窗口，不需要真实模型调用。
