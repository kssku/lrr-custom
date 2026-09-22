# lrr-custom

> **本仓库是 [Difegue/LANraragi](https://github.com/Difegue/LANraragi) 的个人 fork**，
> 面向「**超大归档库 + 网盘 FUSE 远程存储**」场景做了深度性能改造。
> 上游原始内容（徽章、截图、特性列表）保留在下方。

---

## 我为什么做这个 fork

我有一台自建的漫画库：**十万级归档**（cbz），全部放在**网盘**上，
通过第三方挂载工具映射为 FUSE 目录给容器只读访问。

直接跑官方版会撞上四个致命问题 —— 它们都源于同一个前提：
**官方假设「库在本地磁盘、规模几千本」**，而我的场景是「远程 FUSE、十万级」。

| 官方假设 | 我的现实 | 后果 |
|---|---|---|
| `compute_id` 读文件内容算 SHA-1 | FUSE 上每个文件读 512KB ≈ **数百毫秒** | 全库扫描要**几十小时** |
| `KEYS` 全库扫描可接受 | 十万级 ID 键 / 数十万索引键 | 单次请求**数秒到数十秒**，worker 被判死重启 |
| Shinobu 文件监听可用 | FUSE 遍历直接卡死 | 服务不可用 |
| ID 用镜像内绝对路径哈希 | 换机器/换挂载点 | **全库 ID 失效** |

**这个 fork 的目标：把 LANraragi 改造成「超大库 + FUSE 存储」也能流畅跑。**

---

## 我改了什么（四个核心思路）

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

---

## 效果

| 场景 | 官方上游 | 本 fork |
|---|---|---|
| 全库 ID 计算 | 数十小时（FUSE 读内容）| **分钟级**（只哈希路径）|
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

**镜像**：不是官方 `difegue/lanraragi`，而是自建镜像。

**关键环境变量**：

| 变量 | 值 | 作用 |
|---|---|---|
| `LRR_DISABLE_SHINOBU` | `1` | **禁用文件监听**（FUSE 上会卡死）|
| `LRR_CONTENT_DIR` | `<content 根目录>` | 内容根目录 |

**网盘挂载**（只读）：

```yaml
- <宿主 FUSE 路径>:<容器 content 子目录>:ro,rshared
```

**override 补丁机制**（因为镜像代码烤死、无 Dockerfile）：

```yaml
- <宿主 override 路径>/Utils/Database.pm:<容器 lib 路径>/Utils/Database.pm:ro
```

> 详细部署配置见 [`FORK_CHANGES.md`](./FORK_CHANGES.md) 的「(B) 部署层面的改动」。

---

## 与上游同步时必看

本 fork 基于官方 `dev` 分支。**merge 上游时，以下文件有本地改动，必须逐行比对**：

- `lib/LANraragi/Utils/Database.pm` ← `compute_id` + `arcids_idx`
- `lib/LANraragi.pm` ← `LRR_DISABLE_SHINOBU` + 禁用自动重建索引
- `lib/LANraragi/Model/Search.pm` ← 缓存软失效 + `KEYS`→`SCAN`
- `lib/LANraragi/Model/Archive.pm` ← 分页下推
- `lib/LANraragi/Controller/Api/Archive.pm` ← `start` 参数语义
- `lib/LANraragi/Controller/Category.pm` ← 取消服务端全量渲染

**特别是 `compute_id`** —— 如果上游改动覆盖了它，全库 ID 会全部失效。

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
