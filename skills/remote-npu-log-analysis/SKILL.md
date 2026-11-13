---
name: remote-npu-log-analysis
description: SSH 到远程 Linux 机器，对 ModelArts/Ascend NPU vLLM 推理集群日志（如 /mnt/sfs_turbo/logs/<workflow>/<task>/）做取证式分析，定位容器副本启动失败/崩溃原因，并产出结构化 markdown 分析报告（可选发布到 GitHub）。当用户要求"连接远程机器查日志"、"分析 XX 任务/副本失败原因"、"分析 eki35/9r7q5 之类目录的日志"、"排查 NPU/vLLM 副本故障"时使用。
---

# 远程 NPU 推理集群日志取证分析

本 skill 封装完整工作流：**SSH 连接远程机器 → 日志取证 → 根因定位 → 产出报告 →（可选）发布 GitHub**。

## 1. 输入参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| SSH_HOST | `113.46.46.163` | 远程机器 IP，用户可指定其他机器 |
| SSH_USER | `root` | 账号 |
| SSH_PASS | `Huawei@123` | 密码（用户指定其他机器时一并覆盖） |
| LOG_BASE | `/mnt/sfs_turbo/logs/` | 日志根目录 |
| TASK | （必填） | 要分析的任务目录名，如 `eki35`、`9r7q5` |

## 2. 连接与首次验证

```bash
sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 $SSH_USER@$SSH_HOST '<命令>'
```

首次连接先验证并采集环境上下文（写进报告的"背景"一节）：

```bash
hostname; uname -a; cat /etc/os-release | head -3; nproc; free -h | head -2; df -h <LOG_BASE所在盘> | tail -1
```

**注意**：所有远程命令都套一层 sshpass；日志文件很大（单文件可达 110M+），**禁止 cat 整个日志**，一律 `tail` / `grep` / `sed -n` + `cut -c1-300`（plog 单行极长，必须截断）。

## 3. 日志体系知识库（ModelArts + Ascend + vLLM PD 分离部署）

### 3.1 目录结构

```
<LOG_BASE>/<workflow_id>/<task_id>/          # 如 a35d55f779ad/eki35
├── role-0-0-0/rs.log                       # route_server（Go，负载路由，19800/ops 19810）
├── role-1-0-0/  role-1-0-1/                # prefill 实例 ×2（每实例 8 卡）
│   ├── run.log                             # vLLM 主日志（API server + EngineCore 混写）
│   ├── .__run.lock
│   └── log/
│       ├── run/plog/plog-<pid>_<ts>.log    # CANN RUNTIME 层，20M 轮转，旧轮转会被删
│       ├── run/device-<n>/device-<pid>_<ts>.log   # HCCP/HCCL/TDT 设备侧日志
│       └── debug/{plog,device-*}/...       # ⚠️ 仅错误发生时生成（见 3.3）
└── role-2-0-0/  role-2-0-1/                # decode 实例 ×2，结构同上
```

### 3.2 文件语义速查（判读关键）

| 现象 | 含义 |
|------|------|
| `debug/plog/plog-<pid>_<ts>.log` 存在 | **该 pid 进程出过错**；文件名时间戳 = **首个错误时刻**（定位故障起点的第一线索） |
| `log/run/plog/` 下 846 字节的 tiny plog | 进程（重）启动标记；**中途新增一个 = 容器重启**，文件名时间戳 = 重启时刻 |
| `device-0/` 下 ~7.6K、止于 "Start waiting event" 的小日志 | aicpu_scheduler 系统守护进程日志，**正常噪音，直接排除** |
| plog 文件 20M 一轮转、旧代删除 | **轮转 ≠ 重启**；判断进程代际要看 run.log 里 startup banner 与 MainThread PID，不能只看文件时间 |
| run.log 中段出现 `Available plugins for group vllm.platform_plugins` | **第二代进程启动点**（用 `grep -n` 拿行号，看它前一行 = 上一代的死因） |
| 多个文件的 mtime 集中在同一分钟 | 该时刻 = 进程死亡/被回收窗口 |
| role-1-0-1 的 HIXL 日志里 `local_engine:IP:port` | 该 role 的节点 IP；`remote_engine:` 是对端引擎 IP |

### 3.3 已知错误模式 → 含义对照表

| 日志特征 | 层 | 含义 |
|----------|----|------|
| `SynchronizeExecutedTask:Stream synchronize timeout` + `taskType=14 (NOTIFY_WAIT)` + `KERNEL_AICPU` | NPU RUNTIME | aicpu kernel 挂死（如 `HixlBatchGet`），通知永不到达 |
| `LatchTransferFailure` ErrorNo 103901 → 后续全 503900 | HIXL (GE) | 跨节点 KV 传输失败**已锁存**，该实例传输面永久瘫痪，无自愈 |
| `rtMemcpy execution failed, reason=driver error:internal error` / `EL0003` / `ERR00100 PTA call acl api failed` | NPU Driver | 驱动内部错误，设备栈已坏；常以 vLLM `RuntimeError ... LocalScalarDenseNpu.cpp` 形式冒出 |
| `Failed to load blocks` / `Failed to get N keys` error_codes `-704/-800/-707` | mooncake/vLLM | KV cache 加载失败的 vLLM 层表现（多为 HIXL 故障下游） |
| `EngineDeadError` / `EngineCore encountered a fatal error` | vLLM | EngineCore 致命退出；**往上翻 worker 进程的原始异常才是真根因**（API 侧 serving.py:830 的堆栈全是噪音） |
| `No available shared memory broadcast block found in 60 seconds` | vLLM 多进程 | EngineCore 启动握手失败/对端消失 → **重启未完成的标志** |
| rs.log 中 `no available prefill/decode instance found`（RouteServer.5003） | 路由层 | 实例未注册/已摘除；`grep -c` 计数即失败请求规模 |
| rs.log 无任何 instance register 记录 | 路由层 | route_server 起来后从没等到过健康实例 |
| rs.log 第 1 行时间 << 任务启动时间 | 路由层 | route_server 中途重启过（旧日志被覆盖） |
| HCCP `RsUbCtxRmemUnimport`/`RsCtxQpDestroy` 密集出现 | 设备侧 | **资源拆除 = 容器被回收**，不是新启动 |

