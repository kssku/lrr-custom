# lrr-custom 部署手册

> 📖 本文档面向 **拿到镜像、要把它跑起来的人**。
> 想了解「为什么这么改」，读 [`PROJECT.md`](PROJECT.md)；
> 想了解「相对官方上游改了什么」，读 [`FORK_CHANGES.md`](FORK_CHANGES.md)。

---

## 0. 一句话说明

**准备一个 Docker 镜像、一份 compose 文件、三个目录，就能跑起来。**

```
┌─────────────────────────────────────────────────┐
│  你的宿主机                                       │
│                                                   │
│  /你的归档目录      ← 漫画文件（cbz/zip/rar）      │
│  /你的数据目录      ← 入库结果 + 缩略图（要持久化） │
│  /你的插件目录      ← 你自己的元数据插件（可选）   │
│                                                   │
│         ↓ 挂载到容器 ↓                            │
│                                                   │
│  docker-compose.yml + 镜像 lrr-custom:vX          │
└─────────────────────────────────────────────────┘
```

---

## 1. 你需要准备什么

| # | 项 | 说明 |
|---|---|---|
| 1 | **Docker 环境** | Docker Engine 20+ / Docker Compose v2 |
| 2 | **镜像** | `lrr-custom:vX`（用 `docker load` 导入，或自行构建，见 §6） |
| 3 | **归档目录** | 存放漫画文件的目录，可只读挂载 |
| 4 | **数据目录** | 空目录即可，用来持久化入库结果与缩略图 |
| 5 | **插件目录**（可选） | 你自己的元数据插件，见 §5 |

**不需要准备的东西**：

- ❌ 不需要预先建索引 —— 索引由 LRR 自己生成（见 §4）
- ❌ 不需要导入数据库 —— 入库是自动的
- ❌ 不需要 SQLite 元数据库 —— 那是插件的事，见 §5

---

## 2. 目录结构

建议的宿主机布局（路径可任意，但要一致）：

```
/your/path/
├── docker-compose.yml        # 从本仓库 tools/build/docker/ 取模板
├── data/
│   ├── database/             # Redis RDB（入库结果，必须持久化）
│   ├── thumb/                # 缩略图缓存（可删，会重建）
│   └── sideloaded/           # 你的插件放这里（可选）
└── content/                  # 归档目录（或指向已有的）
```

**必须持久化的只有 `database/`**：

| 目录 | 丢了会怎样 |
|---|---|
| `database/` | 🔴 **入库结果全丢，要重新扫描**（十万级库约 2 小时） |
| `thumb/` | 🟢 缩略图会按需重建，只是首次浏览变慢 |
| `sideloaded/` | 🟡 插件要重新放，但如果插件有源码就不是问题 |

---

## 3. 配置与启动

### 3.1 最小 compose 文件

```yaml
services:
  lrr:
    image: lrr-custom:v14          # ← 你的镜像标签
    container_name: lrr
    restart: unless-stopped
    ports:
      - "3010:3000"               # ← 左边改你想要的外部端口
    environment:
      # 内容根目录（容器内路径，不要改）
      LRR_DATA_DIRECTORY: /home/koyomi/lanraragi/content

      # 启用文件监听（本 fork 已改为纯路径扫描，FUSE 上可用）
      LRR_DISABLE_SHINOBU: "0"

      # ⚠️ 作用域监听：冒号分隔，写「顶层目录」，不要写叶子分片
      #    留空 = watcher 空转，什么都不扫
      LRR_SHINOBU_WATCH_DIRS: "你的顶层目录名"

      # 懒生成缩略图：首次在阅读器打开时才做（强烈建议）
      LRR_THUMBNAIL_MODE: lazy

      # FUSE 网盘上必须设 -1，否则权限修正会挂起
      LRR_AUTOFIX_PERMISSIONS: "-1"

      LRR_UID: "9001"
      LRR_GID: "9001"
      TZ: Asia/Shanghai
    volumes:
      # ← 左边全部改成你的路径
      - ./data/database:/home/koyomi/lanraragi/database
      - ./data/thumb:/home/koyomi/lanraragi/thumb
      - ./data/sideloaded:/home/koyomi/lanraragi/lib/LANraragi/Plugin/Sideloaded
      # 归档目录（只读即可）
      - ./content:/home/koyomi/lanraragi/content:ro
```

