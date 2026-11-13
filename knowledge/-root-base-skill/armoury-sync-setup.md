---
name: armoury-sync-setup
description: 本机 Claude Code 资产每小时自动镜像同步到 github.com/xuqiaobo001/armoury 的机制与运维要点
metadata: 
  node_type: memory
  type: project
  originSessionId: f292bab7-4b6d-4a64-86c7-11f18d4ab668
---

2026-11-12 搭建：Claude Code 资产（skills/commands/agents/knowledge/脱敏 settings.json）每小时自动镜像同步到公开仓库 https://github.com/xuqiaobo001/armoury（本地 /root/armoury 为唯一真源）。

- 核心：`/root/armoury/tools/sync.sh`（脱敏→镜像→密钥闸门→push）+ `tools/daemon.sh`（nohup 守护，无系统 cron）
- 手动触发：`armoury-sync` subagent（~/.claude/agents/armoury-sync.md）
- 容器无 cron/systemd；容器重启后需按仓库 README 一键重启 daemon
- 安全红线：仓库公开，settings.json 密钥已脱敏；闸门命中假密钥会 exit 2 拒绝 push——若用户问"为什么没同步"，先查 `/root/armoury/logs/sync.log` 是否有 SECRET-SCAN BLOCKED
