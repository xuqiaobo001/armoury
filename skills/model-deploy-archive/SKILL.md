---
name: model-deploy-archive
description: 将模型部署细化方案（部署文档 + 逐机脚本）按"推理/训练场景 × 硬件类型"归档到 GitHub 仓库 xuqiaobo001/model_deploy_house 并推送。当用户要求"归档部署方案"、"上传部署包到 model_deploy_house"、"把这套方案存档"时使用。
---

# 部署方案归档到 model_deploy_house

- **远端仓库**：https://github.com/xuqiaobo001/model_deploy_house.git
- **本地工作副本**：`/root/kb/model-deploy-house`（credential.helper=store 已配置推送凭证）
- **目录规范**：`<scenario>/<hardware>/<Model>-<形态>-<YYYYMMDD>/`，详细规范与 meta.yaml 模板见仓库 `README.md`（归档前先读一遍，规范以 README 为准）

## 执行步骤

1. **同步本地副本**：
   ```bash
   cd /root/kb/model-deploy-house && git pull --rebase origin main
   ```

2. **确定归档对象**：用户指定的部署包目录；未指定时默认取 `/root/kb/vllm-ascend/deployments/` 下最新的包。读包内 `deploy-plan.md` 顶部信息（模型、硬件、拓扑、来源 commit）。

3. **确定两个维度**（不明确时用 AskUserQuestion 问，不要猜）：
   - **scenario**：`inference`（推理，默认）/ `training`（训练 / RL 后训练）
   - **hardware**：映射到规范目录名——
     | 硬件 | 目录名 |
     |---|---|
     | Atlas 950 DT | `950DT` |
     | Atlas 800 A3 | `Atlas-800-A3` |
     | Atlas 800 A2 | `Atlas-800-A2` |
     | Ascend 910B | `Ascend-910B` |
     | Ascend 910C | `Ascend-910C` |
     | Atlas 300I Duo | `300I-Duo` |
     新硬件：先在仓库 `README.md` 登记命名，再建目录。

4. **归档**：
   - 目标路径：`<scenario>/<hardware>/<Model>-<形态>-<YYYYMMDD>/`（形态如 `2nodes-PD`、`1node-colocated`；日期取方案生成日）
   - 复制包内全部文件（排除 `__pycache__`、临时产物）
   - **生成 `meta.yaml`**（模板见仓库 README）：`source_commit` 从 deploy-plan.md 顶部提取；`status` 按方案性质填 `poc` / `production-ready` / `reference-only`；有官方生产建议（如"推荐 MindIE Motor"）必须写进 `notes`

5. **重建索引并推送**：
   ```bash
   python3 scripts/build_archive_index.py
   git add -A
   git commit -m "archive: <model> <hardware> <scenario> <date>"
   git push origin main
   ```
   push 失败（凭证过期/网络）→ 如实告知用户，本地 commit 保留，勿伪造成功。

6. **汇报**：给出仓库中归档路径的 GitHub 链接、INDEX.md 更新结果、方案包内待填写项（`__REPLACE_ME__`）提醒。

## 注意

- **禁止**把未完成自检（脚本语法错误、占位符未声明）的半成品归档。
- 同一方案重复归档（修订版）：覆盖同名包并在 commit message 注明 `revision:`，或按用户新日期建新包；跟随用户指示。
- 索引 `INDEX.md` 一律由脚本生成，不手工编辑。