### 3.2 三个必须改的地方

| 项 | 改什么 |
|---|---|
| `image:` | 换成你的镜像标签 |
| `ports:` | 换成没被占用的端口 |
| `volumes:` 左边 | 换成你的实际路径 |

### 3.3 `LRR_SHINOBU_WATCH_DIRS` 怎么填

**这是最容易配错的一项。** 规则：

```
填「归档目录的直接子目录名」，冒号分隔。
```

举例，如果你的 `content/` 长这样：

```
content/
├── wnacg/
│   ├── 1-50000/
│   ├── 50001-100000/
│   └── ...
├── pika/
│   ├── 2016/
│   └── 2017/
└── other/
```

那么填：

```yaml
LRR_SHINOBU_WATCH_DIRS: "wnacg:pika:other"
```

**❌ 不要填** `wnacg/1-50000` 这种叶子分片 —— 会让扫描退化成逐文件 `stat`，在网盘上慢几十倍。

**❌ 不要留空** —— 留空则 watcher 什么都不扫。

### 3.4 启动

```bash
docker compose up -d
docker compose logs -f lrr      # 看扫描进度，Ctrl+C 退出日志不影响运行
```

服务起来后访问 `http://你的IP:3010`。

---

## 4. 首次启动后：等入库完成

首次启动会自动扫描 `LRR_SHINOBU_WATCH_DIRS` 指定的目录并入库。

**规模参考**（十万级库、FUSE 网盘）：

| 归档数 | 耗时 |
|---|---|
| 1 万 | 约 5 分钟 |
| 10 万 | 约 50 分钟 |
| 28 万 | 约 2.4 小时 |

看进度：

```bash
docker exec lrr valkey-cli -n 0 ZCARD arcids_idx    # 已入库数，持续增长 = 在入库
```

**归档是逐本实时可见的**：每入库一本就立即写进 `arcids_idx`，列表接口立刻能查到。
不需要等全部扫完才看得到，刷新页面即可看到数量增长。

### 搜索索引：首次启动自动建立，无需手动操作

界面的搜索、统计和「共 N 件瑰宝」计数都读**搜索索引库**（db3）。
索引不存在时，`do_search()` 会直接返回 `(-1, -1)`，界面表现为
「共 -1 件瑰宝」加轮播报错。

索引由 `build_stat_hashes()` 生成，而这个函数在本 fork 中没有自动触发点
（原因见 `PROJECT.md` §9）。为避免每个新部署都要手动补一步，
容器现在通过 s6 一次性服务 `index-init` **在启动时自动处理**：

| 情况 | 行为 |
|---|---|
| 索引已存在（`LAST_JOB_TIME` 有值） | 立即跳过，不耗时 |
| 索引缺失（全新部署） | 自动重建一次 |

重建耗时与**当时已入库的归档数**成正比：库满时约 39,766 本 / 94 秒，
但全新部署首次启动时库还是空的，这一步几乎瞬时完成（日志里会看到一句
`arcids_idx is missing; falling back to a full KEYS scan`，扫的是空库，属正常）。

> **`index-init` 只保证界面不显示「共 -1 件」，不等于索引已经装满数据。**
> 真实的索引条目由 Shinobu 入库时**实时增量写入** db3（`LRR_STATS`、
> `INDEX_date_added:*`、`LRR_UNTAGGED` 随入库同步增长），不需要等全量重建。
> 因此首次入库期间界面计数会从 0 开始稳步上涨，这是预期行为。
> 若要在**批量入库全部完成后**立刻刷新一次统计口径，按下方命令手动重建。

