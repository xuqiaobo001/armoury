#!/usr/bin/env bash
# armoury 同步脚本：把 Claude Code 资产镜像同步到 GitHub armoury 仓库（单向，本地为真源）
# 流程: 互斥锁 -> 脱敏 settings.json -> 镜像复制 -> 白名单 git add -> 无变更跳过
#       -> 生成 README -> 密钥扫描闸门 -> commit -> push
# 退出码: 0=成功/无变更  1=网络或环境错误  2=密钥扫描拦截  3=settings.json 损坏(已降级继续)
set -euo pipefail

REPO=/root/armoury
CLAUDE=/root/.claude
LOG=$REPO/logs/sync.log
mkdir -p "$REPO/logs"

# ---- 日志轮转: >512KB 时 gzip 压缩保留一份 ----
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG")" -gt 524288 ]; then
  gzip -f "$LOG"
fi

log() { echo "[$(date -u +%FT%TZ)] $*" >> "$LOG"; }

# ---- 互斥锁: daemon 与手动触发并发时, 后到者直接跳过 ----
exec 9>"$REPO/.sync.lock"
flock -n 9 || { log "another sync running, skip"; exit 0; }

# ---- 1. 脱敏 settings.json (python3, jq 不可用) ----
# 按 key 名匹配 TOKEN/KEY/SECRET/PASSWORD/CREDENTIAL, 值替换为 ***REDACTED***;
# BASE_URL / 模型名等非敏感配置保留, 便于在新机器恢复配置。
mkdir -p "$REPO/settings"
if [ -f "$CLAUDE/settings.json" ]; then
  if ! python3 - "$CLAUDE/settings.json" "$REPO/settings/settings.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    d = json.load(f)
