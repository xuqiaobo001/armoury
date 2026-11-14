---
name: vllm-ascend-deploy
description: 基于 vllm-ascend 知识库生成指定模型在指定昇腾硬件（如 Atlas 950 DT / A3 / A2）上的部署方案文档与逐机部署脚本，可交付外部客户。当用户提供"模型 + 硬件 + 机器 IP"并要求部署方案、部署脚本、上线指导时使用。
---

# vllm-ascend 部署方案生成

知识库根目录：`/root/kb/vllm-ascend`（上游 `docs/source/tutorials/models/` 的结构化副本）。

**核心原则：所有部署参数必须有知识库文档出处，禁止凭记忆编造参数值。**

## 第一步：明确输入

必须确定四项：
1. **模型名**：模糊时（如 "DSV4.1 flash"）用 `knowledge/INDEX.md` 标题列匹配；仍不唯一则问用户。
2. **硬件型号**：如 Atlas 950 DT、Atlas 800 A3、Atlas 800 A2。对照 `knowledge/hardware.yaml`。
3. **机器清单**：各机 IP、哪台做 node0（对外暴露 API）。网卡名、模型权重路径等次要项未提供时用 `__REPLACE_ME__` 占位，并在方案顶部集中列出"待用户填写项"。
4. **交付对象**：内部使用 / 外部客户（外部客户需追加安全与免责章节）。

关键信息缺失（如机器数量与文档拓扑不符、硬件型号不在档案中）→ 用 AskUserQuestion 询问，不要静默假设。

## 第二步：检索知识库

1. 读 `knowledge/INDEX.md` 定位模型 → 读 `knowledge/models/<slug>.md` **全文**（含原文部署章节）。
2. 条目不存在 → 先运行 `vllm-ascend-kb-sync` skill 同步；仍无 → 如实告知该模型暂无部署文档。
3. 条目带 `discontinued` → 告知已废弃，并在 INDEX 中找替代模型推荐。
4. 注意 `950dt_status`：`planned` 表示文档明确说 950DT 支持还在规划中——必须如实转告用户，不能当作已支持。

## 第三步：硬件与拓扑映射

- **文档直接覆盖用户硬件**（文档含该硬件的镜像/权重/参数章节）→ 严格按文档对应 tab/表格，不要混用其它硬件的参数。
- **文档未覆盖用户硬件** → 查 `hardware.yaml` 同系列产品（如 950DT 与 A3 同为新一代超节点系列），基于相近系列做映射，并在方案中**显著标注"此为推断，未经官方验证"**。
- **机器数量不匹配**：文档常给多个拓扑（如 V4.1-Flash 950DT：1 节点 colocated、2 节点 PD 分离）。选与用户机器数一致的文档拓扑；若没有任何拓扑能对上 → 警告用户并给出最接近的选项，**绝不自创参数组合**。
- 厘清节点角色与启动顺序：通常 node0 对外暴露 API、其余节点 `--headless`，先启动 node0。

## 第四步：生成产物

输出目录：`/root/kb/vllm-ascend/deployments/<model>-<hardware>-<YYYYMMDD>/`

### 1. `deploy-plan.md`（中文、客户可读）

- **概述**：模型 / 硬件 / 部署形态（colocated 或 PD 分离）/ 拓扑（TP/DP/EP/PCP）/ 镜像 / 权重 checkpoint / 依据的文档 commit 链接
- **机器与角色表**：IP、NODE_RANK、角色（Prefill/Decode/API 入口）、端口
- **前置条件**：驱动与容器要求、节点间网络互通验证、共享存储、**端口清单**（API 端口、DP RPC 端口、HCCL/Mooncake 等）
- **部署步骤**：按启动顺序逐机说明（引用生成的脚本）
- **验证步骤**：`/health`、`/v1/models`、chat 冒烟（含流式）
- **注意事项与限制**：从文档 Limitations / FAQ 提取（如不支持 PD 分离、不支持 PP、draft 需 eager 等）
- **假设与待确认项**：所有推断处集中列出；占位符 `__REPLACE_ME__` 清单

### 2. `deploy_node<N>.sh`（每台机器一个）

脚本骨架（内容按文档填充）：

```bash
#!/usr/bin/env bash
# 角色: <node0 - API 入口 / node1 - headless worker>
# 启动顺序: 第 <N> 个启动（先 node0，后其余节点）
set -euo pipefail

# ===== 待确认参数（已按用户提供信息填写，__REPLACE_ME__ 处需人工确认）=====
NODE_RANK=0
NODE0_IP="x.x.x.x"
LOCAL_IP="x.x.x.x"
NIC_NAME="__REPLACE_ME__"
MODEL_PATH="__REPLACE_ME__"

# ===== 环境（严格取自知识库文档对应硬件章节）=====
export HCCL_IF_IP="$LOCAL_IP"
...

# ===== 部署（按文档：容器内 vllm serve 完整命令 / 或 docker run + serve）=====
...
```

要求：`set -euo pipefail`；命令与文档逐字对齐（含 `--additional-config`、`--speculative-config` 等 JSON 参数）；脚本内注释标明该机角色与启动顺序。

### 3. 客户交付附加项（交付对象为外部客户时）

- `deploy-plan.md` 开头加**交付说明与免责**：基于上游开源文档（附 commit 链接）生成、参数未经生产环境验证项清单。
- 安全建议：API 服务勿裸暴露公网、配置 API key / 防火墙白名单、说明各端口用途。
- 排错速查：网络不通（检查 NIC_NAME/防火墙）、权重加载失败（路径/版本）、启动卡住（看 DP 引擎加载日志）。

## 第五步：自查

生成后核对：方案与各脚本中的 **IP、NODE_RANK、TP/DP/EP 数值、镜像 tag、权重路径**完全一致；`vllm serve` 参数与知识库文档一致；无遗留 `__REPLACE_ME__` 未在"待填写项"中声明。

## 第六步：归档（推荐）

自查通过后，提示用户是否调用 `model-deploy-archive` skill 将该部署包按"场景 × 硬件"归档到 `model_deploy_house` 仓库（推理方案归 `inference/<hardware>/`）。用户同意即执行归档 skill 流程。
