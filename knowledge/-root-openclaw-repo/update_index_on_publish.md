---
name: update_index_on_publish
description: 发布新报告到 tech_reports 仓库时，同步更新根目录 README.md 索引文件
type: feedback
originSessionId: 7cc2eecf-c189-4b92-aaed-59ebcb36a47b
---
每次向 GitHub 仓库 (xuqiaobo001/tech_reports) 发布新的 markdown 报告时，必须同步更新仓库根目录的 `README.md` 索引文件，在对应分类的表格中添加新记录（序号、目录链接、简介）。

**Why:** 用户要求维护一个完整的仓库索引，方便快速浏览所有报告内容。
**How to apply:**
1. 发布新报告后，读取 `/tmp/tech_reports/README.md`
2. 根据报告主题判断所属分类（SGLang / vLLM / AI Agent / 华为云基础设施 / 华为云AI昇腾 / 开源项目分析 / 或新增分类）
3. 在对应分类表格末尾追加一行，序号接续当前最大值
4. 更新底部统计表中的报告数量
5. 提交时 commit message 包含索引更新说明
