---
name: sglang-bench
description: 使用 sglang benchmark.serving 对 LLM 推理服务端点（vLLM / sglang / TRT-LLM / PD 分离 router）做性能压测：吞吐/TTFT/ITL/TPOT 测量、共享前缀复现压测、goodput SLO 容量扫描、冷热前缀对比。当用户要求"压测/性能测试/benchmark 模型服务"、"测 TTFT/吞吐"、"复现 KV 传输故障场景"、"找部署最大容量"时使用。
---

# sglang bench serving 压测技能

用 `python3 -m sglang.benchmark.serving` 作为**后端无关的 HTTP 压测客户端**。本机已装好（sglang 0.5.23 + torch 2.14.1+cpu），直接用。

## 前置检查（每次先做）

```bash
# 1. 确认工具可用
python3 -m sglang.benchmark.serving --help >/dev/null 2>&1 && echo OK

# 2. 确认目标端点可达（本分析机到不了 192.168.x 集群时，提示用户在客户端机执行）
curl -s -m 3 http://<host>:<port>/v1/models | head -c 300
```

**网络限制**：若本机不可达目标端点，把命令给用户让其到客户端机（如 192.168.0.35）执行；其他机器安装见文末"安装配方"。

## 后端选择

| 目标端点 | --backend | 路由 |
|---|---|---|
| vLLM / vLLM PD router（chat 接口） | `vllm-chat` | POST /v1/chat/completions |
| vLLM completions | `vllm` | POST /v1/completions |
| sglang 原生 | `sglang` | POST /generate |
| sglang chat | `sglang-oai-chat` | POST /v1/chat/completions |
| TRT-LLM | `trt` | /v2/models/ensemble/generate_stream |

`--model` 可省略（自动查 GET /v1/models）。认证：`export OPENAI_API_KEY=...`。

## 场景配方

### A. PD 分离共享前缀复现压测（对应 GLM-5.3-Flash PD 故障验证）

复现"共享长前缀 + 高并发"触发 Mooncake KV 传输块配对错位的场景：

```bash
python3 -m sglang.benchmark.serving \
  --backend vllm-chat --base-url http://<router>:8081 --model glm \
  --dataset-name generated-shared-prefix \
  --gsp-num-groups 1 --gsp-prompts-per-group 200 \
  --gsp-system-prompt-len 250000 --gsp-question-len 200 --gsp-output-len 256 \
  --num-prompts 200 --max-concurrency 15 \
  --output-file gsp_pd.jsonl --output-details
```

- 必须**持续 30 分钟以上**（原故障在缓存热身后 ~11 分钟才触发），加大 num-prompts 或多轮跑
- 验证标准：D 节点 `grep -c "memory is not registered" d0.log` 为 0，且 JSONL 的 `errors` 数组为空
- 热点分布模拟：`--gsp-group-distribution zipf --gsp-zipf-alpha 1.2`
- 多轮对话形态：`--gsp-num-turns N`（新版本支持）

### B. 基线吞吐/延迟测试

```bash
python3 -m sglang.benchmark.serving \
  --backend vllm-chat --base-url http://<host>:<port> --model glm \
  --dataset-name random --random-input-len 4096 --random-output-len 512 \
  --random-range-ratio 0.5 --num-prompts 300 \
  --request-rate 8 --max-concurrency 32 \
  --output-file baseline.jsonl --output-details
```

### C. goodput / SLO 容量扫描

对 request-rate 逐档扫（如 2/4/8/16/32），goodput 峰值即 SLO 内真实容量：

```bash
for RATE in 2 4 8 16 32; do
python3 -m sglang.benchmark.serving \
  --backend vllm-chat --base-url http://<host>:<port> --model glm \
  --dataset-name random --random-input-len 4096 --random-output-len 512 \
  --num-prompts 200 --request-rate $RATE \
  --goodput ttft:30000 tpot:100 e2el:120000 \
  --output-file sweep_r${RATE}.jsonl
done
```

- SLO 单位毫秒；256K 长请求的 ttft SLO 要放宽（P 侧 prefill 256K 实测 ~22s）
- 输出含 Request goodput (req/s)、SLO attainment (%) 及每项 SLO 的绑定项

### D. 冷/热前缀对比（量化 prefix cache 收益）

```bash
# 冷态：vLLM 服务端须以 VLLM_SERVER_DEV_MODE=1 启动，否则脚本故意报错
... --flush-cache    # vLLM 调 /reset_prefix_cache; sglang 调 /flush_cache
# 热态：不加，跑两遍取第二遍结果
```

### E. 多模态压测

```bash
... --dataset-name image --image-count 3 --image-resolution 720p \
    --random-input-len 512 --random-output-len 512 --apply-chat-template
# 自定义分辨率 512x768；--image-format png --image-content blank
```

## 结果分析

```bash
# 汇总每轮的关键指标
python3 -c "
import json,sys
for f in sys.argv[1:]:
    d=json.loads(open(f).read().strip().splitlines()[-1])
    print(f, '| req/s %.1f | out tok/s %.0f | TTFT p50/p99 %.0f/%.0f ms | ITL p99 %.1f ms' % (
        d.get('request_throughput',0), d.get('output_throughput',0),
        d.get('median_ttft_ms',0), d.get('p99_ttft_ms',0), d.get('p99_itl_ms',0)))" *.jsonl

# 失败请求明细（复现压测必查）
python3 -c "
import json; d=json.loads(open('gsp_pd.jsonl').read().strip().splitlines()[-1])
errs=[e for e in d.get('errors',[]) if e]
print('失败请求数:', len(errs)); [print(e[:200]) for e in errs[:5]]"
```

## 压测后健康检查（PD 分离场景）

```bash
# D 节点：KV 传输失败计数（应为 0）
grep -c "memory is not registered" d0.log
# 功耗超限采样（应无输出）
awk -F, 'NR>1 && $4+0>800' /root/npu_monitor/npu_*.csv
```

## 陷阱清单

- `--fake-prefill`、`--profile` 仅对 **sglang 服务端**有效，vLLM 目标勿用
- `--flush-cache` 对 vLLM 要求服务端 `VLLM_SERVER_DEV_MODE=1`
- `--tokenize-prompt` 仅 `--backend sglang`
- 长上下文压测确认服务端 `max-model-len` ≥ input+output（如 307200）
- 客户端高并发时脚本自动提升 RLIMIT_NOFILE，无需手动 ulimit

## 安装配方（其他机器复刻）

```bash
pip install --break-system-packages sglang==0.5.23 \
  "torch==2.14.1" "torchvision==0.29.1" --index-url https://download.pytorch.org/whl/cpu  # 无GPU机用cpu源; GPU机去掉index-url
pip install --break-system-packages "transformers==5.19.0" "tokenizers==0.23.2" \
  orjson psutil msgspec zmq ipython triton sentencepiece compressed_tensors gguf \
  apache-tvm-ffi "python-dateutil<3" aiohttp numpy requests tqdm datasets pillow pybase64
```

关键坑：`import tvm_ffi` 对应的 pip 包名是 **apache-tvm-ffi**（不是 tvm-ffi）；torch/torchvision 必须配套版本否则 `torchvision::nms does not exist`；sglang 0.5.23 对 transformers/tokenizers 版本强校验。
