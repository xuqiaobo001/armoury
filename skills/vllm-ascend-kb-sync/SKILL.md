---
name: vllm-ascend-kb-sync
description: 同步 vllm-ascend 模型部署知识库（git 拉取最新文档并重建索引）。当用户要求"更新知识库"、"同步 vllm-ascend"、"检查昇腾模型文档有没有更新"、"刷新知识库"时使用。
---

# vllm-ascend 模型部署知识库同步

知识库根目录：`/root/kb/vllm-ascend`

```
repo/        git 浅克隆的上游仓库（只读，脚本强制 hard reset 到 origin/main）
knowledge/   结构化知识层（INDEX.md / meta.json / models/*.md / hardware.yaml）
reports/     每次同步的变更报告 sync_report_*.md
scripts/     sync_kb.sh（同步入口）、build_kb.py（解析构建）
updates.log  同步日志
deployments/ 部署方案产物目录（由 vllm-ascend-deploy skill 生成）
```

## 执行步骤

1. 运行同步脚本：
   ```bash
   bash /root/kb/vllm-ascend/scripts/sync_kb.sh
   ```
   脚本行为：`git fetch --depth 1 origin main` → commit 有变化才 `reset --hard` 并重建知识层；无变化时静默退出（写 updates.log）。

2. 查看结果：`tail -5 /root/kb/vllm-ascend/updates.log`，并读取最新的
   `reports/sync_report_*.md`（按文件名时间戳取最新）。

3. 向用户汇报（中文）：
   - **无更新**：报告当前 commit、上次构建时间即可。
   - **有更新**：列出新增 / 变更 / 移除的模型；**重点高亮与 950DT、A3、A2 硬件相关的内容变化**（例如某模型文档新增了 950DT 部署章节），以及 discontinued 状态变化（模型被废弃）。
   - **失败**（如网络不通）：说明原因，建议稍后重试；不要修改本地知识层来"伪造"同步成功。

## 注意

- 不要手工编辑 `knowledge/` 下的 `INDEX.md`、`meta.json`、`models/*.md`（均为生成物）；改进提取逻辑应修改 `scripts/build_kb.py`。
- `knowledge/hardware.yaml` 是手工维护的硬件档案，同步不会覆盖它；发现文档中出现新硬件规格时，提醒用户（或经确认后）补充该文件。
