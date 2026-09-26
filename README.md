# lrr-custom

> **本仓库是 [Difegue/LANraragi](https://github.com/Difegue/LANraragi) 的个人 fork**，
> 面向「**超大归档库 + 网盘 FUSE 远程存储**」场景做了深度性能改造。
> 上游原始内容（徽章、截图、特性列表）保留在下方。

## 📖 项目文档导航

| 文档 | 内容 |
|---|---|
| **[`PROJECT.md`](PROJECT.md)** | **唯一权威总纲** —— 架构 / 数据流 / 部署 / 运维 / 性能基线 / 技术债 / 待办 |
| [`FORK_CHANGES.md`](FORK_CHANGES.md) | 相对官方上游的**全部改动**（PROJECT.md §5 的展开细节） |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | 开发约定 —— **含「改代码必须同步改文档」硬性规则** |

> ⚠️ 改任何东西之前先读 `PROJECT.md`。它建立了几个反直觉的实测结论
> （如 FUSE 上 `stat` 比 `readdir` 慢 337 倍），是理解本 fork 全部设计的前提。

---

## 我为什么做这个 fork

我有一台自建的漫画库：**十万级归档**（cbz），全部放在**网盘**上，
通过第三方挂载工具映射为 FUSE 目录给容器只读访问。

直接跑官方版会撞上五个致命问题 —— 它们都源于同一个前提：
**官方假设「库在本地磁盘、规模几千本」**，而我的场景是「远程 FUSE、十万级」。

| 官方假设 | 我的现实 | 后果 |
|---|---|---|
| `compute_id` 读文件内容算 SHA-1 | FUSE 上每个文件读 512KB ≈ **数百毫秒** | 全库扫描要**几十小时** |
| `KEYS` 全库扫描可接受 | 十万级 ID 键 / 数十万索引键 | 单次请求**数秒到数十秒**，worker 被判死重启 |
| Shinobu 文件监听可用 | 原版扫描会读文件内容 | 在 FUSE 上遍历直接卡死 |
| ID 用镜像内绝对路径哈希 | 换机器/换挂载点 | **全库 ID 失效** |
| 每个新归档入库时生成缩略图 | FUSE 上两次读文件 | 增量入库被拖死 |

**这个 fork 的目标：把 LANraragi 改造成「超大库 + FUSE 存储」也能流畅跑。**

> **2026-09 更新**：Shinobu 已从「读内容的重量级扫描」改造为
> **纯路径扫描 + 作用域监听**，FUSE 上可正常启用。全库（15 万文件）
> 首次扫描实测 **约 54 秒**，之后完全依赖 inotify 增量。
> 见下方「思路 5」。

---

## 我改了什么（五个核心思路）

### 思路 1：ID 计算不读文件内容

`compute_id` 从「读 512KB 内容算 SHA-1」改为「只哈希文件路径」。

- 消除全库扫描时每个文件的 FUSE 读取开销
- 路径 UTF-8 编码后哈希，非 ASCII 文件名结果一致

### 思路 2：ID 不绑定镜像安装路径

`compute_id` 从「哈希绝对路径」改为「哈希 `content/` 之后的相对路径」。

```
旧: SHA1("<绝对路径>/content/<来源>/<分片>/<文件>.cbz")
新: SHA1("<来源>/<分片>/<文件>.cbz")
```

**收益**：换机器、换挂载点、换 content 根目录，ID 都不再变。
这次改造已在生产完成**全量迁移**。

### 思路 3：分页不再 `KEYS` 全扫

新增 `arcids_idx` zset（db0）作为分页索引 —— **单调递增 score，永不复用**，翻页顺序稳定。

- 上游：每次请求 `KEYS '????…'`（十万级键扫描，秒级 + 数 MB 传输）
- 本 fork：`ZRANGE arcids_idx`（**亚秒级**）
- `add_archive_to_redis` / `delete_archive` / `change_archive_id` 三者同步维护
- **索引缺失时自动回退 `KEYS`** → 部署顺序安全

> ⚠️ 索引**不能**命名为 `LRR_*` 前缀 —— Minion 会 MOVE-drain 该前缀的键。

### 思路 4：搜索缓存要能真正命中

上游 `invalidate_cache` 直接 `DEL` 整个 `LRR_SEARCHCACHE`，而它有 30+ 调用点、
Shinobu 每个文件触发 4 次 —— **导致缓存永远积累不起来**。

改为**软失效**：条目写入时带 `created` 时间戳，命中时比对，不再全量 `DEL`。
实测缓存可累积 **4 条共存**（上游永远 1-2 条）。

**逃生开关**：`LRR_SEARCHCACHE_HARD_INVALIDATE=1` 恢复上游行为。

### 思路 5：Shinobu 改成「纯路径扫描 + 作用域监听」

上游 Shinobu 在入库时会 **读文件内容**（算页数、生成缩略图）——
在 FUSE 上每个文件两次读取，这正是它卡死的根因。

本 fork 把整条入库路径改为**零文件读取**：

- 扫描只走 `readdir` + 路径哈希，**不打开任何归档**
- 缩略图改为**懒生成**（首次在阅读器打开时才做）
- 新增 `LRR_THUMBNAIL_MODE=lazy`（默认）／`auto`（上游行为）

**新增 `LRR_SHINOBU_WATCH_DIRS` —— 作用域监听**：

- **冒号分隔**，可绝对路径也可相对 `content/` 根
- 不设 = watcher 启动但**空转**（安全默认）
- 传 `content/` 本身会被拒绝（避免退化成全库扫描）
- 例：`wnacg/350001-400000:wnacg/_no_id`

**实测（15 万文件 / 9 个分片）**：

| 项 | 结果 |
|---|---|
| 全库首次扫描 | **约 54 秒**（纯目录遍历，不碰归档）|
| 之后增量 | **全靠 inotify**，零额外成本 |
| 新文件入库 | 写入后 **~2 秒**自动入库 |
| 删除 | 清 filemap、**保留 db0 孤儿**（上游行为）|

---

## 效果

| 场景 | 官方上游 | 本 fork |
|---|---|---|
| 全库 ID 计算 | 数十小时（FUSE 读内容）| **分钟级**（只哈希路径）|
| 全库扫描（Shinobu）| 卡死 / 数小时 | **约 54 秒**（纯路径）|
| 增量入库 | 不支持（已禁用）| **inotify 实时，~2 秒** |
| `/api/archives?start=0` | 秒级 | **亚秒级** |
| `/api/archives`（省略 start）| **数十秒**（worker 被判死）| **亚秒级** |
| 分类页渲染 | **分钟级 / 十几 MB** | 前端分页，**秒级** |
| 首次搜索 | 数十秒 | **十几秒** |
| 搜索缓存命中 | 几乎不命中 | **亚秒级** |
| 启动索引重建 | **十几分钟**且循环重跑 | **禁用**，手动触发 |
| ID 跨机器稳定性 | **失效** | **稳定** |

---

## 文档

| 文档 | 内容 |
|---|---|
| [`FORK_CHANGES.md`](./FORK_CHANGES.md) | **完整改动清单** —— 每个提交的目的、实现、实测数据；部署层配置；上游同步策略 |

---

## 部署要点（与官方不同的地方）

**镜像**：不是官方 `difegue/lanraragi`，而是自建镜像（`lrr-custom:v3`，基于
`tools/build/docker/Dockerfile`）。

**关键环境变量**：

| 变量 | 值 | 作用 |
|---|---|---|
| `LRR_DISABLE_SHINOBU` | **`0`** | **启用文件监听**（路径扫描已修好，FUSE 上可用）|
| `LRR_SHINOBU_WATCH_DIRS` | `<分片列表>` | **作用域监听**，冒号分隔；不设 = 空转 |
| `LRR_THUMBNAIL_MODE` | `lazy` | **懒生成缩略图**，首次打开才做（`auto` = 上游行为）|
| `LRR_DATA_DIRECTORY` | `<content 根目录>` | 内容根目录（**不是** `LRR_CONTENT_DIR`，后者在代码中不存在）|

**网盘挂载**（只读）：

```yaml
- <宿主 FUSE 路径>:<容器 content 子目录>:ro
```

> ⚠️ **不要加 `rshared`。** 它加在 FUSE 挂载点上会让内核递归传播挂载事件，
> 容器删除时 umount 永久阻塞 → 容器卡在 `Removal In Progress` → 只能重启 dockerd。
> 详见 [`FORK_CHANGES.md`](./FORK_CHANGES.md) 与知识库条目 `2026-09-23-dell-docker-rshared-mount-explosion`。

> ⚠️ 若容器报 cgroup 相关错误（`sysvinit + elogind` 撞 cgroup namespace），
> 加 `cgroup: host`。

**override 补丁机制**（v3 起已不再需要 —— 修复已进镜像，仅作历史参考）：

```yaml
- <宿主 override 路径>/Utils/Database.pm:<容器 lib 路径>/Utils/Database.pm:ro
```

> 详细部署配置见 [`FORK_CHANGES.md`](./FORK_CHANGES.md) 的「(B) 部署层面的改动」。

**重建镜像**（v3 已可用）：

```bash
docker build -f tools/build/docker/Dockerfile -t lrr-custom:v3 .
```

> v2 的 `perl5` 属主坑已在 `99c08815` 于 Dockerfile 内预建目录修根，
> 不再需要构建后补 `chown`。

---

## 与上游同步时必看

本 fork 基于官方 `dev` 分支。**merge 上游时，以下文件有本地改动，必须逐行比对**：

- `lib/LANraragi/Utils/Database.pm` ← `compute_id` + `arcids_idx`
- `lib/LANraragi.pm` ← `LRR_DISABLE_SHINOBU` + 禁用自动重建索引
- `lib/LANraragi/Model/Search.pm` ← 缓存软失效 + `KEYS`→`SCAN`
- `lib/LANraragi/Model/Archive.pm` ← 分页下推
- `lib/LANraragi/Controller/Api/Archive.pm` ← `start` 参数语义
- `lib/LANraragi/Controller/Category.pm` ← 取消服务端全量渲染
- `lib/Shinobu.pm` ← **纯路径扫描 + `LRR_SHINOBU_WATCH_DIRS` + `create_path` 修复**
  （注意：不在 `lib/LANraragi/Model/` 下，Shinobu 位于 `lib/` 顶层）
- `lib/LANraragi/Model/Plugins.pm` ← **缩略图懒生成守卫**
- `tools/build/docker/Dockerfile` ← **预建 `perl5` 目录（属主 koyomi）**

**特别是 `compute_id`** —— 如果上游改动覆盖了它，全库 ID 会全部失效。

**特别是 `Shinobu.pm`** —— 上游若恢复「扫描时读文件内容」，FUSE 场景会重新卡死。

---

## 风险提示

**已知脆弱点**：分片目录（如 `1-50000`）与年份目录（如 `2026`）是 `comic_id` 的**纯函数**。
若上游改分片大小或年份算法，ID 会再次全变。
**升级路径**：在 `compute_id` 里剥掉 `^\d+-\d+$` 与 `^\d{4}$` 路径段后重跑迁移。

---

<details>
<summary><b>以下为官方 LANraragi 的原始 README</b>（点击展开）</summary>

<!-- 官方原文开始 -->

[<img src="https://img.shields.io/docker/pulls/difegue/lanraragi.svg">](https://hub.docker.com/r/difegue/lanraragi/)
[<img src="https://img.shields.io/github/downloads/difegue/lanraragi/total.svg">](https://github.com/Difegue/LANraragi/releases)
[<img src="https://img.shields.io/github/release/difegue/lanraragi.svg?label=latest%20release">](https://github.com/Difegue/LANraragi/releases/latest)
[<img src="https://img.shields.io/homebrew/v/lanraragi.svg">](https://formulae.brew.sh/formula/lanraragi)  
[<img src="https://img.shields.io/website/https/lrr.tvc-16.science.svg?label=demo%20website&up_message=online">](https://lrr.tvc-16.science/)
[<img src="https://github.com/Difegue/LANraragi/actions/workflows/push-continuous-integration.yml/badge.svg">](https://github.com/Difegue/LANraragi/actions)
[<img src="https://img.shields.io/discord/612709831744290847">](https://discord.gg/aRQxtbg)

<img src="public/favicon.ico" width="128">  
  
LANraragi
===========

Open source server for archival of comics/manga, running on Mojolicious + Redis.

#### 💬 Talk with other fellow LANraragi Users on [Discord](https://discord.gg/aRQxtbg) or [GitHub Discussions](https://github.com/Difegue/LANraragi/discussions)  

#### [📄 Documentation](https://sugoi.gitbook.io/lanraragi/v/dev) | [⏬ Download](https://github.com/Difegue/LANraragi/releases/latest) | [🎞 Demo](https://lrr.tvc-16.science) | [🪟🌃 Windows Nightlies](https://nightly.link/Difegue/LANraragi/workflows/push-continous-delivery/dev) | [💵 Sponsor Development](https://ko-fi.com/T6T2UP5N)  | [🉐 Buy Stickers!](https://ko-fi.com/s/9e8cf6a479)

<a href="https://hosted.weblate.org/engage/lanraragi/">
<img src="https://hosted.weblate.org/widget/lanraragi/multi-auto.svg" alt="Translation status" />
</a>  

<sub>LANraragi uses Weblate for translation hosting.</sub>  

## Screenshots  

|Main Page, Thumbnail View | Main Page, List View |
|---|---|
| [![archive_thumb](./tools/Documentation/.gitbook/assets/archive_thumb.png)](https://raw.githubusercontent.com/Difegue/LANraragi/dev/tools/Documentation/.gitbook/assets/archive_thumb.png) | [![archive_list](./tools/Documentation/.gitbook/assets/archive_list.png)](https://raw.githubusercontent.com/Difegue/LANraragi/dev/tools/Documentation/.gitbook/assets/archive_list.png) |

|Archive Reader | Reader with overlay |
|---|---|
| [![reader](./tools/Documentation/.gitbook/assets/reader.jpg)](https://raw.githubusercontent.com/Difegue/LANraragi/dev/tools/Documentation/.gitbook/assets/reader.jpg) | [![reader_overlay](./tools/Documentation/.gitbook/assets/reader_overlay.jpg)](https://raw.githubusercontent.com/Difegue/LANraragi/dev/tools/Documentation/.gitbook/assets/reader_overlay.jpg) |

|Configuration | Plugin Configuration |
|---|---|
| [![cfg](./tools/Documentation/.gitbook/assets/cfg.png)](https://raw.githubusercontent.com/Difegue/LANraragi/dev/tools/Documentation/.gitbook/assets/cfg.png) | [![cfg_plugin](./tools/Documentation/.gitbook/assets/cfg_plugin.png)](https://raw.githubusercontent.com/Difegue/LANraragi/dev/tools/Documentation/.gitbook/assets/cfg_plugin.png) |

## Features  

* Stores your comics in archive format. (zip/rar/targz/lzma/7z/xz/cbz/cbr/cbw/pdf supported, barebones support for epub)  

* Read archives directly from your web browser: the server reads from within compressed files using temporary folders.

* Read your archives in dedicated reader software using the built-in OPDS Catalog (now with PSE support!)

* Use the Client API to interact with LANraragi from other programs (Available for [many platforms!](https://sugoi.gitbook.io/lanraragi/v/dev/advanced-usage/external-readers))

* Two different user interfaces : compact archive list with thumbnails-on-hover, or thumbnail view.

* Localized interface with 11 languages.  

* Choose from 5 preinstalled responsive library styles, or add your own with CSS.  

* Add various types of metadata to archives: Full Tag support with Namespaces, Summaries, Chapters, per-page Overlays.

* Store archives in Categories and/or Tankoubons to sort your Library easily

* Import metadata using Plugins automatically when archives are added to LANraragi.

* Download archives from the Internet directly to the server, while using the aforementioned automatic metadata import

* Scan for duplicates within your saved archives

* Backup your database as JSON to carry your tags over to another LANraragi instance.

</details>
