# lrr-custom —— 相对官方上游做了什么

> 📖 **先读 [`PROJECT.md`](PROJECT.md)** —— 那是本 fork 的唯一权威项目总纲（架构 / 数据流 / 部署 / 运维 / 待办）。
> 本文档是 PROJECT.md §5「核心改造点」的展开细节，专注回答「**相对官方上游改了什么**」。
>
> 分两部分：**(A) 已提交到 Git 的代码改动**、**(B) 部署层面的配置与运维改动**。
>
> ⚠️ 改动代码时，**本文档与 `PROJECT.md` 必须同步更新**（见 `PROJECT.md` §11）。

---

## 背景：为什么需要这个 fork

库规模为**十万级归档**，内容存放在**网盘映射出的 FUSE 目录**（容器内只读挂载）。

上游设计假设在这个场景下失效：

| 上游假设 | 本场景现实 | 后果 |
|---|---|---|
| `compute_id` 读文件内容算 SHA-1 | FUSE 上每个文件读 512KB ≈ **数百毫秒** | 全库扫描**数十小时** |
| `KEYS` 全库扫描可接受 | 十万级 ID 键 / 数十万索引键 | 单次请求**数秒到数十秒** |
| Shinobu 文件监听可用 | FUSE 遍历会卡死 | 服务不可用 |
| ID 用镜像内绝对路径哈希 | 换机器/换挂载点 | **全库 ID 失效** |

**改造目标：让十万级库在 FUSE 存储上可用。**

---

## (A) Git 提交的代码改动

以下提交全部由本 fork 作者提交。

### 1. 大库性能改造（4 个补丁）

**核心提交**，针对 FUSE 存储的三大痛点。

#### 1.1 `compute_id` 改为路径哈希，不再读文件内容

- 上游读文件内容算 SHA-1（FUSE 上数百毫秒/文件）
- 改为只哈希文件路径（微秒级）
- 路径 UTF-8 编码后 SHA-1，非 ASCII 文件名结果一致

> 注：此提交时哈希的仍是**绝对路径**；相对路径化见第 7 节。

#### 1.2 搜索缓存软失效 + 条目级时间戳校验

- `invalidate_cache` 不再 `DEL` 整个 `LRR_SEARCHCACHE`
  - 上游有 30+ 调用点，Shinobu 每个文件触发 4 次，**导致缓存永远积累不起来**
- 改为 bump `created` 标记；条目写入时带 `created`，命中时比对
- 效果：缓存可累积（实测 4 条共存，上游永远 1-2 条）
- **逃生开关**：`LRR_SEARCHCACHE_HARD_INVALIDATE=1` 恢复上游行为

#### 1.3 两处 `KEYS` 全库阻塞扫描改为增量操作

| 位置 | 上游 | 本 fork |
|---|---|---|
| `Search.pm:168` | `KEYS('???…40个?')` | `zrangebylex LRR_TITLES` |
| `Search.pm:326` | `KEYS('INDEX_*…')` | `SCAN` 游标循环 |

消除对十万级 ID 键 / 数十万索引键的 O(N) 阻塞。

#### 1.4 恢复 `LRR_DISABLE_SHINOBU` 开关

- 上游 dev 版**无条件启动 Shinobu**（文件监听）
- 恢复该环境变量开关，避免在网盘 FUSE 上遍历卡死
- **后续进展**：`readdir` 扫描替代 `File::Find` 后（见 §9），Shinobu 在 FUSE 上已可用，
  因此当前部署改为 **`LRR_DISABLE_SHINOBU=0`（启用）**，并用 `LRR_SHINOBU_WATCH_DIRS` 限定作用域。
  该开关保留的意义是「FUSE 异常时的逃生通道」，而非常态关闭。

**实测效果（十万级库）：**

| 指标 | 改造前 | 改造后 |
|---|---|---|
| 首次搜索 | 数十秒 | **十几秒** |
| 缓存命中 | — | **亚秒级** |
| 数据变更后重新命中 | — | **亚秒级** |
| 缓存条目共存 | 1-2 条 | **4 条** |

---

### 2. `/api/archives` 增加 `start` 分页参数

- 新增可选 `start` 参数，实现服务端分页
- `Model/Archive.pm` 新增分页下推函数
- 同步更新 `tools/openapi.yaml`

**动因**：上游 `/api/archives` 无分页，十万级库上单次要枚举全部 ID。

---

### 3. 用 `arcids_idx` zset 替代 `KEYS` 做分页

**分页性能的关键提交。**

- 上游：`generate_archive_list` 每次请求 `KEYS '????…'`（十万级键扫描），耗时秒级 + 数 MB 传输
- 本 fork：读 `arcids_idx` zset（`ZRANGE`）
- 新增 `arcids_idx`（db0）作为分页索引，**单调递增 score，永不复用** → 翻页顺序稳定
- `add_archive_to_redis` / `delete_archive` / `change_archive_id` 三者同步维护该索引
- **索引缺失时自动回退 `KEYS` 并就地重建索引** → 全新部署自愈，无需手工迁移
- 新增脚本：`script/migrate_arcids.pl`（幂等，支持 dry-run）、`script/bench_arcids.pl`、`script/bench_http.pl`
- `public/js/batch.js` 改为逐页拉取 `?start=N`