SENSITIVE = ("TOKEN", "KEY", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL")
def scrub(obj):
    if isinstance(obj, dict):
        return {k: ("***REDACTED***" if any(s in k.upper() for s in SENSITIVE) else scrub(v))
                for k, v in obj.items()}
    if isinstance(obj, list):
        return [scrub(x) for x in obj]
    return obj
with open(dst, "w") as f:
    json.dump(scrub(d), f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
  then
    log "WARN: settings.json 读取/解析失败, 保留仓库中的旧脱敏版本"
    code=3
  fi
fi

# ---- 2. 镜像复制 (整目录重建, 资产总量 <1M, 本地删除 => 远端删除) ----
mirror_dir() { # mirror_dir <src> <dst>  src 不存在时删掉 dst
  local src=$1 dst=$2
  rm -rf "$dst"
  [ -d "$src" ] && cp -a "$src" "$dst"
}
mirror_dir "$CLAUDE/skills"   "$REPO/skills"
mirror_dir "$CLAUDE/commands" "$REPO/commands"
mirror_dir "$CLAUDE/agents"   "$REPO/agents"

# knowledge/: 各项目 memory/, 仅同步非空项目, 整体重建以支持项目级删除
rm -rf "$REPO/knowledge"
mkdir -p "$REPO/knowledge"
for m in "$CLAUDE"/projects/*/memory; do
  [ -d "$m" ] || continue
  [ -n "$(ls -A "$m" 2>/dev/null)" ] || continue
  cp -a "$m" "$REPO/knowledge/$(basename "$(dirname "$m")")"
done

# ---- 3. 白名单 git add (绝不用 git add -A; knowledge 目录名可能以 - 开头, 用 -- 分隔) ----
cd "$REPO"
git add -- skills commands agents knowledge settings tools

# ---- 4. 无变更则跳过 (README 时间戳仅在确有变更时更新, 避免空 commit) ----
if [ -z "$(git diff --cached --name-only)" ]; then
  log "no changes"
  exit 0
fi

# ---- 5. 生成 README 索引 ----
TS=$(date -u +%FT%TZ)
NSKILL=$(find "$REPO/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
NCMDF=$(find "$REPO/commands" -name '*.md' 2>/dev/null | wc -l)
NAGENT=$(find "$REPO/agents" -name '*.md' 2>/dev/null | wc -l)
NKNOW=$(find "$REPO/knowledge" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
cat > "$REPO/README.md" <<EOF
# Armoury — Claude Code 资产库

本仓库由 \`tools/sync.sh\` 每小时自动镜像同步本机 Claude Code 资产（单向，本地为真源），请勿直接在远端修改。

| 目录 | 内容 | 数量 |
|---|---|---|
| \`skills/\` | Claude Code skills | $NSKILL |
| \`commands/\` | agent / 斜杠命令定义 | $NCMDF 个 .md |
| \`agents/\` | subagent 定义（含本同步机制的 armoury-sync） | $NAGENT 个 .md |
| \`knowledge/\` | 各项目 memory 知识库 | $NKNOW 个项目 |
| \`settings/\` | settings.json（已脱敏: TOKEN/KEY/SECRET/PASSWORD 类值替换为 ***REDACTED***） | - |
| \`tools/\` | 同步脚本与守护脚本（自举入仓） | - |

**LAST_SYNC: $TS (UTC)**

## 恢复 / 重启

容器重启后恢复定时同步（克隆仓库 + 一条命令）:

\`\`\`bash
git clone https://github.com/xuqiaobo001/armoury.git /root/armoury
nohup bash /root/armoury/tools/daemon.sh start >>/root/armoury/logs/daemon.log 2>&1 & disown
\`\`\`

手动立即同步: 在 Claude Code 中使用 \`armoury-sync\` subagent, 或直接运行 \`bash /root/armoury/tools/sync.sh\`。

守护进程管理: \`bash /root/armoury/tools/daemon.sh start|stop|status\`

## 安全

- \`settings.json\` 中的密钥类 env 已自动脱敏; 每次提交前有密钥扫描闸门（GitHub/AWS/Slack/JWT/bigmodel 等格式）, 命中即拒绝 push。
- \`~/.git-credentials\`、对话记录、history 等敏感文件不在同步白名单内, 永不进仓库。
EOF
git add -- README.md

# ---- 6. 密钥扫描闸门: 对 staged 新增行匹配真实密钥形态 ----
# 只匹配"固定前缀 + 足够长随机串", 不匹配裸词 token/password (skills 文档中提及规范文字不误伤)。
SECRET_RE='ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|\bsk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[baprs]-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{20,}\.|[a-f0-9]{32}\.[A-Za-z0-9_-]{16,}'
ADDED=$(git diff --cached --unified=0 | grep '^[+]' | grep -v '^[+][+][+]' || true)
if [ -n "$ADDED" ] && printf '%s\n' "$ADDED" | grep -qE "$SECRET_RE"; then
  NHIT=$(printf '%s\n' "$ADDED" | grep -cE "$SECRET_RE" || true)
  git reset --quiet
  log "SECRET-SCAN BLOCKED: $NHIT suspicious line(s) in files: $(git diff --name-only HEAD 2>/dev/null | tr '\n' ' ')"
  log "SECRET-SCAN BLOCKED: push 已拒绝, 请移除密钥后重试"
  exit 2
fi

# ---- 7. commit + push ----
NFILES=$(git diff --cached --name-only | wc -l)
COMMIT=$(git commit -q -m "sync: $TS ($NFILES files)" && git rev-parse --short HEAD) || { log "WARN: nothing to commit"; exit 0; }

if git push -q origin main 2>>"$LOG"; then
  log "pushed $COMMIT ($NFILES files)"
else
  log "push failed, retry with fetch + force-with-lease (mirror semantics: local wins)"
  git fetch origin 2>>"$LOG" || { log "ERROR: network unreachable, will retry next round"; exit 1; }
  git push --force-with-lease -q origin main 2>>"$LOG" || { log "ERROR: force push failed, will retry next round"; exit 1; }
  log "force-pushed $COMMIT ($NFILES files)"
fi

exit ${code:-0}
