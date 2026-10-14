# 操作规程

1.12.0 修复模拟写入状态阻塞真实刻录：光盘页新增「清除模拟写入」，只删除 `archive_root\simulated\<盘号>` 下的派生副本，保留待刻目录、源文件、盘号、清单和审计记录。切换真实刻碟时，在封包与空白介质预检通过后自动清除纯模拟状态；实体 `WRITTEN`、部分写入或结果不明记录仍保持锁定，真实写入仍须逐盘确认。

1.11.0 新增「接入现成照片盘」：直接使用包含 data 与 00_DISC_CATALOG 的完整硬链接目录，保留原盘号、卷标和索引，不复制照片、不使用 DwarFS。默认预览；首次封包只按原 CSV 哈希核对一遍，支持进度、停止和续做。见 [EXTERNAL-STAGING.md](EXTERNAL-STAGING.md)。


1.10.0：支持同时制作归档 A、刻录归档 B，按归档和光驱互斥，盘号/catalog 使用短时全库锁。下方任务列表可切换日志与停止目标。续做会先跳过已记录写入的盘，快速复用近期完整待刻目录，只制作剩余盘；保留原计划的起始盘号。详见 [CONCURRENCY.md](CONCURRENCY.md)。


1.9.0：封包时校验；7 天内文件大小、修改时间和最终记录一致时复用。光驱/盘片自动检测并下拉选择。刻后回读默认关闭，可手动执行；未写入的 ImgBurn 取消可恢复原盘号待刻。详见 [BURNING.md](BURNING.md)。

## 归档生命周期与可信依据

```
ingest → immutable plan → build (III) → stage/seal
  → real burn → BURNED_UNVERIFIED → register location
                       └→ optional optical verify → VERIFIED
  → full restore test → explicit source deletion

stage/seal → simulated copy → SIMULATED_PASS → test register/restore
                                      ↳ 永远没有原件删除资格
```

`catalog.json` 是主记录，`catalog.sqlite` 是可重建的检索索引。原始 `ingest.json` 的哈希被 plan 固定；staging 内 `SHA256SUMS` 和 `DISC.json` 的哈希由 HDD 上的 catalog 固定；各次 verify 报告的哈希也被 catalog 固定。这可以发现意外修改，不是针对能改写整个 catalog 的攻击者的数字签名系统。

没有后台任务会从 STAGED 自动前进到 BURNING。Agent 是 `archive-agent.ps1 -Command ...` 总入口，共享库处理实际工作；状态只能由对应操作写入，HTTP 不提供任何写接口。建议同一套盘只由一个 archive 根目录管理，不能复制两份 catalog 后各自分配编号。

## 扫描前准备

1. 人工按 I / II / III / M 决定价值类别；脚本不会自动把 RAW 判为废片。
2. 确认 II 的 master 为现存最高质量版本，不再转码来换容量。
3. iPhone 备份必须停止写入；若 Manifest.db 的 WAL/SHM 仍存在，保留整个备份并先确认一致性。脚本会按 `Manifest.db-*` 重复根伴随文件，但不能代替应用一致性检查。
4. 选择不会变动的源目录。扫描中的读错误、文件变化、路径问题直接失败，不生成“部分成功”的 ingest。
5. 准备足够的工作空间。1.6.0 的 III 类直接按文件清单读取原目录，不再制作 shard 输入副本；DwarFS 与同卷 staging 共享数据。1.7.0 构建回验使用有界缓冲流或按配置跳过，不再创建完整临时树；模拟光盘保留独立副本。应为 DwarFS 镜像、PAR2 及模拟预留容量，并逐盘管理工作空间。

本工具保存普通文件内容、文件路径、mtime、空目录；不把 NTFS ACL、EFS、稀疏分配布局等当作已归档。检测到备用数据流（包括 Zone.Identifier）会拒绝 ingest，删除前也会再检查，不静默遗漏。需要完整 NTFS 语义的系统备份应先使用能保留这些语义的备份格式，然后归档该格式。符号链接、junction 和其他 reparse point 明确拒绝，避免跟随到源目录之外。

## 分盘算法和容量