> **重要约束**：索引**不能**命名为 `LRR_*` 前缀 —— Minion 会 MOVE-drain 该前缀的键。

**实测效果（十万级库）：**

| 请求 | 改造前 | 改造后 |
|---|---|---|
| `?start=0` | 秒级 | **亚秒级** |
| 中间页 | 秒级 | **亚秒级** |
| 末页 | 秒级 | **亚秒级** |

---

### 4. 分类页前端分页 + 补齐 i18n 词条

**问题**：分类页原先服务端一次性渲染全部归档 `<li>` —— 十万级 ≈ **十几 MB / 分钟级**。

- `Controller/Category.pm`：不再调用 `generate_archive_list()`，`arclist` 传空
- `public/js/category.js`：新增递归分页加载 / `finishArchiveList` / `applyCategoryChecks`
  - 同时修复上游「一次性回填会静默漏勾」的 bug
- `templates/category.html.tt2`：改为 loading 占位符
- `templates/i18n.html.tt2` + `locales/template/{en,zh}.po`：补 `Loading archives...` 等词条
  - （服务端 `c.lh()` 走 `.po` 词表，缺词会刷 Maketext error）

**验证**：浏览器级 DOM 断言 PASS —— 批量归档数秒加载完毕，首/中/末 checkbox 均 checked，前端 0 错误。

---

### 5. `/api/archives` 省略 `start` 时返回首页

**问题**：上游省略 `start` 返回**全量**。十万级库上这条路径要**数十秒**，远超 prefork 的 50s `heartbeat_timeout`，**会让 worker 被判死并重启**。

- 改为与 `/api/search` 同一套语义：省略 `start` 即分页（`$start || 0`），全量须显式传 `start=-1`
- 同步更新 `tools/openapi.yaml`

**影响面已核实**：仓库内 `batch.js` / `category.js` 都显式传 `?start=N`，无裸调用。

---

### 6. 新增 `arcids_idx` 一致性自检脚本

**为什么需要**：分页依赖 `arcids_idx` 与真实归档集合一致。一旦漂移，分页会**静默漏归档或重复，而 HTTP 响应仍然 200 + 格式正确，日志里什么都看不到**。

**关键洞察**：只比数量不够 —— 陈旧条目 +1、漏建 −1 会让 `ZCARD` 看起来完全正常（**实测中就是这样**）。

检查四项：

1. 集合双向差集（索引独有 = 陈旧；归档独有 = 漏建）
2. score 唯一性（重复会让 `ZRANGE` 顺序不确定）
3. score 连续性（删除只 `ZREM` 不回收序号，有洞 = 删除路径漏同步）
4. 计数器与最大 score 一致

`--fix` 只修集合成员，**刻意不重编号**（重编号会让正在翻页的客户端拿到乱序）。

**实测**：健康库 → `CONSISTENT`；注入双向漂移 → 精确定位；`--fix` → `REPAIRED`；复核 → `CONSISTENT`。
扫描用 `SCAN` 不用 `KEYS`，避免自检本身阻塞服务。

---

### 7. `compute_id` 改为哈希 `content/` 相对路径

**问题**：ID 里含镜像内绝对路径，**换机器、换挂载点、换 content 根目录时全库 ID 失效**。

```
旧: SHA1("<绝对路径>/content/<来源>/<分片>/<文件>.cbz")
新: SHA1("<来源>/<分片>/<文件>.cbz")
```

**实现**：

- 用 `LANraragi::Model::Config::get_userdir()` 取权威 content 根
  （它处理 `LRR_DATA_DIRECTORY` 覆盖，回退到 redis 的 `dirname` 配置）
- `File::Spec->abs2rel` 求相对路径后再 SHA-1
- 相对路径 UTF-8 编码后哈希，非 ASCII 文件名一致

**生产验证（十万级归档已全量迁移）**：

- db0 档案 hash / `arcids_idx` / db3 索引 / 缩略图 **四层全部对齐新 ID**
- `arcids_idx` **保 score 迁移**，分页顺序不变

---

### 8. 禁用启动时自动 `build_stat_hashes`

**问题**：十万级归档的库上，启动时 `enqueue('build_stat_hashes')` 会全量重建 db3 索引：

- 单次耗时约 **十几分钟**
- 且会**循环重跑**（重建过程中服务已在响应，触发新一轮）
- 期间 CPU 打满，服务可用性受损

**改动**：注释掉该 `enqueue`，索引变更时手动触发。

**注意**：此改动意味着「新增归档后索引不会自动更新」。若恢复 Shinobu 自动扫描，需重新评估。

---

### 9. `Shinobu` 首扫改用 `readdir`，避开 `File::Find` 的逐条目 `-d`