它依赖 redis 启动、先于 lanraragi 运行，因此**不会**出现「界面已可访问但 `LAST_JOB_TIME` 还没写入」的窗口。
重建失败不会阻止容器启动，只在日志中告警。

**手动重建**（例如索引损坏、或入库完成后想立即刷新统计）：

```bash
docker exec -u koyomi lrr perl /home/koyomi/lanraragi/script/rebuild_stats.pl
```

> ⚠️ **必须带 `-u koyomi`。** 以 root 运行会用 root 重建 `lanraragi.log`，
> 之后以 koyomi 运行的 Web 服务将无法写入日志，**每个请求都会返回 500**。
> `rebuild_stats.pl` 内置了 root 检测，误用会直接报错而不是静默破坏。

**验证索引状态**：

```bash
docker exec lrr valkey-cli -n 3 GET LAST_JOB_TIME      # 返回数字 = 正常
```

**查看自动初始化日志**：

```bash
docker logs lrr 2>&1 | grep index-init
```

正常输出为 `Search index already present; nothing to do.` 或 `Search index built.`

返回 JSON 且含 `data` 数组 → ✅ 可以用了。

---

## 5. 插件（可选）

本 fork **不含任何自制插件** —— 插件由你自己提供。

### 放置位置

```
宿主机 ./data/sideloaded/你的插件.pm
   ↓ 挂载到
容器 /home/koyomi/lanraragi/lib/LANraragi/Plugin/Sideloaded/
```

### 插件必须满足的约定

| 项 | 要求 |
|---|---|
| **包名** | `LANraragi::Plugin::Sideloaded::<文件名>` —— **包名必须和文件名一致**，否则不会被加载 |
| **类型** | 元数据插件放 `Sideloaded/`，脚本插件也放这里 |
| **外部数据** | 如果插件要读外部索引/数据库，用 **额外的只读挂载**，不要放进镜像 |
| **重载** | 改插件后需要重启容器（`docker compose restart lrr`） |

### 如果需要挂载外部数据

在 compose 里加一行：

```yaml
    volumes:
      - /你的索引目录:/opt/你的数据:ro      # ← 只读
```

然后插件里用 `/opt/你的数据/...` 访问。

---

## 6. 构建镜像（如果你想自己构建）

本仓库自带 Dockerfile：

```bash
cd /path/to/lrr-custom
docker build -f tools/build/docker/Dockerfile -t lrr-custom:v8 .
```

**注意**：构建上下文必须是**仓库根目录**（`.`），因为 Dockerfile 里引用了 `/lib`、`/public`、`/templates` 等。

### 改了代码要重新构建

**这一点非常重要** —— 镜像里的代码是**构建时的快照**：

| 你改了什么 | 需要做什么 |
|---|---|
| `lib/**/*.pm`（后端） | 重新构建镜像 |
| `public/js/**/*.js`（前端） | 重新构建镜像 |
| `templates/**` | 重新构建镜像 |
| `docker-compose.yml` 里的环境变量 | 只需 `docker compose up -d` |
| `sideloaded/` 里的插件 | 只需 `docker compose restart lrr` |

**❌ 改了 `public/js/` 却只重启容器 = 改动不生效。** 因为 `public/` 不在 compose 的挂载表里。

---

## 7. 常见问题

### 界面显示「共 -1 件瑰宝」、列表空白

**原因**：搜索索引缺失——`LAST_JOB_TIME` 在 db3 里不存在，`do_search()` 直接返回 `(-1,-1)`。

正常情况下 `index-init` 服务会在启动时自动建立索引，所以先看它是否失败：

```bash
docker logs lrr 2>&1 | grep index-init
docker exec lrr valkey-cli -n 3 GET LAST_JOB_TIME
```

**解决**：手动重建（**注意 `-u koyomi`**）：

```bash
docker exec -u koyomi lrr perl /home/koyomi/lanraragi/script/rebuild_stats.pl
```

索引建立后刷新页面即可。注意**入库尚未结束时索引是不完整的**——
如果库很大，等扫描跑完再重建一次，计数才准确。

