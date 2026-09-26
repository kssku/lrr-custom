See https://sugoi.gitbook.io/lanraragi/dev/extending-lanraragi/index for developer guidelines, best practices and more.
Happy hacking!

---

## ⚠️ 本 fork 的硬性约定：改代码必须同步改文档

**本仓库是 [kssku/lrr-custom](https://github.com/kssku/lrr-custom)，不是官方上游。**

在提交任何改动之前，请先读 [`PROJECT.md`](PROJECT.md) —— 它是本 fork 的唯一权威项目文档。

### 提交前必做

1. 打开 `PROJECT.md` §11「文档维护契约」，确认你这次改动**涉及哪些章节**
2. **同步更新那些章节**（描述还准确吗？有新增内容吗？）
3. 更新 `PROJECT.md` §9.4 待办清单（勾掉已完成的、新增产生的）
4. 更新 `PROJECT.md` 头部「文档最后同步」时间戳
5. 若改动属于「相对官方上游的差异」，**同时更新 [`FORK_CHANGES.md`](FORK_CHANGES.md)**

### 为什么不这样做不行

本 fork 建立在几个**反直觉的实测结论**上（见 `PROJECT.md` §2.3）。例如：

- FUSE 上 `readdir` 极快，但 `stat` 慢 337 倍 —— 所以任何触发逐条 `stat` 的代码都是性能灾难
- `KEYS` 在 16 万归档下阻塞 Redis 约 2 秒 —— 所以每个 `KEYS` 调用点都要交代清楚
- 索引在 **db3** 不在 db0 —— 查错库会得出「索引不存在」的错误结论

一份过期的总纲比没有总纲更危险：**它会让人基于错误的地图做决策。**

> 文档不是事后补的，是和代码一起提交的。