字节与 GiB 不能混淆：`1 GiB = 1,073,741,824 bytes`。默认容量为 BD25 25,025,314,816 字节、BD50 50,050,629,632 字节，作为规划上界；插入盘实际可写扇区仍需在刻录时读取。

```
usable = capacity - reserve
payload_limit = min(configured_payload, floor(usable / (1 + PAR_percent/100)))
DwarFS_input_limit = payload_limit - DwarFS_overhead
normal_file_cost = logical_file_bytes + per_file_overhead
```

默认 BD25 DwarFS payload 21 GiB，先按约 20.75 GiB 原始数据成本规划；BD50 为 44 GiB 和约 43.75 GiB。根 metadata 的完整成本在每个 shard 预先扣除。先将能够容纳的整目录作为单元，过大目录递归细分；单元按大小降序放入首个可容纳盘，稳定保留路径映射。

压缩率按 **1:1** 保守估算，不靠预测“压缩后能放下”来塞满盘。用户已有样例的 original filesystem size 22.47 GiB、compressed block size 22.47 GiB、119873 inodes，说明该备份近乎不可压缩；这是用户提供的样例，未重新读取其原始备份。DwarFS 的收益主要是小文件聚合与每盘独立恢复。

构建后看真实 image size；stage 后重新计算全部数据、PAR2、说明文件、manifest 和估计文件系统开销；IMAPI2 还核对实际生成的 UDF 总扇区数。PAR2 小文件四舍五入、目录元数据、镜像开销都可能超出估计，因此失败时降低 payload 后重新 ingest/plan 为新 set，保留失败证据。不要切割超限 DwarFS。

分盘计划一旦创建就不可直接覆盖。1.8.0 的受控 ID 修订允许用户修改尚未写盘套装的碟片 ID 或归档 ID，保存原清单历史并使 staging 失效；DwarFS 保留，见 [RENAME.md](RENAME.md)。编号在写 plan 前先预留，崩溃可以留下编号空缺，但不复用编号。当前版本替换坏盘采用新 set/plan；不自动重写已经印在其他盘上的整套 manifest。

## 视频准备

`split-video` 调用 mkvmerge `--split size:<bytes>`，默认目标 20.5 GiB、最大接受 21.5 GiB。切分按关键帧进行，可能超过目标。超出最大值立即失败，保留已生成输出供检查；用更低 TargetGiB 和新的输出目录重试。不得把失败输出直接 ingest。

所有 MKV 段独立播放，不设置跨文件 segment linking，不指定编码器。保留 mkvmerge 支持的轨道、章节、标签；这不是所有输入容器字段都逐字节保真的保证。每段使用本地时间轴，`VIDEO-MANIFEST.json` 保存顺序、持续时间、累计时间估计、输入 SHA-256、大小与 mkvmerge 版本。累计时间不是精确原始 packet PTS 映射；如需逐包追溯，应额外保留源文件或导出逐轨时间戳。

Remux 后 MKV 段的容器字节不会等于原始 MP4/MKV；内容未重编码与文件 bit-identical 是不同的验收项。mkvmerge 返回 1（警告）也会阻止接受，要求检查日志；不会把警告当普通成功。

联系表需要 ffmpeg。默认每 300 秒取样，5×4 网格，取前 20 张；超长片段应调节间隔或另制联系表。短片段剩余格可能空白。生成后人工看图、检查代表性。`EVENTS.md` 和 `event_summary` 来自 `-Summary` 或人工编辑，不自动虚构游戏事件。完成这些准备后，ingest 整个输出目录为 II 类。

## DwarFS 验收

每个 shard 的 build 顺序：快速模式检查源大小/mtime（完整模式才重复 SHA-256）并生成输入清单 → 限定工具版本 0.15.7 → mkdwarfs → 实际大小检查 → dwarfsck `--check-integrity` → 镜像 SHA-256 → 按 skip_roundtrip 跳过或流式逐文件回验。见 FAST-BUILD.md。

原始 stdout/stderr 与退出码写在 `archive/logs/*.log` 及对应 JSON；摘要写入 `build/<disc_id>/build.json`。非交互输出可能使用 `original size`、`compressed filesystem` 等措辞，解析缺失时保留 null 和原始日志，不捏造数值。`original_bytes` 为被选中文件逻辑大小之和，`image_bytes` 是实际完整镜像长度；compressed-size 文本来自工具，不混同文件长度。