**问题**：`update_filemap()` 原用 `File::Find`，它对**每个条目**做一次 `-d` 判断（一次 `stat`）。
在 CloudFS 的 FUSE 挂载上，容器内经 bind mount 的元数据成本约 **31.8 ms/条目**（宿主原生 4.5 ms），
于是 26,417 文件的分片需 **14 分钟以上** —— 实测 **120 s 超时都跑不完一个分片**。

**改动**：新增 `_scan_archives()`（`lib/Shinobu.pm`），用 `readdir` 一次取全部条目名，
再用 `is_archive()` 正则判断。该正则要求以 `.<扩展名>` 结尾，**永远不匹配目录名**，
故命中即为归档、零 `stat`；仅未命中时才做一次 `-d` 决定是否递归。

**实测（容器内 / CloudFS bind mount / 2026-10-03）**：

| 方案 | `wnacg/1-50000`（26,417 文件）| 全部 20 目录（254,133 文件）|
|---|---|---|
| 旧 `File::Find`（逐条目 `-d`）| **>120 s 未完成** | 不可达（单分片即卡死）|
| 新 `_scan_archives`（`readdir` + 正则）| **6.8 s** | **55 s** |

目标库分片为扁平结构（`1-50000`、`pika/2020` 实测 0 子目录，100% 为 `.cbz`），
故新实现的 `stat` 次数为 **0**，相对旧实现 ≥17 倍提速。

**注意**：这是**单条目成本**的规避，不是挂载层修复。若目录含真实子目录树，`-d` 仍会发生（但只在目录上，不在文件上）。

---

### 10. 前端不再主动请求生成缩略图（列表页）

**问题**：`LRR_THUMBNAIL_MODE=lazy` 只关闭了**入库时**的缩略图生成，
但**浏览列表页**时前端仍会主动要求后端生成 —— 两条路互相独立，环境变量管不到后者。

```
① 浏览器打开归档列表
② 前端对当前页每个归档请求：
   /api/archives/<id>/thumbnail?no_fallback=true
③ 后端 Model/Archive.pm::serve_thumbnail 看到 no_fallback=true：
     入队 Minion thumbnail_task → 读 FUSE 网盘 → 调 libvips
④ 每翻一页，对那一页所有归档重复 ②-③
```

**后果（FUSE 场景下尤其严重）**：仅**浏览列表**就会对远程挂载发起大量读取，
正是本 fork 要消除的开销（`Model/Plugins.pm:242` 注释：
*"nothing but the reader may touch the remote mount"*）。

**改动**（去掉两处 `?no_fallback=true`）：

| 文件 | 行 | 场景 |
|---|---|---|
| `public/js/mod/index_datatables.js` | 218-219 | 表格模式，每行渲染 |
| `public/js/mod/common.js` | 357-358 | 缩略图卡片模式 |

去掉后后端走 `else` 分支，直接 `render_file ./public/img/noThumb.png`，
**零 Minion 任务、零网盘读取**。缩略图只在**打开阅读器**时生成 ——
准确地说，自第 12 节起，打开阅读器也**只生成封面**，不再生成页面缩略图。

> `public/js/mod/common.js` 该处**上游原有注释本身就写着**
> *"Don't enforce no_fallback=true here, we don't want those divs to trigger Minion jobs"*
> —— 代码与注释矛盾，本次改动**让代码符合其注释的意图**。

> 归档编辑页调用的是裸 `/api/archives/<id>/thumbnail`（不带 `no_fallback`），
> 本就不触发生成，因此该页无需改动。（旧版此处引用 `public/js/mod/edit.js`，
> 该文件已随前端重构消失，改为描述行为而非路径。）

**生效方式**：前端文件在 `Dockerfile:128` 被 `COPY /public public` 烤进镜像，
`public/` **不在 compose 挂载表中** —— 改完必须**重建镜像**才生效。

---

### 11. 坏图拦截 + 缩略图失败熔断器

**背景**：第 10 节把「浏览列表页主动要图」这条主要触发路径去掉了，
但**坏图仍会在阅读器里被触发**。而一张坏图（0 字节 / 非图片数据）会让
`extract_thumbnail` 每次都 die：

```
前端请求缩略图 → 入队 thumbnail_task → 打开 CBZ、从远端读图 → libvips die
   ↑                                                              ↓
   └──────────── 前端重试（无限循环），每次重开归档正文 ────────────┘
```

在 FUSE 挂载上，每次重试都是一个卡在远程 IO 的 **D 状态进程**，累积后拖垮容器。

> ⚠️ **重要事实**：`patch-badimage/apply2.pl` 与 `apply3.pl` 此前**从未真正生效** ——
> 它们是针对旧部署路径 `/opt/data/lanraragi/patched/` 写的脚本，且 `apply3.pl` 的
> 熔断器只有「读」没有「写」。仓库与镜像中都不存在 `is_decodable_image` / `thumbfail`
> 标记。本次将其**固化为正式代码**（提交 `48ff6caf`）。

