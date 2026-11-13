# Armoury — Claude Code 资产库

本仓库由 `tools/sync.sh` 每小时自动镜像同步本机 Claude Code 资产（单向，本地为真源），请勿直接在远端修改。

| 目录 | 内容 | 数量 |
|---|---|---|
| `skills/` | Claude Code skills | 7 |
| `commands/` | agent / 斜杠命令定义 | 18 个 .md |
| `agents/` | subagent 定义（含本同步机制的 armoury-sync） | 1 个 .md |
| `knowledge/` | 各项目 memory 知识库 | 2 个项目 |
| `settings/` | settings.json（已脱敏: TOKEN/KEY/SECRET/PASSWORD 类值替换为 ***REDACTED***） | - |
| `tools/` | 同步脚本与守护脚本（自举入仓） | - |

**LAST_SYNC: 2026-11-13T03:02:50Z (UTC)**

## 恢复 / 重启

容器重启后恢复定时同步（克隆仓库 + 一条命令）:

```bash
git clone https://github.com/xuqiaobo001/armoury.git /root/armoury
nohup bash /root/armoury/tools/daemon.sh start >>/root/armoury/logs/daemon.log 2>&1 & disown
```

手动立即同步: 在 Claude Code 中使用 `armoury-sync` subagent, 或直接运行 `bash /root/armoury/tools/sync.sh`。

守护进程管理: `bash /root/armoury/tools/daemon.sh start|stop|status`

## 安全

- `settings.json` 中的密钥类 env 已自动脱敏; 每次提交前有密钥扫描闸门（GitHub/AWS/Slack/JWT/bigmodel 等格式）, 命中即拒绝 push。
- `~/.git-credentials`、对话记录、history 等敏感文件不在同步白名单内, 永不进仓库。