`dwarfsck --check-integrity` 验证块完整性；流式内容回验进一步证明选中文件实际被纳入镜像；Skip 模式没有这项证据。每个 shard 重复根 metadata 只是恢复辅助，单 shard 不等于一套可用 iPhone 备份。完整恢复必须取得所有 shard 并拥有加密密码。

挂载运行前完整性检查，调用 `dwarfs IMAGE M: -f -o readonly`；保持该 PowerShell 窗口开启，Ctrl+C 结束挂载。WinFsp 是挂载依赖，不是 GUI；项目不自动安装或修复它。

## PAR2

计划时指定百分比；stage 阶段按此值创建恢复卷并运行 PAR2 verify。支持 par2cmdline 与 par2j64 的不同参数形式；版本及长路径支持以实际安装版本为准，失败则停止 stage。

当前对每个非空 payload 文件创建一个 PAR2 set，避免超长命令行与递归通配符漏文件；`PAR2.json` 记录输入路径和 index 位置。III 类每盘仅一个 DwarFS，因此恢复卷高效；大量小文件直接创建 PAR2 开销会明显增加，实际 stage 容量再次兜底。零字节文件由 SHA-256 验证。

PAR2 保护 `data/` 内容；catalog、SET-MANIFEST、恢复说明仍需独立核心盘／HDD 副本，不能以 PAR2 替代全库 metadata 备份。5% 是恢复数据目标比例，不是能承受整张盘丢失的概率或寿命保证。

修复时将盘内容复制到新的 HDD 目录，在副本上使用对应工具 `r` / `repair`，成功后重新按可信 SHA256SUMS 校验。不要对光盘做修复写入；不要使用“即使失败也覆盖”的修复选项。

## 刻录前检查

- 正确盘号、正确 Archive Set、正确卷标；核对 JSON/CSV 和实体标签。
- 已封存 staging 没有额外文件，封包校验记录与 catalog 一致；7 天内可复用，见 BURNING.md。
- III 镜像在 build 中已完整性 PASS，并符合选定模式：流式回验 PASS，或快速模式明确记录 SKIPPED_FAST / NOT_CHECKED。
- 插入全新 BD-R；不提供擦除、追加、覆盖、烧多份或擦掉原件的自动选项。
- 使用光驱报告且适合该介质的速度。默认 ImgBurn 配置 4x 是示例，若盘/固件只报告 2x，应核对 MID 与写策略，不强行改固件。原生 IMAPI2 使用驱动默认受支持速度。

IMAPI2 构建 UDF 2.50 并显式 finalize；若 Windows 不提供该版本则停止，不能自动降为 UDF 2.01。ImgBurn 以 BUILD/DEVICE 写盘，显式 UDF 2.50；BD-R 是否确实关闭会在 verify 阶段再从 IMAPI2 检查。不得把 ImgBurn 正常退出或其界面“完成”当作外部哈希 PASS。

## 可选刻后回读与独立删除门槛

选择回读校验时，弹出并重插盘，用 `verify-disc -MediaReloaded` 确认实际 CDRom、卷标、UDF、finalized、全体文件哈希与 DwarFS 完整性。软件无法以 `-MediaReloaded` 本身证明用户真的重插了介质，该标志记录操作者确认；应按规程执行。模拟根目录不能通过物理验证分支。

登记 location 后进行恢复演练。删除入口同时要求整套每张盘注册且 VERIFIED、报告未改变、非 simulation、finalized 证据和全套 restore PASS。恢复演练默认对所有类别强制，III 类即使关闭默认配置仍强制。

执行删除前再核对原始 ingest 哈希、源树文件数、每个文件哈希。新增/修改/缺失文件都会阻止删除。只按已经验证的相对路径逐文件删除，保留空目录，逐条写 `events.jsonl`。删除中断时有部分文件已删除，catalog 尚不宣称整套 original_deleted；不要盲目重复执行，先按事件日志核对并从已验证归档恢复所需文件。

自动删除只承诺所扫描普通数据流的字节恢复。需要保留源盘附加 NTFS 语义时，不应使用本工具删除该类源数据。