**改动（三个文件，纯新增 85 行）**：

| # | 文件 | 改动 |
|---|---|---|
| 1 | `lib/LANraragi/Utils/Archive.pm` | 新增 `is_decodable_image()`，在 `generate_thumbnail` 送 libvips **之前**按魔术字节判定；不通过则 `die "BROKEN_IMAGE: ..."` |
| 2 | `lib/LANraragi/Utils/Minion.pm` | `thumbnail_task` 失败分支 `INCR thumbfail:<id>` + 24h TTL；成功分支 `DEL` |
| 3 | `lib/LANraragi/Model/Archive.pm` | `serve_thumbnail` 入队前读 `thumbfail:<id>`，**≥ 3 次**不再入队，直接返回 `noThumb.png` |

**`is_decodable_image` 识别的格式**（魔术字节）：

| 格式 | 特征 |
|---|---|
| JPEG | `FF D8 FF` |
| PNG | `89 50 4E 47 0D 0A 1A 0A` |
| GIF | `GIF87a` / `GIF89a` |
| WebP | `RIFF....WEBP` |
| BMP | `BM` |
| TIFF | `II*\0` / `MM\0*` |
| AVIF/HEIF | `....ftyp(avif\|avis\|heic\|heix\|mif1\|msf1)` |
| JXL | `FF 0A` |

**熔断器参数**：
- 阈值：**3 次**连续失败（`Model/Archive.pm` 中硬编码 `$thumbfail < 3`）
- 计数键：`thumbfail:<archive_id>`，位于 **db0**（`get_redis`，归档库）
- TTL：首次 `INCR` 时设 **86400 秒（24h）**，避免偶发失败永久拉黑
- 成功即 `DEL`，计数清零

**这是「事前避免 + 事后止血」两层防护**：

| 层 | 手段 | 效果 |
|---|---|---|
| 前端 | 第 10 节：不再主动要图 | 大幅减少触发量 |
| 后端 | 本节：坏图拦截 + 熔断 | 即使被触发，也会止损 |

**排查命令**：

```bash
docker exec lrr sh -c 'redis-cli -n 0 KEYS "thumbfail:*"'
```

**生效方式**：三个都是 `.pm` 后端文件，同样**不在挂载表中** —— 必须**重建镜像**。

> **第 12 节之后的变化**：本节描述的熔断器仍完全有效，但触发面进一步缩小 ——
> 打开阅读器已不再请求页面缩略图（见第 12 节），因此 `thumbnail_task` 现在只服务
> 封面这一张图。坏图拦截与熔断逻辑本身未改动。

---

### 12. 打开阅读器只生成封面（移除 MCE，修复 Minion 作业卡死）

**问题**：即使第 10、11 节已把缩略图生成收窄到「打开阅读器」这一个入口，
该入口在实际运行中**仍然会永久卡死 Minion worker**：作业停在 `active`，
`performed=0`，页面目录一个文件都不产生，归档哈希里的 `thumbjob` 字段永不被清除，
后续对该归档的请求全部被复用到一个永远不结束的旧作业 id 上。

**根因**：`Utils/Minion.pm` 的 `thumbnail_task` / `page_thumbnails` 在 Minion
**作业子进程**里初始化 `MCE::Shared`。该子进程内的 MCE 管理器握手**永远完不成**：

| 观测项 | 值 |
|---|---|
| 进程状态 | 冻结，`wchan=0`（不在任何系统调用上等待） |
| 打开的文件描述符 | 约 40 个**匿名 socket** |
| `utime` | 卡在 0.16 秒不再增长 |
| 页面输出 | 0 个文件 |
| 作业状态 | 永久 `active`，`performed=0` |

单独在容器里跑一个等价的 MCE 脚本**完全正常** —— 说明故障只在 Minion 作业
子进程这一特定环境下触发（继承的 fd / 信号 / 进程组与 MCE 管理器的握手冲突）。

**改动（`lib/LANraragi/Utils/Minion.pm`，净减 6 行）**：

| # | 改动 |
|---|---|
| 1 | 移除模块级 `use MCE::Loop;` / `use MCE::Shared;` |
| 2 | `MCE::Shared->array` → 普通 `my @errors = ()`；`$errors->push(...)` → `push @errors, ...`；`$errors->values` → `@errors` |
| 3 | 两个 `IS_UNIX` 的 `mce_loop { ... } \@keys; MCE::Loop->finish;` → 顺序 `$sub->(@keys);` |
| 4 | `find_duplicates` 的 `MCE::Shared->hash` → 普通哈希 |
| 5 | 移除 `MCE::Shared->stop;` 调用 |

**同时收窄为「只做封面」**（本次改造的实际目标）：

