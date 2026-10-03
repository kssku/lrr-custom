# 变更记录

本文件记录 **lrr-custom**（[Difegue/LANraragi](https://github.com/Difegue/LANraragi) 的个人 fork）
相对自身的变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

> 上游基线版本：**0.9.81 (Atomica)**。
> 本 fork 标识：**Speed of Life**（`package.json` 的 `version_name`，取自 Bowie《Low》1977 开篇曲，
> 延续上游以 Bowie 作品命名版本代号的传统）。
> 本 fork 自 2026-10-03 起**独立维护**，不再 merge 上游；上游改动不自动流入。
> 相对上游的**逐条技术差异**见 [`FORK_CHANGES.md`](FORK_CHANGES.md)。

## [Unreleased]

### 新增
- **独立版本标识**：`package.json` 的 `version_name` 由 `Atomica` 改为 `Speed of Life`，
  `description` 改为本 fork 自己的标语；`tools/openapi.yaml` 的示例值同步。
  `version` **保持 `0.9.81` 不变** —— 它被前端静态资源路由 `/js/:version/*`
  以 `\d+\.\d+\.\d+` 严格匹配（`lib/LANraragi/Utils/Routing.pm:74`），
  任何非「数字.数字.数字」的写法都会让 vendor 资源 404（已实测 `0.9.81+kssku` / `0.9.81-kssku` 均 404）。

### 修复
- **扫描断点写到只读挂载**：`ingest_cursor.json` 此前拼在 `LRR_DATA_DIRECTORY`
  （content 根）下，而生产 content 是**只读 FUSE**，`_save_cursor` 静默失败 ⇒
  断点从未落盘、每次重启从头重扫。移至可写数据目录后实测生效
  （首扫 `2 unit(s) / 0.6s` → 重启 `0 unit(s) / 0.0s`）。

### 变更
- **Shinobu 扫描入库改顺序执行**：移除 `MCE::Loop` 多进程并发
  （`mce_loop { add_new_files(@$_) }` → 顺序 `foreach`），与 Windows 分支及
  Minion 的既有修法统一。消除多进程并发写 Redis（db0/db3）的竞争风险，
  并移除与 Minion 卡死同源的 MCE 机制。实测 6 个归档严格顺序入库，`/proc`
  无 MCE 残留；代价量化约 **2ms/归档**，被 FUSE 遍历成本（数十分钟量级）淹没。

### 新增
- `docker-compose.yml`：开箱即用，引用已发布镜像，content 挂载**不加 `:ro`**
  （本 fork 零环境变量即可运行）。
- `LICENSE`：标准命名的 MIT 许可证（原仅有上游命名的 `COPYING`，
  GitHub 无法自动识别）。
- `.editorconfig`：统一编辑器换行/缩进，减少噪声 diff。
- `CHANGELOG.md`：本文件。
- `DEPLOY.md` §8：已发布镜像与代理依赖（Docker Hub 拉取/发布、mihomo 代理配置）。

### 文档
- `README.md` 标准化：移除内嵌的**上游 README 折叠块**（上游有自己的 README，
  重复且随版本漂移），补文档导航表与许可证段落。
- 四份文档的镜像标签统一为 `lrr-custom:v14`；修正 `FORK_CHANGES.md` 中
  Dockerfile 的行号引用（`COPY /public` 实为第 149 行、`perl5` 修复为第 113-116 行、
  总行数 157 行）。

## 更早的改动（按主题归纳）

以下为本 fork 建立性能改造以来的主要里程碑，非逐提交流水。

### 性能改造（核心五思路）
- **ID 计算不读文件内容**：`compute_id` 从「读 512KB 算 SHA-1」改为
  「只哈希文件路径」，消除全库扫描时每文件的 FUSE 读取开销。
- **ID 不绑定镜像安装路径**：改为哈希 `content/` 之后的**相对路径**，换机器/
  换挂载点后全库 ID 不再失效。
- **分页不再 `KEYS` 全扫**：`arcids_idx` 有序集合 + 分页下推，
  `/api/archives` 从数十秒降到亚秒级。
- **搜索缓存可命中**：软失效 + `KEYS`→`SCAN`。
- **Shinobu 纯路径扫描 + 作用域监听**：`_scan_archives()` 以 `readdir` 平铺
  扫描替代 `File::Find`（后者对每个条目触发 FUSE `stat`）。单分片（26,417 文件）
  从 **120 秒跑不完** 降到 **6.8 秒**；全库 254,133 文件 **55 秒**。

### 稳定性修复
- **Minion 作业卡死**：移除 MCE::Shared，job children 改顺序执行。
- **缩略图懒生成**：`LRR_THUMBNAIL_MODE=lazy`，入库与列表页不生成缩略图，
  仅在阅读器打开时生成，避免 FUSE 上两次读文件拖死增量入库。
- **封面自动生成链路打通**：修复「打开过也不刷新封面」。
- **容器数据目录权限**：无条件修正，避免 uid 9001 启动时权限错误。
- **坏图拦截 + 熔断器**：前端 `no_fallback` 修复。
- **索引首次启动自动建立**：替代「启动时重建且循环重跑」。
- **s6 相关**：`index-init` oneshot 路径修正；s6 可执行位固化进镜像。

### 部署
- **挂载即用**：不设 `LRR_SHINOBU_WATCH_DIRS` 时自动枚举 content 根一级子目录；
  content 挂载**不需要 `:ro`**，零环境变量可运行。
- **镜像发布**：`kssku123/lrr-custom:v14` 与 `:latest` 已推送至 Docker Hub。
- **代理依赖**：直连 `registry-1.docker.io` 超时时，Docker daemon 需走
  `http://127.0.0.1:7890`（见 `DEPLOY.md` §8.3）。