## 实体收纳与 NFC

普通 25GB 优先低成本、明确 BD 对应的活页套／索引盒，盘号对应 `P-01 / Page 37 / A` 一类具体位置；避免只能按叠放顺序寻找。50GB DL 若自带 slim case，可用于备份和较重要视频。核心／M-DISC 独立壳。

NFC 贴壳、盒或册，不贴光盘本体；标签只写稳定 URL，数据库的主键是 disc_id/set_id。手机访问必须能解析主机名并连接服务；断网或服务关闭时仍可凭盘面编号和光盘 RESTORE.md 离线恢复。不要把个人源路径或密码写 NFC。光盘离线，检索 catalog 可以在线。

## 常见错误与继续方式

| 错误 | 处理 |
|---|---|
| Source changed / copy conflict | 停止写入应用，保留当前证据，用新 SetId 重新扫描；恢复冲突不自动覆盖 |
| Oversize file | 游戏视频先分段；其他文件换 DL 或用能独立恢复的应用备份单元 |
| Built image / staging exceeds budget | 降低 payload、留更多 overhead，创建新 plan；不 split DwarFS |
| Version mismatch / native exit nonzero | 检查精确工具路径和对应日志，不自动换版本 |
| Stage already exists | 可能已封存或上次中断。检查 catalog 与目录，人工将旧失败目录改名后仅在尚未封存时重试；已封存记录用新 set |
| Archive ID already exists, but no plan/disc remains | 这是蓝屏或手工删除计划目录留下的孤立 ingest 记录。先确认该 set 没有盘记录、set 目录和原件删除状态，再执行 `archive-agent.ps1 -Command delete-orphan-set -SetId <ArchiveId> -Reason "..." -Execute`；工具会写维护收据、同步 JSON/SQLite，并保留盘号高水位。已有盘记录、set 目录或 set rename 历史时会拒绝清理。 |
| 需要删除整批未刻录任务并重做 | 使用 `archive-agent.ps1 -Command discard-unburned-plan -SetId <ArchiveId> -Reason "..." -Execute`。它只接受没有真实 burn/verify/register 的 set，删除 plan/build/staging 和盘记录，保留 ingest 扫描结果与源文件；如需回到较低的未占用 B 号，再使用 `manage-ids.ps1 -Command set-counter -Prefix B -NextNumber 16 -AllowCounterRollback -Execute`，回退会检查记录、别名和物理证据。 |
| Archive lock unavailable | 另一进程正在处理同一归档；等待它完成。退出后锁自动释放，不删除 catalog |
| Burn failed / verify failed | 保留原件和日志；失败盘编号不复用，改新 set/plan 制作替代盘 |
| SQLite sync unavailable | JSON 仍是主记录；配置真实 Python，用 catalog.py sync 重建索引 |
| WinFsp DLL 缺失 | 仅挂载受影响；可以继续用 standalone mkdwarfs/dwarfsck/dwarfsextract |
| 长路径工具失败 | 优先 PowerShell 7；第三方工具/UDF 仍有自身限制。缩短工作根目录或升级兼容工具，不静默裁剪文件名 |

## Catalog 丢失和离线恢复

优先从核心副本恢复 `catalog.json`、配置和 `sets/` 全目录，再重建 SQLite。无 catalog 时，每张盘的 RESTORE.md、SET-MANIFEST 和 SHA256SUMS 仍提供独立检查／解包信息；可按盘号顺序手工合并，重复 metadata 只有哈希相同才保留一份，最终按完整 ingest 文件表核对。

仅靠同盘 SHA256SUMS 可以发现意外损坏，不能取代外部可信哈希。保留 `disc-labels.csv` 与整套 catalog 独立副本。整理核心盘时先将 catalog、配置、工具版本信息、恢复说明复制到 archive_root 之外的专门输入目录，再以 M 类 ingest，避免扫描正在写入的归档工作目录。

## 定期复核

记录实际位置、介质批次等可在 summary/外部操作记录中补充；定期重新进行 optical verify，出现 FAIL 立即保留源或其他副本并迁移。项目不承诺“刻一次永久不管”，也不自动安排后台刻录、删除或联网公开服务。

