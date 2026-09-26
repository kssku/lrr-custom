# lrr-custom 项目总纲

> **本文件是本仓库的唯一权威总纲。任何代码、配置、脚本、部署方式的修改，都必须在同一次提交里同步更新本文件对应章节。**
>
> 这不是建议，是硬性要求。理由：本 fork 的改动分布在「ID 算法 / Redis 索引 / 扫描路径 / 部署挂载」四个互相耦合的层面，
> 只改一处而不更新总纲，下一个人（或下一次会话的 AI）就会按过时认知操作，直接损坏全库 ID 或触发挂载事故。

## 维护契约

| 项 | 规定 |
|---|---|
| 权威性 | 本文件与代码冲突时，**以代码为准**，并立即修正本文件 |
| 同步时机 | 同一次 commit 内，改代码 → 改本文件；不允许"下次再补" |
| 提交信息 | 涉及行为变更的提交，正文必须写明 `Docs: PROJECT.md §<章节>` |
| 审查 | `git diff` 里出现代码改动但 `PROJECT.md` 无对应改动时，视为提交不合格 |
| 事实要求 | 只写已核验的事实。**环境变量必须能在代码里 grep 到引用点**，否则不得写入 |
| 实测数据 | 性能数字必须标注测量环境与样本量，禁止写"约""很快"这类无锚点描述 |

**相关文档**：
[`README.md`](./README.md)（面向使用者的介绍与部署要点）·
[`FORK_CHANGES.md`](./FORK_CHANGES.md)（逐提交的改动清单与实测数据）·
[`CONTRIBUTING.md`](./CONTRIBUTING.md)（提交规范）

---

## 1. 项目定位