### 扫描很慢 / 卡住

**原因**：`LRR_SHINOBU_WATCH_DIRS` 配成了叶子分片。

**解决**：改成顶层目录名（见 §3.3）。

### 列表页浏览时磁盘/网盘负载高

**原因**：前端在为每个归档请求缩略图。

**排查**：

```bash
docker exec lrr sh -c 'valkey-cli -n 0 KEYS "thumbfail:*"'   # 有无失败计数
```

**说明**：本 fork 已把列表页的主动请求去掉（`no_fallback` 修复）。如果你的镜像构建于该修复之前，需要重新构建。

### 容器启动后立刻退出

看日志：

```bash
docker compose logs lrr | tail -50
```

常见原因：归档目录路径写错、权限不足（`LRR_UID`/`LRR_GID` 与宿主机目录属主不符）。

### 列表页封面一直是占位图（打开过也不刷新）

**现象**：列表页/轮播的封面全是灰色 `noThumb.png`；强刷（Ctrl+F5）也没用；只有极个别归档有真封面。

**根因（两层，第一层才是主因）**

**第一层：本 fork 里没有任何路径会自动生成封面。**

上游原本有三条生成封面的路径，这个 fork 全部移除了：

| 路径 | 本 fork 的状态 |
|---|---|
| `Shinobu.pm` 入库时提取封面 | ❌ 已移除（避免入库时在 FUSE 上开压缩包） |
| 前端列表页发 `no_fallback=true` | ❌ 已移除（避免列表页为每个归档排队、批量读盘） |
| `page_thumbnails` 任务 | ⚠️ 原注释写「封面应已由别处高分辨率处理」，但那个「别处」正是上面前两条 |

结果：`serve_thumbnail` 不带 `no_fallback` 时直接返回占位图且**不入队**；而唯一会入队的 `no_fallback=true` 前端从不发送。所以除了手工调 API，封面永远不会生成。

另外 `generate_page_thumbnails` 的入队判定只检查第 `1..pagecount` 页，**从不检查封面**。于是「页面缩略图已存在、唯独封面缺失」的归档会一直返回 `No job queued, all thumbnails already exist.`，任务永远不入队。

**第二层：占位图与真封面共用 URL，且无缓存头。**

列表页封面 URL 固定为 `/api/archives/<id>/thumbnail`，**没有 cachebust**。若响应不带 `Cache-Control`，浏览器会启发式缓存那个占位图响应，之后真封面生成了也继续用缓存。

**解决**：升级到 `v9` 或更新。该版本的三处改动：

1. `Minion.pm` — `page_thumbnails` 任务**顺带生成封面（page 0）**。打开阅读器是唯一确定用户在意这本的时机，且归档本就已打开，多抽首页几乎不增加远程开销；列表页仍不批量触发。
2. `Archive.pm` `generate_page_thumbnails` — 入队判定**纳入封面文件**，覆盖「页面齐全但封面缺失」的情况。
3. `Archive.pm` `serve_thumbnail` — 两个分支都加缓存头：

| 响应 | 头 |
|---|---|
| 真封面 | `Cache-Control: no-cache`（可缓存，但每次回源校验） |
| 占位图 | `Cache-Control: no-store, must-revalidate`（禁止缓存） |

即：**打开一次阅读器，该归档的封面就会生成并落盘**，回到列表页即可看到（列表页本身不触发批量生成，这是刻意保留的设计）。

验证：

```bash
ID=<某个从未打开过的归档 id>

# 1) 模拟阅读器打开：先取文件列表（会回写 pagecount）
curl -s "http://127.0.0.1:3011/api/archives/$ID/files" -o /dev/null

# 2) 请求页面缩略图 → 应返回 job id（修复前是 "No job queued, all thumbnails already exist."）
curl -s -X POST "http://127.0.0.1:3011/api/archives/$ID/files/thumbnails"

# 3) 几秒后封面应落盘：<数据目录>/thumb/<前两位>/<id>.jpg
ls -la <数据目录>/thumb/${ID:0:2}/ | grep "$ID"

# 4) 缓存头
curl -sI "http://127.0.0.1:3011/api/archives/deadbeef/thumbnail" | grep -i cache-control
# → no-store, must-revalidate
```