## 1.2.0 场景与确认补充

照片并非统一低价值：A 精选核心保留 HDD，B 正常 RAW 保留其他副本，C 落选/未挑 RAW 才是腾出 HDD 的主要对象。A/B 和 M 核心源文件被 delete-source 明确拒绝；不能仅凭 SecondCopy 备注解锁。具体映射见 SCENARIOS.md。

照片目录尽量整批同盘；目录过大才拆到照片家族。RAW/JPEG/XMP（含 IMG.ARW.XMP）同名家族保留实体，即使其中 RAW 与别处逐位相同也不把配套关系拆开。目录中保留原路径，恢复时重建别名；XMP 内容不修改。

每一次实际写盘都在 UDF authoring/预检准备好之后由用户输入对应 BURN 盘号短语。没有自动确认开关。Agent 不可在控制台或窗口自动填确认答案。取消/输入不匹配时仍为 STAGED，不产生实际 burn 记录。开始写入后失败或结果不明则记 BURN_NEEDS_REVIEW，替代空白盘必须新盘号、新计划、新确认。

prepare 复用已完成、验证过的不可变步骤，返回 READY_FOR_REVIEW；不会接续 burn、删除或清理。GUI 对应“准备归档”，默认仅预览。GUI 调用工作进程的日志保留在 work/ui-jobs；后台 CLI 详细工具日志在 archive/logs。

## 编号管理（1.3.0）

同一 archive_root 内的所有 set 共用 P/G/B/M 计数器和全库 disc_index。使用 manage-ids 只读查看，向前设置下一号需 Execute，写入由 archive.lock 串行保护。卷标由 plan 封存，burn 两个后端使用同一值，verify 核对实盘卷标；不能改配置给已规划的盘换名。旧库 init 只补 catalog 身份与索引，旧盘内字节不变。详细字段、模板、CSV 和迁移流程见 [IDENTIFIERS.md](IDENTIFIERS.md)。

## 1.4.0 补充

自动计数器仍记录最高分配位置；单批可通过 StartDiscId 选择任意未占用的起始号及自定义前缀。目录删除与 delete-source 完全独立，删除目录记录可恢复并保留校验证据，旧 ID 不会重新绑定。卷描述分别封存在 plan 与 DISC.json 中，刻录前核对。ImgBurn 使用每次独立的 IBB 项目和 portable 设置文件；不覆盖其现有用户设置。字段是否写入 UDF 必须看映射，不把清单元数据当作文件系统内部描述符。详见 IDENTIFIERS.md。


## 准备中停止与继续

1.5.0 提供只作用于准备任务的“停止准备”，并实时显示 DwarFS 原生进度。中断状态为 CANCELLED，保留已完成盘、源数据和半成品；相同计划继续时，未完成输出移入 interrupted 后重做当前片。操作方式、日志位置、成对保存时的等待与旧窗口更新限制见 [PROGRESS.md](PROGRESS.md)。真实刻碟不受该按钮控制。


## 同卷免复制

1.6.0 自动按 Windows 卷身份识别源与待刻位置。同卷 payload 建硬链接，跨卷使用原有独立复制；同卷建链失败时不回退复制。III 类 mkdwarfs 以原目录和 `--input-list` 直接读本 shard。完整规则、共享数据的注意事项及空间预留见 [STORAGE.md](STORAGE.md)。


## 大量小文件与 Apple 备份

扫描仍逐文件读取原始字节计算 SHA-256；数据库索引、文件名和分桶不代替这项验证。对加密 Manifest.db，本工具不索取密码、不解密数据库或假称复用其中的内容摘要。目录分桶用于规划，关键 metadata 重复成本计入每张盘预算。扫描、构建源校验和解包回验是不同步骤。

若载入提示只有扫描清单、没有计划，保留 ingest.json，先查看失败日志。存在重复 catalog ID 时，不能直接跳过哈希保护；应保留原记录证据，将哈希与 catalog 匹配的完整扫描转为新 ID 后重新规划。不能把部分扫描当完整扫描使用。


校验界面进度、DwarFS 无百分比阶段及更新后重新打开界面的说明见 [VERIFICATION-PROGRESS.md](VERIFICATION-PROGRESS.md)。