LANraragi（LRR）的个人 fork。上游 [Difegue/LANraragi](https://github.com/Difegue/LANraragi) 面向
**本地磁盘上的中小型漫画库**；本 fork 面向一个上游没有假设过的场景：

> **一个 16 万文件级别的漫画库，存放在 115 网盘的 FUSE 挂载点上。**

这个场景让上游的每一个隐含假设都失效：

| 上游假设 | 本场景现实 | 后果 |
|---|---|---|
| 文件在本地盘，读取便宜 | FUSE 往返，每次 `stat` ~1.65 ms | 逐文件 `stat` 全库要数小时 |
| 归档可以打开读内容算 ID | 每文件读 512 KB | 全库 ID 计算要数十小时 |
| `KEYS` 扫描可接受 | db0 有 16 万键、db3 有 26.9 万键 | 单次调用阻塞数秒 |
| ID 可绑定安装路径 | 挂载点会变 | 换机/换挂载点 → 全库 ID 失效 |
| 扫描时可以读文件 | 读文件就是卡死的根因 | Shinobu 卡死 |

本 fork 的全部改动，都是为了在这五个点上把「读内容」换成「读路径」、把「全扫」换成「按索引取」。

- **版本基线**：`0.9.81 Atomica`（见 `package.json`）
- **上游基线 commit**：`db310690`
- **本 fork 提交数**：15（自 `8370bf83` 起）
- **当前分支**：`feature/path-hash-id`
- **远程**：`https://github.com/kssku/lrr-custom.git`

---

## 2. 目录结构

```
lrr-custom/
├── PROJECT.md              ← 本文件（唯一权威总纲）
├── README.md               ← 使用者视角：核心思路、部署要点、实测数据
├── FORK_CHANGES.md         ← 逐提交改动清单 + (B) 部署层配置
├── CONTRIBUTING.md         ← 提交规范（含本项目总纲同步要求）
├── lrr.conf                ← Redis 连接与库分配
├── lib/
│   ├── LANraragi.pm        ← 应用启动、Minion/Shinobu 拉起
│   ├── Shinobu.pm          ← 文件监听与入库（★ 本 fork 重写为纯路径扫描）
│   ├── Worker.pm
│   └── LANraragi/
│       ├── Controller/     ← HTTP 层（含 Api/）
│       ├── Model/          ← 业务层（Search / Archive / Config / Plugins …）
│       ├── Plugin/         ← 插件（含 Scripts/）
│       └── Utils/          ← 工具层（★ Database.pm 含 ID 算法与 arcids_idx）
├── script/                 ← 运维与迁移脚本（见 §7）
├── patch-badimage/         ← 坏图/坏缩略图熔断补丁
├── patch-thumbfail/        ← 缩略图失败补丁
├── public/js/              ← 前端（batch.js / category.js 分页改造）
├── templates/ + locales/   ← 模板与 i18n（新增词条必须同步 .po）
└── tools/build/docker/     ← 自建镜像的 Dockerfile 与 s6 启动脚本
```

**注意**：`Shinobu.pm` 位于 `lib/Shinobu.pm`，**不是** `lib/LANraragi/Model/Shinobu.pm`。
README 旧版本里的该路径是错的，已修正。

---

## 3. 架构与数据流

### 3.1 进程模型

| 进程 | 职责 | 启动方式 |
|---|---|---|
| `lanraragi`（Mojolicious）| HTTP 服务、API、页面渲染 | 主进程 |
| Minion worker | 后台任务（入库、缩略图、备份…）| `Proc::Simple` 独立进程 |
| Shinobu | 文件监听 + 增量入库 | `Proc::Simple` 独立进程 |

Minion 与 Shinobu 是**独立进程**，pid 落在 `/tmp/*.pid`、`/tmp/*.pid-s6`。
因此「重启主服务」不一定重启它们 —— 排查行为异常时必须先确认进程实际状态。

### 3.2 Redis 库分配（`lrr.conf`）

| 库 | 用途 | 关键键 |
|---|---|---|
| db0 | 归档数据 | 每归档一个 hash；**`arcids_idx`**（zset，分页索引）|
| db1 | Minion | 任务队列 |
| db2 | 配置 | `dirname`、`thumbdir` 等 |
| db3 | 搜索索引 | `INDEX_*`（**26.9 万键**）、`LRR_TITLES`（有序集）|
| db4 | 指标 | `metrics:*` |

连接：`redis_address = 127.0.0.1:6379`，`base_url_path = ""`。

> ⚠️ **`arcids_idx` 绝不能用 `LRR_*` 前缀。** Minion 会 MOVE-drain 所有 `LRR_*` 键，
> 用该前缀会让分页索引被 Minion 清空。

### 3.3 两套独立索引（最容易搞错的地方）

| 索引 | 位置 | 服务对象 | 访问方式 |
|---|---|---|---|
| `arcids_idx` | db0 | **分页**（`/api/archives?start=N`）| `ZRANGE` |
| `LRR_TITLES` | db3 | **搜索**（标题排序/模糊匹配）| `zrangebylex` / `zscan` |

它们**不是同一份数据**，数量也不保证一致。改分页不要动搜索，反之亦然。

### 3.4 内容根目录：唯一权威来源

```
get_userdir()  →  $ENV{LRR_DATA_DIRECTORY}  若设置则覆盖
               →  否则 get_redis_conf("dirname", "./content")
               →  相对路径以 /lanraragi 为基准转绝对路径
```

定义在 `lib/LANraragi/Model/Config.pm:130`。

> ❌ **不存在 `LRR_CONTENT_DIR` 这个变量。** 全仓零引用。README 旧版本写过它，已修正。
> 正确变量是 **`LRR_DATA_DIRECTORY`**。

### 3.5 ID 算法（`lib/LANraragi/Utils/Database.pm::compute_id`）

**旧（上游）**：读归档前 512 KB 算哈希 → 内容寻址。
**新（本 fork）**：`SHA1( <相对 content 根的路径> )`，UTF-8 编码后哈希，**O(1)，零文件读取**。

```perl
my $root = LANraragi::Model::Config::get_userdir();
# SHA1(abs2rel($file, $root))  —— 形如 SHA1("wnacg/350001-400000/351234/351234.cbz")
```

三个设计后果，必须理解：

1. **ID 与安装位置解耦** —— 换机器、换挂载点，ID 不变。
2. **来源目录名参与哈希** —— 同一部作品出现在两个来源下不会碰撞。
3. **分片目录名是 ID 的纯函数** —— `1-50000` 这类数字区间、`2026` 这类年份目录，
   都是入库工具按 ID 生成的。**如果入库工具改了分片规则或年份规则，全库 ID 会再次全变。**

> ⚠️ **已知脆弱点与升级路径**（同时写在 `compute_id` 的注释里）：
> 若分片/年份规则变更，需在 `compute_id` 中剥掉 `^\d+-\d+$` 与 `^\d{4}$` 路径段后，重跑 ID 迁移。

### 3.6 入库流程（本 fork 改造后）

```
写入文件
  → inotify 事件（仅 LRR_SHINOBU_WATCH_DIRS 范围内的目录）
  → 纯路径扫描：readdir + 路径哈希，**不打开归档**
  → 建 db0 hash + 写 arcids_idx
  → 缩略图：不生成（LRR_THUMBNAIL_MODE=lazy，首次阅读时才做）
```

**删除行为**：清 filemap，**保留 db0 孤儿** —— 这是上游行为，本 fork 未改。

### 3.7 搜索缓存：软失效

上游用硬失效（改索引即清缓存），在大库上导致缓存几乎永不命中。
本 fork 改为**软失效**：比对缓存条目的 `created` 时间戳，而不是直接丢弃。
`LRR_SEARCHCACHE_HARD_INVALIDATE=1` 可恢复上游行为（调试用）。

---

## 4. 环境变量（全部已核验存在）

> 规则：**下表中没有的变量不得在部署里使用。** 尤其 `LRR_CONTENT_DIR`、`LRR_AUTOFIX_PERMISSIONS`
> 是历史文档里出现过但**代码中不存在**的臆造变量。

### 4.1 本 fork 新增或语义变更

| 变量 | 默认 | 作用 | 定义位置 |
|---|---|---|---|
| `LRR_DATA_DIRECTORY` | — | **内容根目录覆盖**（最高优先级）| `Model/Config.pm:130` |
| `LRR_DISABLE_SHINOBU` | — | **设 `1` 才禁用**；不设或设 `0` 均启用 | `lib/LANraragi.pm`、`lib/Shinobu.pm` |
| `LRR_SHINOBU_WATCH_DIRS` | 空 | **作用域监听**，冒号分隔；不设 = watcher 空转 | `lib/Shinobu.pm` |
| `LRR_THUMBNAIL_MODE` | `lazy` | `lazy` 懒生成 / `auto` 上游行为 | `Model/Plugins.pm` |
| `LRR_SEARCHCACHE_HARD_INVALIDATE` | 空 | 设 `1` 恢复上游硬失效 | `Utils/Database.pm` |
| `LRR_STRICT_FILE_CHECK` | 空 | 设 `1` 恢复逐文件 `-e` 存在性检查 | `Utils/Database.pm` |

**`LRR_SHINOBU_WATCH_DIRS` 细则**：
- 冒号分隔，可绝对路径也可相对内容根
- 不设 = watcher 启动但**空转**（安全默认）
- **传内容根本身会被拒绝** —— 防止退化回全库扫描
- 例：`wnacg/350001-400000:wnacg/_no_id`

### 4.2 上游既有（本场景会用到的）

| 变量 | 作用 | 定义位置 |
|---|---|---|
| `LRR_THUMB_DIRECTORY` | 缩略图目录覆盖 | `Model/Config.pm` |
| `LRR_TEMP_DIRECTORY` | 临时目录覆盖 | `Utils/TempFolder.pm` |
| `LRR_LOGROTATE_FILES` | 日志保留份数（默认 7）| `Utils/RotatingLog.pm` |
| `LRR_LOGROTATE_SIZE` | 单份日志字节上限（默认 1048576）| `Utils/RotatingLog.pm` |

---

## 5. 部署

### 5.1 镜像

不是官方 `difegue/lanraragi`，而是自建镜像 **`lrr-custom:v3`**，基于 `tools/build/docker/Dockerfile`。

```bash
docker build -f tools/build/docker/Dockerfile -t lrr-custom:v3 .
```

> `v2` 存在 `perl5` 目录属主坑，已在 `99c08815` 于 Dockerfile 内预建目录（属主 `koyomi`）修根。
> 不再需要构建后补 `chown`。
>
> **override 补丁机制（bind mount 单文件覆盖）自 v3 起已废弃** —— 修复已进镜像。
> 该机制仅作为历史记录保留在 `FORK_CHANGES.md`。

### 5.2 网盘挂载

```yaml
- <宿主 FUSE 路径>:<容器 content 子目录>:ro
```

> ⚠️ **绝对不要加 `rshared`。**
> 加在 FUSE 挂载点上会让内核递归传播挂载事件；容器删除时 `umount` 永久阻塞，
> 容器卡在 `Removal In Progress`，**只能重启 dockerd** 才能恢复。
> 事故记录：知识库条目 `2026-09-23-dell-docker-rshared-mount-explosion`。

> ⚠️ 若容器报 cgroup 相关错误（`sysvinit + elogind` 撞 cgroup namespace），加 `cgroup: host`。

### 5.3 关键环境变量取值

| 变量 | 值 | 说明 |
|---|---|---|
| `LRR_DISABLE_SHINOBU` | **`0`** | **启用**监听（路径扫描已修好，FUSE 上可用）|
| `LRR_SHINOBU_WATCH_DIRS` | `<分片列表>` | 作用域监听，冒号分隔；不设 = 空转 |
| `LRR_THUMBNAIL_MODE` | `lazy` | 懒生成缩略图 |
| `LRR_DATA_DIRECTORY` | `<content 根目录>` | 内容根目录（**不是** `LRR_CONTENT_DIR`）|

---

## 6. 实测数据

测量环境：宿主机（非容器），115 网盘 FUSE 挂载点，15 万文件 / 9 个分片。

### 6.1 扫描性能

| 项 | 结果 |
|---|---|
| 全库首次扫描 | **约 54 秒**（纯目录遍历，不碰归档）|
| 之后增量 | 全靠 inotify，零额外成本 |
| 新文件入库 | 写入后 **约 2 秒**自动入库 |
| 删除 | 清 filemap、保留 db0 孤儿（上游行为）|

### 6.2 与上游对比

| 场景 | 官方上游 | 本 fork |
|---|---|---|
| 全库 ID 计算 | 数十小时（FUSE 读内容）| **分钟级**（只哈希路径）|
| 全库扫描（Shinobu）| 卡死 / 数小时 | **约 54 秒** |
| 增量入库 | 不支持（已禁用）| **inotify 实时，~2 秒** |
| `/api/archives?start=0` | 秒级 | **亚秒级** |
| `/api/archives`（省略 `start`）| **数十秒**（worker 被判死）| **亚秒级** |
| 分类页渲染 | **分钟级 / 十几 MB** | 前端分页，**秒级** |
| 首次搜索 | 数十秒 | **十几秒** |
| 搜索缓存命中 | 几乎不命中 | **亚秒级** |
| 启动索引重建 | **十几分钟**且循环重跑 | **禁用**，手动触发 |
| ID 跨机器稳定性 | **失效** | **稳定** |

### 6.3 FUSE 底层特性（解释上面数字的来源）

单个分片（50001-100000，22,812 项）实测：

| 方法 | 耗时 |
|---|---|
| SQLite 直读 `dir_cache` | **0.06 s** |
| `ls -U` | 0.143 s |
| `ls -1` | 0.12 s |
| `find -maxdepth 1` | 0.16 s |
| shell 拼路径 | 0.35 s |
| `ls`（带属性）| 0.40 s |
| **`ls -l`** | **48.28 s** |
| `find -maxdepth 2` | 110.17 s |
| Perl `readdir` 递归 | 111.62 s |

**根因**：慢的不是 `readdir`，而是**逐条 `stat` 的 FUSE 往返（~1.65 ms/次）**。
`ls -U`（143 ms）与 `ls -l`（48,284 ms）差 **337 倍**，全部来自属性查询。
`fileproperties.sqlite` 仅 4 KB，属性无缓存 → 每次 `stat` 回源网盘。

**推论（也是本 fork 的设计依据）**：只要不 `stat`、不读文件，16 万文件的路径遍历是**秒级**操作。
这就是「纯路径扫描」能成立的物理基础。

---

## 7. 运维脚本（`script/`）

| 脚本 | 用途 |
|---|---|
| `verify_arcids.pl` | **`arcids_idx` 一致性自检**。查四项：集合双向差集、score 唯一性、score 连续性、计数器与最大 score 一致。`--fix` 只修集合成员，**刻意不重编号**。用 `SCAN` 不用 `KEYS` |
| `migrate_arcids.pl` | 从既有 db0 构建 `arcids_idx`。**幂等**，支持 `--dry-run` |
| `bench_arcids.pl` | `arcids_idx` 读写基准 |
| `bench_http.pl` | HTTP 接口基准 |
| `ingest_batched.pl` | **批量入库模块**（当前主力）|
| `ingest_files.pl` | 旧版入库脚本 |
| `check_plugin_loads.pl` | 插件加载自检 |
| `launcher.pl` | 容器入口 |
| `lanraragi` / `get_version` / `backup` | 启动与版本工具 |

> ⚠️ **`arcids_idx` 的一个陷阱**：只比 `ZCARD` 数量**不能**判断一致性 ——
> 陈旧条目 +1、漏建 −1 会让总数看起来完全正常。**实测中就是这样。**
> 必须用 `verify_arcids.pl` 做集合级比对。

---

## 8. 与上游同步

本 fork 基于官方 `dev` 分支。**merge 上游时以下文件有本地改动，必须逐行比对**：

| 文件 | 改动 |
|---|---|
| `lib/LANraragi/Utils/Database.pm` | `compute_id` 路径哈希 + `arcids_idx` |
| `lib/LANraragi.pm` | `LRR_DISABLE_SHINOBU` + 禁用启动自动重建索引 |
| `lib/LANraragi/Model/Search.pm` | 缓存软失效 + `KEYS` → `SCAN` |
| `lib/LANraragi/Model/Archive.pm` | 分页下推 |
| `lib/LANraragi/Controller/Api/Archive.pm` | `start` 参数语义 |
| `lib/LANraragi/Controller/Category.pm` | 取消服务端全量渲染 |
| `lib/Shinobu.pm` | **纯路径扫描 + `LRR_SHINOBU_WATCH_DIRS` + `create_path` 修复** |
| `lib/LANraragi/Model/Plugins.pm` | 缩略图懒生成守卫 |
| `tools/build/docker/Dockerfile` | 预建 `perl5` 目录（属主 `koyomi`）|

**最高危两项**：
- **`compute_id`** —— 上游若覆盖它，全库 ID 全部失效。
- **`Shinobu.pm`** —— 上游若恢复「扫描时读文件内容」，FUSE 场景会重新卡死。

---

## 9. 待办与已知问题

### 9.1 性能残留（尚未改造）

**A 级 —— 40 字符 ID 模式的 `KEYS`，16 万归档下单次阻塞约 2 秒**：

| 位置 | 调用场景 |
|---|---|
| `Model/Stats.pm:56` | `get_archive_count`，**每次统计页 / Prometheus 抓取** |
| `Model/Stats.pm:260` | `compute_content_size` |
| `Controller/Api/Database.pm:194` | `clear_new_all` |
| `Model/Archive.pm:97` | `get_archive_ids` |
| `Model/Backup.pm:132` | 备份 |
| `Utils/Database.pm:407` | `clean_database`，**扫描后必跑** |
| `Utils/Minion.pm:189`、`Utils/Minion.pm:287` | 后台任务 |
| `Plugin/Scripts/nHentaiSourceConverter.pm:34` | 插件 |

**B 级 —— 规模小，非瓶颈**：
`TANK_??????????`、`SET_??????????`、`REG_??????????`、
`LRR_PLUGIN_*`（`Utils/Plugins.pm:299`）、`STAMPS_*`（`Model/Backup.pm:108`）、
`metrics:*`（`Model/Metrics.pm` 等 6 处）。

**已改造（C 级）**：`Model/Search.pm:168`、`Model/Search.pm:326`、`Model/Search.pm:44`。

### 9.2 唯一的逐条 `stat` 残留

`Model/Opds.pm:99` 仍有 `-e $file`。
OPDS 客户端拉目录时会对每个条目 `stat`，在 FUSE 上会卡（参见 §6.3 的 1.65 ms/条）。
**尚未改造。**

### 9.3 待清理文件（需确认后删除）

| 文件 | 理由 |
|---|---|
| `script/ingest_files.pl` | 全仓无引用，已被 `ingest_batched.pl` 取代 |
| `patch-badimage/apply.sh` | 已失效，被 `apply2.pl` 覆盖 |
| `patch-thumbfail/thumbfail.patch.pl` | 用 `docker exec` 改镜像内路径，违背 override 思路，与 `apply3.pl` 重叠 |

### 9.4 可选后续

- 把既有全量路径清单直接导入 LRR（跳过扫描，秒级）
- CD2 `dir_cache` 碎片回收（界面「清理数据库」；需确认扫描已停）
- 补写知识库条目：CD2 缓存库全量、FUSE `readdir` vs `stat` 337 倍差距、
  `rshared` 挂载爆炸事故

---

## 10. 修改指引

改任何东西之前，先回答三个问题：

1. **这个改动会不会改变 ID？** 会 → 需要迁移方案 + 全库重跑预算。
2. **这个改动会不会引入 `stat` 或文件读取？** 会 → 在 FUSE 上等于引入数量级退化。
3. **这个改动涉及哪个 Redis 库？** 分页是 db0 的 `arcids_idx`，
   搜索是 db3 的 `LRR_TITLES` / `INDEX_*`，别搞混；新键**不要**用 `LRR_*` 前缀。

改完之后，**同一次提交里更新本文件对应章节**，并在提交信息里写
`Docs: PROJECT.md §<章节>`。