| 文件 | 改动 |
|---|---|
| `Utils/Minion.pm` | `page_thumbnails` 任务体不再遍历 `1..N` 页，只生成第 0 页（即封面） |
| `Model/Archive.pm` | `generate_page_thumbnails` 只检查**封面**是否存在；页面缩略图缺失**不再**触发入队 |
| `public/js/mod/reader_common.js` | 打开阅读器不再 POST `/api/archives/<id>/files/thumbnails` |
| `public/js/mod/reader_archive_overlay.js` | 页码直接显示数字，不再等待页面缩略图 |

**代价与取舍**：阅读器翻页时不再有页面缩略图条，只显示页码。对本 fork 的场景
（远程 FUSE、十万级库）这是划算的 —— 封面是列表页/详情页的刚需，页面缩略图只是
阅读器里的导航辅助，而它需要**逐页读取远端归档**才能生成。

**实测验证（镜像 `lrr-custom:v12`，容器 `lrr-test`）**：

对 3 个归档分别删除封面后经 API 触发，封面全部正确生成，
而各自的页面缩略图目录时间戳**保持不变**：

| 归档 | 页数 | 封面 | 页面缩略图 |
|---|---|---|---|
| `60dd838c…` | 27 | 02:16 生成（98025 B）✅ | 停留在 02:08，未重渲染 ✅ |
| `ae83730a…` | 28 | 02:18 生成（82301 B）✅ | 未生成 ✅ |
| `bc0945f7…` | 59 | 02:18 生成（93544 B）✅ | 停留在 01:11，未重渲染 ✅ |

触发后 `active: []`，所有作业 `finished`，`thumbjob` 字段被正确 `hdel`。

**附带修复**：`lib/LANraragi.pm` 的 `missing_after` 从 `5` 恢复为上游默认
`1800`（提交 `a9b22864`）。Minion worker 心跳间隔是 300 秒，而 `missing_after(5)`
意味着任何超过 5 秒的作业都会让 worker 被判定为失联并被回收，与心跳间隔
自相矛盾。

**生效方式**：`.pm` 与 `public/js/` 都不在 compose 挂载表中 —— 必须**重建镜像**。

---

### 13. 「挂载即用」默认值（`LRR_SHINOBU_WATCH_DIRS` 自动探测 + `AUTOFIX` 默认 -1）

**问题**：官方镜像 `docker run -v ...:/content ... difegue/lanraragi` 起来就能用，
而本 fork 有 **2 个环境变量必须手填**，否则①库永远空白 ②容器静默挂起。

| # | 变量 | 不设时的行为（改前） | 是否阻断即用 |
|---|---|---|---|
| 1 | `LRR_SHINOBU_WATCH_DIRS` | **拒绝扫描**（`Shinobu.pm` 直接 return）→ 库空白 | ⚠️ **致命** |
| 2 | `LRR_AUTOFIX_PERMISSIONS` | Dockerfile 硬编码 `1` → s6 递归 `chown` → **FUSE 上静默死锁** | ⚠️ **致命** |

**改动**：

1. **`lib/Shinobu.pm` `get_watch_dirs()`**：未设时自动枚举 content 根的一级子目录作为作用域。
   - 用 `defined()` 判断（非真值）：显式空串 `""` 仍是「禁用扫描」的逃生开关
   - 只做一次 `readdir`，**不引入逐条目 `stat`**
   - 粒度正确：`ingest_batched()` 枚举每个 root 的直接子目录为扫描单元，
     取 content 根的一级子目录 ⇒ 单元正好落在分片/年份目录上

2. **`tools/build/docker/Dockerfile`**：`LRR_AUTOFIX_PERMISSIONS=1` → **`-1`**。
   - 权限问题**可见可修**；FUSE 上的递归 `chown` 是**静默死锁**
   - 本地磁盘部署若依赖自动修权限，显式设 `LRR_AUTOFIX_PERMISSIONS=1` 即可

**三种取值的行为（`LRR_SHINOBU_WATCH_DIRS`）**：

| 取值 | 行为 |
|---|---|
| **不设** | 自动枚举 content 根一级子目录（推荐，即挂载即用）|
| **空串 `""`** | 显式禁用扫描（逃生开关，行为同改前的不设）|
| `"wnacg:pika"` | 只扫这两个（**完全不变**，向后兼容）|

**为什么粒度不会错**：自动探测**永远从 content 根往下取一级**，
结构上不可能犯「配叶子分片」的错 —— 而手配 `wnacg/1-50000` 会让
`enumerate_units` 找不到子目录，把整个分片当成一个单元，逐个 `stat` 5 万个归档。

**代价**：若某用户 content 根下**直接堆了几十万文件**（无分片），自动探测会扫它。
但上游行为**同样会扫**（上游就是全量遍历），因此不比官方差。

### 14. 扫描断点移到可写目录 + 入库改顺序执行

**问题一：断点文件从未写出过**（`lib/LANraragi/Utils/Ingest.pm`）

`default_cursor_path()` 用 `LRR_DATA_DIRECTORY` 拼 `ingest_cursor.json` 的路径，
但该变量是 **content 根**，而 content 在 FUSE 上通常以 `:ro` 挂载。
`_save_cursor()` 的 `open('>', $tmp)` 因此必失败 → 打一条 warn 后 `return`，
**断点静默丢失**，每次重启从头重扫。

