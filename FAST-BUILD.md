# 快速构建与流式回验（1.7.0）

在「工具与目录 → DwarFS 构建方式」选择并保存：

| 方式 | 创建参数 | 构建前检查 | 构建后内容回验 |
|---|---|---|---|
| 快速无压缩 · Skip roundtrip（默认） | `-l 0 --file-hash none --order none` | 大小与 mtime；不重复读源 SHA-256 | 跳过，记录 SKIPPED_FAST / NOT_CHECKED |
| 无压缩 + 流式 roundtrip | 同上 | 大小与 mtime | 解包流逐文件与 ingest SHA-256 比较 |
| 压缩 + 流式 roundtrip | GUI 设 level 7，保留内部去重 | 源 SHA-256 | 同上 |

CLI 使用 archive.config.json 中 `dwarfs.build_profile`（fast / verified）与 `dwarfs.skip_roundtrip`（true / false）。fast 强制 level 0；verified 使用 compression_level。没有新字段的旧配置沿用完整校验。不要设置 verified + skip_roundtrip=true，GUI 不提供这个组合。

DwarFS 0.15.7 官方本机 `mkdwarfs -H` 明确列出 level 0 的 block/schema/history/metadata 都为 null、窗口为 0、order 为 none。内部去重默认使用 xxh3-128；本工具快速模式关闭这次内部去重 hash。初始 ingest 的 SHA-256 仍作为恢复清单；构建前只做元数据预检，并不声称它证明字节未变化。

镜像仍执行 dwarfsck --check-integrity，记录退出码和镜像 SHA-256。同卷 staging 把重复的链接前/链接后镜像 hash 合并到封存时的一次检查，封存仍必须与构建哈希一致。刻后校验已计算的镜像 SHA-256 传给完整性检查报告，不再在同一步重算。实际恢复和删除源门槛保留。

## 流式 roundtrip

数据流：dwarfsextract（pax 写标准输出）→ 有界管道 → tar 消费器 → 每文件 SHA-256 → 丢弃内容。

传输端复用 1 MiB 缓冲区，哈希端复用 1 MiB 缓冲区；tar 自身缓冲 64 KiB，DwarFS block cache 64 MiB。不会创建完整 tar、roundtrip 文件树或每文件临时文件。清单和已见文件的元数据随文件数量增长，所以不能称整个程序总内存只有 1 MiB。硬链接通过已核验的内容摘要解决，拒绝缺失/额外/重复文件、冲突、符号链接和不可解析的链接。

两个外部进程由同一个 worker 直接持有；停止准备会停止这两个明确的进程并等待管道退出。生产端和校验端都必须正常结束，才记录 roundtrip PASS。流式校验需要 Python 3.10+，只用标准库。

Skip 模式不证明镜像文件内容与 ingest 的每个源 hash 一致，报告写 NOT_CHECKED；需要这项证据时选流式模式。无论哪种模式，刻后回读都不会被跳过，删除源仍要求完整恢复并核对。

既有成功镜像直接复用，不为更改构建方式重新占用盘号。旧版 roundtrip / 失败 staging 不会自动删除。磁盘空间不足时，无压缩构建会在读取源文件前拒绝。
