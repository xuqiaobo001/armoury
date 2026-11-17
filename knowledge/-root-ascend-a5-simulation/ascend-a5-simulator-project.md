---
name: ascend-a5-simulator-project
description: ascend_a5_simulation 项目——Roofline+并行策略寻优的训练/推理性能仿真器，架构与状态
metadata: 
  node_type: memory
  type: project
  originSessionId: 59c4e000-d8bf-4612-9008-4a3ce085c3d9
---

用户在 /root/ascend_a5_simulation 构建昇腾 A5（Atlas 950 量级）LLM 性能仿真器，2026-11-17 完成首个可用版本（纯 Python stdlib，零依赖，CLI 是 run.py）。

**Why:** 用户要做训练/推理性能仿真与并行策略寻优；仿真器定位为"策略排序器"（Spearman>0.9 优先于绝对精度），不是精确计时器。

**How to apply:** 三层架构：cost_model（Roofline 单算子，η 按 m 查曲线）→ train_sim（1F1B 事件仿真+显存过滤）/ infer_sim（continuous batching 离散事件）→ search（L1 粗排+top-k L2 精算）。hw_profiles/*.json 全是占位参数，上线前必须用 calib/ 微基准（torch_npu GEMM sweep、HCCL 带宽）回填，验收标准 MAPE<15%。已知简化记录在 README 第 5 节（vPP/CP/MoE 负载不均/FP8 效率曲线等未建模）。