实测：容器与宿主上**都找不到**该文件，content 挂载确认只读
（`touch: Read-only file system`）。

改动：断点是**扫描状态**而非内容，改放到可写的镜像 VOLUME
`/home/koyomi/lanraragi/database/`；`LRR_INGEST_CURSOR` 可覆盖。

实测对比：

| | 改前 | 改后 |
|---|---|---|
| 路径 | `<content 根>/ingest_cursor.json` | `<data>/database/ingest_cursor.json` |
| 可写性 | ❌ 只读挂载，写入必失败 | ✅ 可写 |
| 首次扫描 | `2 unit(s), 0.6s` | `2 unit(s), 0.6s` |
| **重启后** | 断点不存在 → **重扫** | `0 unit(s), 0.0s` → **断点复用** |

**问题二：首次入库用 MCE 多进程并发写 Redis**（`lib/Shinobu.pm`）

Unix 分支用 `mce_loop` 并发跑 `add_new_files()`。该函数在本 fork 里
**只剩 Redis 写入**（`compute_id` 只哈希路径，`add_new_file` 已移除
`get_filelist` / 体积轮询 / 缩略图生成），并发因此只带来两个问题：

1. **正确性**：`add_new_files()` 写 db0（archive hash、`arcids_idx`）与 db3
   （`INDEX_*` / `LRR_STATS`）。并发写可能在 `arcids_idx` 序号上竞争、重复计数 stats。
2. **风险**：MCE 正是本 fork 里卡死 Minion 作业的**同一机制**。

改动：**全平台改顺序执行**，移除 `use MCE::Loop`。

**为什么吞吐代价可接受**：实测 Redis 单次写 ~200µs，每归档约 10 次写 ⇒ ~2ms/归档。
5 万归档的首次扫描约多花 100 秒 —— 而同一场扫描里 FUSE 的 `readdir` 遍历
是**几十分钟**量级（`wnacg` 一层 9 个目录就要 35 秒），串行写完全被淹没。

**实测证据**（6 个真实归档，2 个一级子目录，不设 `WATCH_DIRS`）：

```
auto-detected 2 watch director(ies) under the content root.
Found 6 new files.
Adding new file .../a/1.cbz     with ID 21e99869...
Adding new file .../a/10.cbz    with ID d7974a44...
Adding new file .../a/10000.cbz with ID 19278baa...
Adding new file .../a/10001.cbz with ID 44a65899...
Adding new file .../b/10002.cbz with ID 12fd60c1...
Adding new file .../b/10003.cbz with ID 24a01954...
Initial scan complete: 2 unit(s) in 1 batch(es), 0.6s.
```

6 个文件按 a/1 → a/10 → a/10000 → a/10001 → b/10002 → b/10003 **严格顺序**入库，
并发下不会如此整齐。`/proc` 扫描无任何 MCE 进程残留。

---

## (B) 部署层面的改动（不在 Git 中）

### 1. 镜像

**不是**官方 `difegue/lanraragi`，而是自建镜像 **`lrr-custom:v14`**。

**构建方式（2026-10-03 核实，此前文档说「本机无 Dockerfile」已过时）**：

```bash
cd <仓库根>
docker build -f tools/build/docker/Dockerfile -t lrr-custom:v14 .
```

- `tools/build/docker/Dockerfile` **存在于仓库**（136 行，多阶段构建：`base` → `build` → `runtime`）
- `Dockerfile:128` 的 `COPY /public public` 是**前端文件烤进镜像**的位置 ——
  改 `public/js/**` 后**必须重建镜像**才生效（`public/` 不在 compose 挂载表中）
- `Dockerfile:106` 有 fork 专属修复：预建 `/home/koyomi/perl5` 并 `chown koyomi`，
  避免 local::lib 以 uid 9001 启动时无法创建 `perl5/bin`

### 2. 环境变量

| 变量 | 值 | 作用 |
|---|---|---|
| `LRR_DATA_DIRECTORY` | `<content 根目录>` | 内容根目录。**不是** `LRR_CONTENT_DIR`——该变量在代码中不存在（见 PROJECT.md §3.1） |
| `LRR_DISABLE_SHINOBU` | **`0`** | **启用监听**（`readdir` 扫描已修好，见 (A) 9）。未设即启用 |
| `LRR_SHINOBU_WATCH_DIRS` | `<顶层目录>` | 监听/首扫范围，用 `:` 分隔。**配顶层目录**（如 `wnacg`），不要配叶子分片 |
| `LRR_AUTOFIX_PERMISSIONS` | `-1` | 权限修正策略 |
| `LRR_UID` / `LRR_GID` | `<运行身份>` | 运行身份 |
| `MOJO_PROXY` | `1` | 反代支持 |
| `MOJO_REVERSE_PROXY` | `1` | 反代支持 |
| `LRR_NETWORK` | `http://*:3000` | 监听地址 |