## 4. 标准分析流程

按序执行，每步给出结论再进下一步。所有远程命令记得套 sshpass。

**Step 1 — 清点任务目录，建立文件时间线**

```bash
find <LOG_BASE>/<wf>/<task> -type f | xargs ls -lah --time-style="+%m-%d %H:%M:%S" \
  | awk '{print $5, $6, $7, $8}' | sort -k2,3
```

看两头：文件名时间戳聚集处 = 各代进程出生点；mtime 聚集处 = 死亡窗口。

**Step 2 — 验证"是否真的启动失败"（平台说的启动失败 ≠ 日志事实）**

```bash
grep -nE "Started server process|Application startup complete|Loading model weights took|init engine" <role>/run.log | head
```

若 weights 加载 + startup complete 齐全 → 是"运行期死亡后的重启未完成"，转 Step 3。

**Step 3 — 找死亡现场：run.log 怎么结束的**

```bash
for r in role-1-0-0 role-1-0-1 role-2-0-0 role-2-0-1; do echo "## $r"; tail -6 $r/run.log | cut -c1-280; done
```

判读：health 200 到最后一行 = 被外部杀；戛然而止无堆栈 = 挂死/被杀；有 shutdown 序列 = 主动退出。

**Step 4 — 若发生过重启：定位代际边界，看上一代死因**

```bash
grep -n "Available plugins for group" <role>/run.log | tail -1   # 第二代启动行号 N
sed -n "$((N-80)),$((N-5))p" <role>/run.log | grep -E "ERROR|Traceback|EngineDead" | grep -vE "serving.py|async for|raise output" | cut -c1-300
```

过滤 API 侧堆栈噪音，抓 worker/EngineCore 进程的原始异常（如 rtMemcpy、driver error）。

**Step 5 — 读 debug 转储：NPU 层错误起点**

```bash
ls -la <role>/log/debug/plog/          # 文件名时间戳 = 首错时刻
head -30 <最小的一个>.log | cut -c1-270 # 头几行就是原始错误链
```

重点抓：stream sync timeout 的 device_id/stream_id/kernel 名、local_engine/remote_engine IP 对。

**Step 6 — rs.log：路由层视角**

```bash
head -1 role-0-0-0/rs.log                       # 起始时间 vs 任务启动时间
grep -cE "no available (prefill|decode) instance found" role-0-0-0/rs.log
grep -iE "register" role-0-0-0/rs.log | grep -viE "metrics|Proxy|appliers" | head
grep -nE "restart|crash|unhealthy|exit" role-0-0-0/rs.log | tail -20
```

**Step 7 — 跨任务/跨副本关联（关键！同窗故障 = 集群级事件）**

对比多个任务目录的：致命错误时刻（精确到毫秒）、故障节点 IP、故障层。若不同任务在秒级窗口内死于同类 NPU 底层错误 → 判定共享基础设施（HIXL/UB 网络、mooncake、驱动）故障，而非单副本问题。注意对端 remote_engine IP 可能属于另一个任务，需反查归属。

**Step 8 — 汇总输出报告**（模板见下节），如需发布调用 `report-publisher` skill。

## 5. 报告模板

文件名建议：`<主题>_analysis.md`，结构：

```markdown
# <系统> 故障分析报告（<任务1> / <任务2>）
> 分析日期 / 分析对象与日志路径 / 集群形态（软件栈版本、模型）/ 一句话部署架构

## 0. 背景与 TL;DR
平台现象 + 核心结论（每个任务一句话：不是没启动，而是 XX 死亡 + 重启未完成）

## 1. 集群与日志结构速览
目录树 + role 表 + 节点 IP 清单

## 2~N. 每个任务一节
### 结论（一段话）
### 时间线（markdown 表：时间 | 事件 | 证据文件/行号）
### 根因链（ASCII 缩进树：底层 → 上游连锁）
### 关键判据（为什么排除其他解释、已排除的干扰项）

## 关联分析（多任务时）
对比表：首发故障 / 致命时刻（精确到毫秒，标出间隔）/ 故障层 / 结局 → 集群级判定

## 建议与后续动作
按优先级编号：驱动/固件日志排查（给出具体节点 IP）、网络链路、给厂商提工单（附证据）、平台摘除策略改进

## 附录 A：分析命令   ## 附录 B：证据文件索引（表：证据 | 文件路径[:行号]）
```

**报告红线**：证据必须带文件路径（可加行号）；时间精确到毫秒；**绝不写入 SSH 密码/token 等敏感信息**；区分"日志事实"与"推断"（推断标注理由）。

## 6. 发布（可选）

用户要求上传时，调用 `report-publisher` skill：仓库 `xuqiaobo001/tech_reports`，报告放 `<name>/<name>/README.md`，commit 格式 `docs: add <name> report`。发布前 grep 检查报告不含密码/token。
