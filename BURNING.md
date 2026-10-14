# 刻录、设备选择、模拟清理与取消恢复 — 1.12.0

## 1.12.0 模拟副本清理与真实刻录切换

“模拟写入”是在 `archive_root\simulated\<盘号>` 创建的本机派生副本，不是实体光盘证据。选中该盘后点击「清除模拟写入」，确认后只删除这个受限目录并把记录恢复为 `STAGED`；待刻目录、源文件、盘号、不可变计划、SHA256SUMS 与既有报告均保留，原模拟字段写入 `simulation_history` 和 maintenance journal。命令行先预览、再执行：

```powershell
.\scripts\clear-simulation.ps1 -DiscId BD-B-0015
.\scripts\clear-simulation.ps1 -DiscId BD-B-0015 -Execute
```

若直接从纯模拟记录点击「真实刻碟」，程序先完成待刻封包及所选空白 BD-R 的容量/介质预检，再自动执行相同清理，然后进入逐盘确认。用户取消切换提示时不启动任务；最终实体写入仍须亲自输入 `BURN <disc_id>`。程序不会用本功能清除 `WRITTEN`、部分写入、结果不明或实体校验记录；这些仍按原生日志检查。

1.10.1 修复 ImgBurn 完成映像准备后直接关闭的识别：唯一项目日志完整结束，且仅有一次完整的映像准备、没有写入阶段时，记为 NOT_STARTED 并返回原盘号待刻。既有误判可点「恢复取消的待刻记录」；保留 burn_history 和原日志，无需重新封包或更换盘号。日志缺失、部分写入、第二项操作或混入其他项目时仍须检查证据。

第 2 页自动枚举 Windows IMAPI2 光驱，用下拉框选择设备。检测在独立后台任务中运行；插入或更换盘片后点击“刷新光驱与盘片”。显示型号、介质、空白状态、可用容量及设备报告的 BD 写速；无盘、忙碌或不支持时显示实际未知/错误。真实写入前再次枚举，并确认盘符仍对应所选设备。

第 4 页设置 ImgBurn 请求速度 MAX 或具体倍速，保存后用于下一次任务。MAX 请求最高速度；设备和盘片决定实际速度。此项只适用于 ImgBurn。界面新增“刻录后让 ImgBurn 回读校验”，默认关闭，对应 `burn.verify_after_write=false`；旧配置未填写也默认关闭。原生 IMAPI2 仍不自动回读。

## 校验何时发生

1. 封包时完成 SHA-256 和相应 DwarFS 完整性检查，并在 catalog 的 stage.receipt 保存文件路径、大小、修改时间及最终记录哈希。
2. 刻录前，最近校验在 **7 天以内**且记录一致时，只比较文件列表、大小、修改时间和 SHA256SUMS / DISC.json；不重新读取 payload、不重跑 dwarfsck。复用不会延长原有 7 天期限。文件大小/修改时间从底层文件句柄读取，避免 NTFS 硬链接的目录缓存。
3. 过期、文件列表/大小/修改时间变化时重新校验内容；最终记录与可信 catalog 不符时拒绝刻录。只读句柄覆盖检查、用户确认到写入结束，确认后只检查新增文件和介质变化。
4. 成功写入登记为 BURNED_UNVERIFIED，可直接登记物理位置。手动回读仍在第 2 页提供；仅真实回读通过才标为 VERIFIED。写入成功、封包校验通过和光盘回读通过是不同结果。

旧版封包没有逐文件时间快照。1.9.0 的兼容复用要求原始 seal 在 7 天内、最终记录哈希匹配、文件列表和总大小一致、每个文件最后修改不晚于 seal。首次记录为 `LEGACY_METADATA_REUSE`，之后按快照比较；这是元数据复用，不能宣称刚重新校验了文件内容，也不能检测保持大小和时间戳不变的内容变化。校验或恢复流程依然可以显式执行。

## 确认与 ImgBurn 取消

真实刻碟仍要求用户亲自输入 `BURN <disc_id>`。确认窗口允许显示，不由 Agent 代填或接受。

每次 ImgBurn 调用使用独立项目与原生日志 `/LOG`；解析固定英语日志以匹配该项目的写入阶段。进程退出码 0 不能证明写入成功。日志表明准备映像时取消、尚未写入时，恢复 STAGED，并把尝试保存在 burn_history；重新点击真实刻碟即可使用同一 ID。取消后若 ImgBurn 窗口仍开着，请关闭该窗口以便它保存最终日志。

旧版本误记为已刻录的取消，在第 2 页点“恢复取消的待刻记录”，或运行：

```powershell
.\scripts\recover-burn.ps1 -DiscId BD-B-0004 -Execute
.\scripts\list-drives.ps1
```

旧记录通过自身调用日志的时间、唯一项目路径、目标光驱绑定 ImgBurn 原生日志，并保存日志副本。只恢复能确认未写入的尝试。部分写入、日志缺失或结果不明保留 BURN_NEEDS_REVIEW；不凭“当前插入空白盘”抹掉上一张盘的写入历史。已写入完成、随后取消 Verify 的盘仍为已写入。

1.8.1 及更早版本的窗口不会热更新。等待当前任务结束后，关闭旧窗口，用 START.bat 重新打开。升级不重建镜像、不改变盘号，也不自动刻碟。

## 1.9.1 封盘状态误报修复

IMAPI2 的 0x8000 是“此写入接口不支持介质”，不能翻译为“未封盘”。缺少 0x4000 标志也不能直接得出未封盘结论。新版优先使用明确的 IMAPI finalized 状态，否则发送只读 MMC READ DISC INFORMATION（0x51，34 字节），要求 DiscStatus=2、LastSessionStatus=3。请求通过 Windows 光驱设备接口发送，不封盘、不修复、不擦除、不弹盘。

未插盘、身份不符或无法确认状态，报告为 NOT_RUN / MEDIA_PREFLIGHT；保持已有写入和有效校验证据。只有进入文件哈希检查后发生错误才标为 VERIFY_FAILED。回读仍是手动操作。

旧版本这种误报可在光盘页选中对应盘和光驱，点击“修正旧版封盘误报”，或运行：

```powershell
.\scripts\repair-verify-status.ps1 -DiscId BD-B-0004 -Drive G: -Execute
```

它只处理该已知预检报错，核对可信旧报告、盘片完整状态和 DISC.json / SHA256SUMS 两个小文件，保留旧报告到 verification_history，恢复 BURNED_UNVERIFIED。不读取 payload，不把记录变成 VERIFIED；实际内容校验失败不能用此命令清除。库正被扫描/制作占用时等待其完成再执行，不能强行抢锁。


1.9.2：手动回读默认仅逐文件比对 SHA-256。额外 DwarFS 内部检查需勾选慢速深检或传 -DeepVerifyDwarfs，并使用单个读取线程。校验可点停止，取消不记为 PASS/内容 FAIL。进度与大容量计数说明见 [VERIFICATION-PROGRESS.md](VERIFICATION-PROGRESS.md)。