### 3. 挂载

| 宿主 | 容器内 | 模式 | 说明 |
|---|---|---|---|
| `<宿主 FUSE 路径>` | `content/<来源>` | **ro** | **网盘 FUSE 只读挂载**（⚠️ **不要加 `rshared`**，见下方警告） |
| `<数据目录>/database` | `database` | rw | redis 数据落地 |
| `<数据目录>/thumb` | `thumb` | rw | 缩略图 |
| `<数据目录>/plugins` | `.../Plugin/Sideloaded` | rw | 插件 |
| `<override 路径>/Utils/Database.pm` | `.../Utils/Database.pm` | **ro** | **补丁覆盖** |

> ⚠️ **不要给 FUSE 挂载点加 `rshared`**：它会让内核递归传播挂载事件，容器删除时 `umount` 永久阻塞 → 容器卡在 `Removal In Progress` → 只能重启 dockerd。

#### 3.1 ⚠️ bind mount 跨 FUSE 的元数据开销（2026-10 实测）

**结论：容器通过 bind mount 访问宿主 FUSE 时，每个文件的元数据操作比宿主侧慢数千倍。**

这不是代码问题，`Ingest` 批处理也**无法规避** —— 它只降低单次遍历的爆炸半径，不改变 per-file 成本。

同一目录 `wnacg/1-50000`（26417 个文件）实测：

| 操作 | 宿主机（原生 FUSE） | 容器内（bind mount） |
|---|---|---|
| `readdir` 26417 条目 | 0.003s | **6.45s** |
| `stat` 200 个文件 | 0.00s | **1.13s**（5.7 ms/个） |
| `getxattr` 100 个文件 | — | **6.62s**（66 ms/个） |
| `File::Find` 全分片 | **1.0s** | **>60s（未完成）** |

**成因**：宿主侧 dentry 缓存已预热，容器内因挂载命名空间隔离无法复用；且挂载参数含 `default_permissions`，每次元数据访问额外发起一轮 FUSE 权限检查。

**按 5.7 ms/文件推算**：26417 文件 × 5.7ms ≈ **150 秒/分片** —— 这正是首扫「每分片 2.5 分钟」的来源。全库 30 万文件首扫因此需数小时。

**缓解方向（按收益排序）**：

1. 改用 Docker **named volume** 而非 bind mount（内核路径不同，可能显著更快）—— 需实测验证
2. 查询 CloudFS 是否支持 `actimeo` 等属性缓存参数，延长缓存有效期
3. `LRR_SHINOBU_WATCH_DIRS` 只配真正需要监听的目录，缩小首扫范围
4. **首扫一次性完成后**，后续靠 inotify 增量，不再有此成本

> 注：官方上游 `01-lrr-setup` 默认对 `content/` 递归 `chmod`（`LRR_AUTOFIX_PERMISSIONS=1`），在 30 万文件 + 慢 FUSE 上会让容器启动卡住很久。大库部署建议设 `LRR_AUTOFIX_PERMISSIONS=-1`（跳过修正）。

### 4. override 补丁机制 —— ⚠️ 已废弃

> **自镜像 `lrr-custom:v14` 起，本机制不再使用。** 修复已全部进镜像源码。
> 本节保留作为历史记录，**新部署不要启用**。

**当年为什么需要**：早期镜像代码是烤死的（当时仓库无 Dockerfile），`docker exec` 改文件会在容器重建时丢失。

**当年做法**：单个文件 bind mount（`:ro`），覆盖容器内 `lib/LANraragi/Utils/Database.pm`。

**现在的事实（2026-10-03 核验）**：

| 检查项 | 结果 |
|---|---|
| compose 挂载表引用 override | ❌ 无 |
| `tools/build/docker/Dockerfile` 引用 override | ❌ 无 |
| 仓库内 `override/` 目录 | ❌ 不存在 |
| `/vol1/1000/docker/lrr/override/Database.pm` | 存在，但**无任何路径引用它** —— 孤儿文件 |
| 该文件内容 | **过时**：缺 `5ee7f7f0`（`arcids_idx` 按需重建）的 63 行代码，`CUSTOM FORK` 标记 9 处 vs 仓库 10 处 |

**结论**：`override/Database.pm` 既不生效、内容也已落后于仓库版本。
交付物中**不包含** `override/`，避免使用者误以为改动它会生效。

### 5. Redis 库分工（排查时必看）

| 库 | 角色 | 内容 |
|---|---|---|
| db0 | `redis_database` | 归档 hash + `arcids_idx` |
| db1 | minion | `minion.*` 任务 |
| db2 | config | `LRR_PLUGIN_*` / `LRR_CONFIG` |
| **db3** | **search** | **`LRR_TITLES` / `LRR_STATS` / `INDEX_*` 等索引全在这** |
| db4 | metrics | — |

> ⚠️ 查索引必须 `select(3)`。查 db0 会得到「索引不存在」的错误结论。

### 6. 运维脚本（本 fork 新增）