### 缩略图全部生成失败（`thumb/` 目录 Permission denied）

**现象**：日志出现

```
mkdir /home/koyomi/lanraragi/thumb/XX: Permission denied
```

阅读器里页面缩略图空白，封面也一直是占位图；但归档列表、阅读正文、搜索都正常——所以**看起来像前端 bug，实际是权限问题**。

**原因**：`thumb/`、`Sideloaded/`、`Managed/` 是**容器自己的数据目录**，不是远程内容卷。当宿主侧用一个新建的空目录 bind-mount 覆盖它们时，容器会继承那个挂载点的权限（常见是 `000`，属主为宿主用户），而 LRR 以 `koyomi`（9001）运行，连 `ls` 都做不了。

**v8 之前的坑**：修复这三处的代码被放在 `if [ "$FIX_PERMS" -eq 1 ]` 块里，而远程内容卷场景下用户会设 `LRR_AUTOFIX_PERMISSIONS=-1` 以避免 FUSE 挂起——于是**关掉内容卷修复的同时，静默地关掉了容器自有目录的修复**。

**解决**：升级到 `v8` 或更新。该版本把这三处的 `mkdir -p` + `chown` + `chmod` 移出了开关块，**无条件执行**；内容卷的修复仍然受开关控制，不受影响。

启动日志里会看到：

```
Ensuring container-owned data folders are writable...
Not touching content permissions          # 因为设了 -1，符合预期
```

**为什么现在才修**：`fix-attrs.d/01-lrr-dirs` 这个 s6-overlay 机制本来能做这件事，但它**从未被 Dockerfile COPY 进镜像**（只 COPY 了 `s6-rc.d/` 和 `cont-init.d/`），所以一直是死文件，现已删除，逻辑统一收进 `01-lrr-setup`。

---

## 8. 相关文档

| 文档 | 内容 |
|---|---|
| [`PROJECT.md`](PROJECT.md) | 项目总纲：架构、数据流、Redis 库分配、ID 算法、实测数据、待办 |
| [`FORK_CHANGES.md`](FORK_CHANGES.md) | 相对官方上游的逐条改动（代码 + 部署） |
| [`README.md`](README.md) | 项目简介 |

---

## 附：环境变量速查

### 本 fork 新增或语义变更

| 变量 | 默认 | 说明 |
|---|---|---|
| `LRR_SHINOBU_WATCH_DIRS` | 空 | 作用域监听目录，冒号分隔。**必填** |
| `LRR_SHINOBU_BATCH_SIZE` | 20 | 每批扫描的 unit 数 |
| `LRR_SHINOBU_BATCH_SLEEP` | 2 | 批间休眠秒数 |
| `LRR_THUMBNAIL_MODE` | `lazy` | `lazy` = 首次在阅读器打开时才生成 |
| `LRR_DISABLE_SHINOBU` | 0 | 设为 `1` 完全禁用文件监听 |
| `LRR_SEARCHCACHE_HARD_INVALIDATE` | 0 | 设为 `1` 恢复上游的硬失效行为（逃生开关） |
| `LRR_STRICT_FILE_CHECK` | 0 | 设为 `1` 恢复逐文件存在性检查（FUSE 上很慢） |

### 必须正确设置

| 变量 | 值 | 为什么 |
|---|---|---|
| `LRR_AUTOFIX_PERMISSIONS` | `-1` | FUSE 网盘上权限修正会挂起 |
| `LRR_UID` / `LRR_GID` | `9001` | 与宿主机数据目录属主一致 |
| `LRR_DATA_DIRECTORY` | `/home/koyomi/lanraragi/content` | 内容根（容器内路径） |

> 完整清单见 `PROJECT.md` §4。
