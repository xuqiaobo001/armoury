#!/usr/bin/env bash
# armoury 同步守护进程：每小时跑一次 sync.sh（Claude Code 资产 -> GitHub armoury 仓库）
# 用法: daemon.sh start|stop|status
#   启动: nohup bash /root/armoury/tools/daemon.sh start >>/root/armoury/logs/daemon.log 2>&1 & disown
set -u

REPO=/root/armoury
PIDFILE=$REPO/.daemon.pid
LOCK=$REPO/.daemon.lock
INTERVAL=3600   # 每小时

mkdir -p "$REPO/logs"

case "${1:-}" in
  start)
    # 防重复启动：flock 独占锁（仅 pidfile 无法防 pid 复用误判）
    exec 8>"$LOCK"
    flock -n 8 || { echo "daemon already running"; exit 1; }
    echo $$ > "$PIDFILE"
    trap 'rm -f "$PIDFILE"' TERM INT EXIT
    echo "[$(date -u +%FT%TZ)] daemon started pid=$$ interval=${INTERVAL}s"
    # 立即同步一次，之后按间隔循环；单次失败不退出
    while :; do
      bash "$REPO/tools/sync.sh" || true
      sleep "$INTERVAL"
    done
    ;;
  stop)
    if [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "daemon stopped"
      rm -f "$PIDFILE"
    else
      echo "daemon not running"
      exit 1
    fi
    ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "running (pid $(cat "$PIDFILE"))"
    else
      echo "stopped"
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 {start|stop|status}"
    exit 1
    ;;
esac
