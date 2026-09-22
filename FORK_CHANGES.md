# lrr-custom —— 相对官方上游做了什么

> 本文档记录本 fork 相对 [Difegue/LANraragi](https://github.com/Difegue/LANraragi) 官方上游的**全部改动**。
> 分两部分：**(A) 已提交到 Git 的代码改动**、**(B) 部署层面的配置与运维改动**。

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
- 生产环境已设 `LRR_DISABLE_SHINOBU=1`

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
- **索引缺失时自动回退 `KEYS`** → 部署顺序安全
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

## (B) 部署层面的改动（不在 Git 中）

### 1. 镜像

**不是**官方 `difegue/lanraragi`。基于官方代码 + 上述提交构建（本机无 Dockerfile，构建环境在别处）。

### 2. 环境变量

| 变量 | 值 | 作用 |
|---|---|---|
| `LRR_CONTENT_DIR` | `<content 根目录>` | 内容根目录 |
| `LRR_DISABLE_SHINOBU` | **`1`** | **禁用文件监听**（FUSE 上会卡死）|
| `LRR_AUTOFIX_PERMISSIONS` | `-1` | 权限修正策略 |
| `LRR_UID` / `LRR_GID` | `<运行身份>` | 运行身份 |
| `MOJO_PROXY` | `1` | 反代支持 |
| `MOJO_REVERSE_PROXY` | `1` | 反代支持 |
| `LRR_NETWORK` | `http://*:3000` | 监听地址 |

### 3. 挂载

| 宿主 | 容器内 | 模式 | 说明 |
|---|---|---|---|
| `<宿主 FUSE 路径>` | `content/<来源>` | **ro,rshared** | **网盘 FUSE 只读挂载** |
| `<数据目录>/database` | `database` | rw | redis 数据落地 |
| `<数据目录>/thumb` | `thumb` | rw | 缩略图 |
| `<数据目录>/plugins` | `.../Plugin/Sideloaded` | rw | 插件 |
| `<override 路径>/Utils/Database.pm` | `.../Utils/Database.pm` | **ro** | **补丁覆盖** |

### 4. override 补丁机制

**为什么需要**：镜像代码是烤死的（无 Dockerfile），`docker exec` 改文件会在容器重建时丢失。

**做法**：单个文件 bind mount（`:ro`），覆盖容器内 `lib/LANraragi/Utils/Database.pm`。

**注意**：宿主 `override/` 下另有若干 `.pm`，**内容与镜像内一致且未挂载** —— 改它们不生效。

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
| 启动索引重建 | **十几分钟**且循环重跑 | **禁用**，手动触发 |
| ID 跨机器稳定性 | **失效**（含绝对路径）| **稳定**（相对路径）|

---

## 与官方上游的同步策略

- 本 fork 基于官方 `dev` 分支，定期 merge 上游
- 同步上游时**必须比对**以下文件（本 fork 有改动）：
  - `lib/LANraragi/Utils/Database.pm` ← `compute_id` + `arcids_idx`
  - `lib/LANraragi.pm` ← `LRR_DISABLE_SHINOBU` + 禁用自动重建
  - `lib/LANraragi/Model/Search.pm` ← 缓存软失效 + `KEYS`→`SCAN`
  - `lib/LANraragi/Model/Archive.pm` ← 分页下推
  - `lib/LANraragi/Controller/Api/Archive.pm` ← `start` 参数语义
  - `lib/LANraragi/Controller/Category.pm` ← 取消服务端全量渲染
- 升级镜像后，用 `override/Utils/Database.pm` 与镜像内官方原版逐行比对

---

## 一句话总结

**把 LANraragi 从「面向本地小库」改造为「十万级库 + 网盘 FUSE 远程存储可用」** —— 核心是四件事：**ID 不再读文件内容**、**分页不再 `KEYS` 全扫**、**搜索缓存能真正命中**、**ID 不再绑定安装路径**。
