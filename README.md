# lrr-custom

> **本仓库是 [Difegue/LANraragi](https://github.com/Difegue/LANraragi) 的个人 fork**，
> 面向「**超大归档库 + 网盘 FUSE 远程存储**」场景做了深度性能改造。
> **自 2026-10-03 起独立维护，不再 merge 官方上游**（未配置 `upstream` remote）。
> 上游原始内容（徽章、截图、特性列表）保留在下方。

## 📖 项目文档导航

| 文档 | 内容 |
|---|---|
| **[`PROJECT.md`](PROJECT.md)** | **唯一权威总纲** —— 架构 / 数据流 / 部署 / 运维 / 性能基线 / 技术债 / 待办 |
| [`DEPLOY.md`](DEPLOY.md) | **部署手册** —— 最小 compose、已发布镜像、代理依赖、常见问题排查 |
| [`FORK_CHANGES.md`](FORK_CHANGES.md) | 相对官方上游改动的**逐条技术说明**（含原因与实测数据；文件清单见 `PROJECT.md` §8） |
| [`CHANGELOG.md`](CHANGELOG.md) | 版本变更记录（Keep a Changelog 格式） |
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

> **2026-10 更新**：Shinobu 首扫的底层实现已从 `File::Find` 改为
> `readdir` 平铺扫描（`_scan_archives()`），避开 `File::Find` 对**每个条目**
> 做 `-d` 判断所触发的 FUSE `stat`。容器内经 bind mount 实测：
> 旧实现单个分片（26,417 文件）**120 秒都跑不完**；新实现 **6.8 秒**，
> 全库 20 个目录（**254,133 文件**）**55 秒**。见下方「思路 5」。

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
- **索引缺失时自动回退 `KEYS` 并就地重建索引** → 全新部署自愈，无需手工迁移

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

**扫描实现：`_scan_archives()`（`lib/Shinobu.pm`）**

原实现用 `File::Find`，它对**每个条目**做一次 `-d` 判断（即一次 `stat`）。
在 FUSE 上这是致命的：容器内经 bind mount 单条目元数据成本约 **31.8 ms**，
26,417 个文件的分片要 **14 分钟以上**。

新实现先用 `readdir` 一次取全部条目名，再用 `is_archive()` 正则判断。
该正则要求以 `.<扩展名>` 结尾，**永远不匹配目录名**，所以命中即为归档、
**零 `stat`**；只有未命中时才做一次 `-d` 决定是否递归。

**新增 `LRR_SHINOBU_WATCH_DIRS` —— 作用域监听**：

- **冒号分隔**，可绝对路径也可相对 `content/` 根
- **不设** = 自动枚举 content 根的一级子目录作为作用域（推荐）
- **设空串 `""`** = watcher 启动但**空转**（逃生开关）
- 传 `content/` 本身会被拒绝（避免退化成全库扫描）
- 例：`wnacg:pika`（**配顶层来源目录，不要配到叶子分片**）

> ⚠️ **不要配到叶子分片**（如 `wnacg/1-50000`）。`enumerate_units` 会把该目录下
> 的 2.6 万个归档文件当成「单元」逐个处理。配**顶层来源目录**才能让它按分片分批。

**实测**：

| 项 | 环境 / 样本 | 结果 |
|---|---|---|
| 首次扫描（旧 `File::Find`）| 容器内 bind mount / 单分片 26,417 文件 | **>120 秒未完成** |
| 首次扫描（新 `_scan_archives`）| 容器内 bind mount / 单分片 26,417 文件 | **6.8 秒** |
| 首次扫描（新实现，全库）| 容器内 bind mount / 20 目录 254,133 文件 | **55 秒** |
| 之后增量 | — | **全靠 inotify**，零额外成本 |
| 新文件入库 | — | 写入后 **~2 秒**自动入库 |
| 删除 | — | 清 filemap、**保留 db0 孤儿**（上游行为）|

---

## 效果

| 场景 | 官方上游 | 本 fork |
|---|---|---|
| 全库 ID 计算 | 数十小时（FUSE 读内容）| **分钟级**（只哈希路径）|
| 全库扫描（Shinobu）| 卡死 / 数小时 | **55 秒**（254,133 文件 / 容器内实测）|
| 增量入库 | 不支持（已禁用）| **inotify 实时，~2 秒** |
| `/api/archives?start=0` | 秒级 | **亚秒级** |
| `/api/archives`（省略 start）| **数十秒**（worker 被判死）| **亚秒级** |
| 分类页渲染 | **分钟级 / 十几 MB** | 前端分页，**秒级** |
| 首次搜索 | 数十秒 | **十几秒** |
| 搜索缓存命中 | 几乎不命中 | **亚秒级** |
| 启动索引重建 | **十几分钟**且循环重跑 | **禁用**，手动触发 |
| ID 跨机器稳定性 | **失效** | **稳定** |

---

## 部署要点（与官方不同的地方）

**镜像**：不是官方 `difegue/lanraragi`，而是自建镜像（`lrr-custom:v15`，基于
`tools/build/docker/Dockerfile`）。**已发布到 Docker Hub**：

```bash
docker pull kssku123/lrr-custom:v15     # 或 :latest
```

**开箱即用的 compose（标准模板，复制即可用）**：

只改一处 —— `volumes` 里第一行的 `/path/to/your/comics`，指向你的漫画目录。
其余路径都是相对路径，数据留在 compose 同目录下的 `./data/`。

```yaml
# =============================================================================
# lrr-custom —— 开箱即用的 compose 文件
# -----------------------------------------------------------------------------
# 使用已发布镜像 kssku123/lrr-custom:v15，挂载即用。
#
# 特点：
#   - 不需要设置 LRR_SHINOBU_WATCH_DIRS —— 未设时自动探测 content 下的一级子目录
#   - content 挂载不需要 :ro（可以加），但绝对不要加 rshared
#   - 首次启动会自动探测目录、扫描入库、建立搜索索引，需要等一会儿
#
# 快速开始：
#   1. 改下面三处 <...> 路径
#   2. docker compose up -d
#   3. 打开 http://<你的IP>:3000
#
# 详细说明见 DEPLOY.md
# =============================================================================
services:
  lanraragi:
    image: kssku123/lrr-custom:v15
    container_name: lanraragi
    restart: unless-stopped
    ports:
      # 左边是宿主端口，按需改（想避开已占用的 3000 就改成 3010:3000）
      - "3000:3000"
    environment:
      # 内容根目录（容器内路径，不要改）
      LRR_DATA_DIRECTORY: /home/koyomi/lanraragi/content

      # 启用 Shinobu 自动扫描
      LRR_DISABLE_SHINOBU: "0"

      # -----------------------------------------------------------------------
      # 扫描范围：**默认不设**，会自动探测 content 下的一级子目录。
      # 只有当你只想扫其中某几个目录时，才取消下面这行的注释并填写。
      # 多个目录用冒号分隔，例如："wnacg:pika"
      # 注意：填 content/ 本身会被拒绝（防退化成全库扫描）
      # -----------------------------------------------------------------------
      # LRR_SHINOBU_WATCH_DIRS: ""

      # 扫描批处理参数（默认即可；扫得慢可调大 BATCH_SIZE）
      LRR_SHINOBU_BATCH_SIZE: "20"
      LRR_SHINOBU_BATCH_SLEEP: "2"

      # 懒生成缩略图：列表页/入库不生成，只在打开阅读器时生成。
      # 网盘（FUSE）上强烈建议保留此设置，否则入库会非常慢。
      LRR_THUMBNAIL_MODE: lazy

      # FUSE 挂载点上禁止自动递归修权限（会挂起容器）
      LRR_AUTOFIX_PERMISSIONS: "-1"

      # 容器内运行身份；如宿主目录属主不同，改这两个值
      LRR_UID: "9001"
      LRR_GID: "9001"

      LRR_NETWORK: "http://*:3000"
      TZ: Asia/Shanghai
    volumes:
      # -----------------------------------------------------------------------
      # ⚠️ 下面第一行必须改成你自己的路径，否则容器起不来。
      # 其它路径都是相对路径（./data/...），数据会留在本 compose 同目录下。
      # -----------------------------------------------------------------------

      # 你的漫画目录 —— 必须改成绝对路径，例如 /vol1/1000/comics
      # 可以是一整个大目录，里面放多个子目录（会自动探测）
      - /path/to/your/comics:/home/koyomi/lanraragi/content

      # 数据目录（Redis 数据库、缩略图、插件）—— 必须持久化
      - ./data/database:/home/koyomi/lanraragi/database
      - ./data/thumb:/home/koyomi/lanraragi/thumb
      - ./data/sideloaded:/home/koyomi/lanraragi/lib/LANraragi/Plugin/Sideloaded
      - ./data/managed:/home/koyomi/lanraragi/lib/LANraragi/Plugin/Managed
    healthcheck:
      test:
        - CMD
        - wget
        - "--quiet"
        - "--tries=1"
        - "--no-check-certificate"
        - "--spider"
        - "-Y"
        - "off"
        - http://127.0.0.1:3000
      interval: 30s
      timeout: 10s
      retries: 3
```

> 同一份文件也在仓库根 [`docker-compose.yml`](docker-compose.yml)，可直接
> `git clone` 后 `docker compose up -d`。**两处内容必须保持一致** ——
> 修改 compose 时请同时更新这里和仓库根文件。
> 完整部署说明（含网盘挂载、代理依赖、故障排查）见 [`DEPLOY.md`](DEPLOY.md)。

**关键环境变量**：

| 变量 | 值 | 作用 |
|---|---|---|
| `LRR_DISABLE_SHINOBU` | — | **设 `1` 才禁用**；不设或设 `0` 均启用监听（扫描已改为零 stat，FUSE 上可用）|
| `LRR_SHINOBU_WATCH_DIRS` | `<来源目录列表>` | **作用域监听**，冒号分隔。**不设**＝自动枚举 content 根一级子目录；**设空串 `""`**＝显式禁用扫描。**配顶层目录，不要配叶子分片**（见下）|
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

> ⚠️ **`override` 补丁机制（bind mount 单文件覆盖）已于 v3 废弃，不要再使用。**
> 修复已进镜像；仓库内不存在 `override/` 目录。历史上那个
> `docker/lrr/override/Database.pm` 是**孤儿文件** —— 无任何路径引用它，
> 内容也已落后于仓库版本。**照抄旧文档建这个目录不会生效。**
> 要改行为就改仓库代码、重建镜像。完整核实结论见
> [`FORK_CHANGES.md`](./FORK_CHANGES.md) §(B)4、[`PROJECT.md`](./PROJECT.md) §5。

> 详细部署配置见 [`FORK_CHANGES.md`](./FORK_CHANGES.md) 的「(B) 部署层面的改动」。

**重建镜像**（v3 已可用）：

```bash
docker build -f tools/build/docker/Dockerfile -t lrr-custom:v15 .
```

> v2 的 `perl5` 属主坑已在 `99c08815` 于 Dockerfile 内预建目录修根，
> 不再需要构建后补 `chown`。

---

## 与上游的关系：独立维护

**本 fork 自 2026-10-03 起独立维护，不再 merge 官方上游。** 远程只有
`origin`（`kssku/lrr-custom`），未配置 `upstream`，历史为单根。

上游新特性**不自动流入**；确需某个上游修复时**手工挑选、单独提交**。

以下是**最高危的两处**，被上游实现覆盖会立刻出问题：

| 文件 | 为什么危险 |
|---|---|
| `lib/LANraragi/Utils/Database.pm` | **`compute_id`** 被覆盖 ⇒ **全库 ID 全部失效** |
| `lib/Shinobu.pm`（在 `lib/` 顶层，**不是** `Model/` 下）| 若恢复「扫描时读文件内容」⇒ FUSE 场景**重新卡死** |

本 fork 相对上游分叉点共有 **22 个实质改动的文件**（含构建/元数据共 25 个），
完整清单见 [`PROJECT.md` §8](PROJECT.md#8-与上游的关系独立维护)。

需要最新列表时**不要手工维护**，直接跑：

```bash
git diff --stat db310690..HEAD -- lib/ public/js/ tools/openapi.yaml
```

---

## 风险提示

**已知脆弱点**：`comic_id` 是 `content/` 之后**整条相对路径**的哈希。
所以路径里任何一段变了，ID 都会变 —— 包括：

| 路径段 | 例 | 变化原因 |
|---|---|---|
| 来源目录 | `wnacg` / `pika` | 新增来源、改名 |
| 分片目录 | `1-50000` | 上游改分片大小 |
| 年份目录 | `2026` | 年份算法变化 |
| 文件名 | `123456.cbz` | 重命名 |

**升级路径**：在 `compute_id` 里剥掉不稳定的路径段（如 `^\d+-\d+$`、`^\d{4}$`）后重跑迁移。
`script/migrate_arcids.pl` 可重建分页索引，但**不改变 ID 本身** —— ID 迁移需另行处理。

---

---

## 许可证

本项目遵循上游的 **MIT License**，见 [`LICENSE`](LICENSE)（版权归原作者
[Difegue](https://github.com/Difegue) 所有，fork 改动同样以 MIT 发布）。

上游项目：[Difegue/LANraragi](https://github.com/Difegue/LANraragi)