| 脚本 | 作用 |
|---|---|
| `script/migrate_arcids.pl` | 构建 `arcids_idx`（幂等，支持 dry-run）|
| `script/verify_arcids.pl` | 索引一致性自检（支持 `--fix`）|
| `script/bench_arcids.pl` | 索引性能基准 |
| `script/bench_http.pl` | HTTP 分页性能基准 |

---

## 效果总览

| 场景 | 官方上游 | 本 fork |
|---|---|---|
| 全库 ID 计算 | 数十小时（FUSE 读内容）| **分钟级**（只哈希路径）|
| `/api/archives?start=0` | 秒级 | **亚秒级** |
| `/api/archives`（省略 start）| **数十秒**（worker 被判死）| **亚秒级** |
| 分类页渲染 | **分钟级 / 十几 MB** | 前端分页，**秒级** |
| 首次搜索 | 数十秒 | **十几秒** |
| 搜索缓存命中 | 几乎不命中 | **亚秒级** |
| 启动索引重建 | **十几分钟**且循环重跑 | **按需触发**：`index-init` 服务仅在 `LAST_JOB_TIME` 缺失时建一次 |
| ID 跨机器稳定性 | **失效**（含绝对路径）| **稳定**（相对路径）|
| 浏览列表页 | 每页入队缩略图任务 | **零任务**（占位图）|
| 打开阅读器 | 生成封面 + 全部页面缩略图（逐页读远端归档）| **只生成封面**，零页面读取 |
| Minion 作业子进程 | 作业卡 `active`，worker 被拖死 | **顺序执行，正常完成** |
| 坏缩略图 | libvips die → 前端无限重试 → D 状态堆积 | **魔术字节拦截 + 3 次熔断** |
| 挂载即用 | 官方镜像开箱可用 | **需 0 个环境变量**（`WATCH_DIRS` 自动探测、`AUTOFIX` 默认 -1）|
| 扫描断点 | — | **写入可写目录，重启复用**（改前写只读 content，静默丢失）|
| 首次入库 | 多进程并发写 | **顺序执行**，与 Minion 同源的 MCE 已移除 |

> ℹ️ **关于启动索引重建**：本 fork 禁用的是**上游那种每次启动都全量重跑**的行为
> （大库上要十几分钟，且失败会循环重试）。取而代之的是 s6 一次性服务 `index-init`：
> 仅在 `LAST_JOB_TIME` 缺失时执行一次 `rebuild_stats.pl`，之后每次重启都秒过。
> 因此新部署**不再需要**手动触发 `build_stat_hashes`，界面也不会再显示「共 -1 件瑰宝」。
>
> 注意 `index-init` 只负责写入 `LAST_JOB_TIME`，让 `do_search()` 不再返回 `-1`；
> 真实索引条目由 Shinobu 入库时实时增量写入，不需要等全量重建完成。
> 手动重建方式仍见 [`DEPLOY.md`](./DEPLOY.md)（注意：`script/migrate_arcids.pl` **只**管
> `arcids_idx`，**不**管 `build_stat_hashes` —— 此前的文档在此处有误导）。

---

## 与官方上游的关系：独立维护

- **本 fork 自 2026-10-03 起独立维护，不再 merge 官方上游** —— 未配置 `upstream`
  remote，历史为单根，与官方已无合并关系
- 上游新特性**不自动流入**；确需某个上游修复时**手工挑选、单独提交**
- 以下文件是本 fork 相对上游分叉点的全部改动，用于确认「本地改了什么」：
  - `lib/LANraragi/Utils/Database.pm` ← `compute_id` + `arcids_idx`
  - `lib/LANraragi.pm` ← `LRR_DISABLE_SHINOBU` + 禁用自动重建
  - `lib/LANraragi/Model/Search.pm` ← 缓存软失效 + `KEYS`→`SCAN`
  - `lib/LANraragi/Model/Archive.pm` ← 分页下推
  - `lib/LANraragi/Controller/Api/Archive.pm` ← `start` 参数语义
  - `lib/LANraragi/Controller/Category.pm` ← 取消服务端全量渲染
  - `public/js/mod/common.js` ← 去掉 `no_fallback=true`
  - `lib/Shinobu.pm` ← 纯路径扫描 + 作用域监听 + **未设时自动探测一级子目录**
  - `tools/build/docker/Dockerfile` ← `LRR_AUTOFIX_PERMISSIONS` 默认 `1`→`-1`
  - `public/js/mod/index_datatables.js` ← 去掉 `no_fallback=true`
- 手工引入上游代码后，用 `git diff` 逐个比对上述文件是否被覆盖
  （**不要**再依赖已废弃的 `override/` 机制）

---

## 一句话总结

**把 LANraragi 从「面向本地小库」改造为「十万级库 + 网盘 FUSE 远程存储可用」** —— 核心是四件事：**ID 不再读文件内容**、**分页不再 `KEYS` 全扫**、**搜索缓存能真正命中**、**ID 不再绑定安装路径**。
