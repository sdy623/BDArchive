# 编号、删除记录和卷描述 — 1.8.0

打开 `START.bat`。制作页可填写**本批起始盘号**；「5 编号与卷标」查看自动计数器、索引并删除/恢复目录记录；「6 卷描述模板」填写截图中对应的各个字段，并预览实际写入范围。

## 接续其他工具的编号

起始盘号留空：按照片 P、录像 G、备份 B、核心 M 的自动计数器接号。

填 `IPA-009`：本批成为 `IPA-009`、`IPA-010`、`IPA-011`……。填 `BD-B-0100`：从该号起连续分盘。即使自动计数器已到 500，也可显式选择尚未占用的 100 开始；不会把自动计数器倒退。自定义前缀不消耗 P/G/B/M 的自动号池。

格式：大写英文字母开头，可含数字、`_`、`-`，以 1…2147483647 的数字结尾，完整 ID 最多 32 字符。保留起始数字的补零宽度；越过 999 自动变 1000。为安全文件名、跨工具及卷标兼容设此范围，源文件路径仍支持 Unicode 和空格。

实际分盘先检查整个号段，遇到任何已有记录、已删除记录或残留的构建/待刻/模拟目录时整体拒绝，不自动跳号，也不留下半套已分配号码。外部工具的 catalog 不会自动读取：用户应填写其空闲号段。同一库同时运行的任务由 archive.lock 串行保护。

```powershell
.\scripts\plan-discs.ps1 -SetId IPH-2025-0117 -StartDiscId IPA-001 -Execute
.\scripts\prepare-archive.ps1 -Scenario backup -SetId IPH-2025-0117 `
  -Source 'D:\Cold Data\iPhone backup' -StartDiscId BD-B-0100 -Execute
```

续做同一套使用原参数。修改已经编译的碟片 ID 或归档 ID，使用第 5 页专门的改名按钮；无需重编 DwarFS，详见 [RENAME.md](RENAME.md)。已写入光盘的 ID 不可改写，普通起号或模板选项也不能修改既有计划。盘号不是刻录次数，也不是光驱/厂商 Media ID。

## 删除目录记录与恢复

在第 5 页选择记录，点击“删除所选记录”。默认是只读预览；勾选“执行编号管理”才执行。删除后的记录从正常列表、盒标 CSV 和默认目录查询中移除。勾选“显示已删除记录”可以选中它并恢复。

这是**可恢复的目录删除**：保留盘号、校验状态、原计划、源文件、staging 和物理光盘。删除的旧 ID 继续指向旧证据，不会分配给另一张盘。恢复记录会重新显示原来的状态，不把它重新标为已校验。若一套有已删除记录，摘要会注明；须先恢复记录才能继续刻录/恢复该套或评估原件删除。

```powershell
# 默认只展示将删除哪条记录
.\scripts\manage-ids.ps1 -Command delete-disc-record -DiscId IPA-001
# 明确执行目录删除；不使用 DeleteSourceConfirmed
.\scripts\manage-ids.ps1 -Command delete-disc-record -DiscId IPA-001 -Reason '交给其他工具管理' -Execute
.\scripts\manage-ids.ps1 -Command restore-disc-record -DiscId IPA-001 -Execute
```

JSON catalog 保存删除标志、时间、原因；events.jsonl 保存删除/恢复事件。SQLite 是可重建索引，`catalog.py list` 默认不显示已删除记录，`--include-deleted` 可查看。NFC 旧 `/disc/IPA-001` 页面仍能显示“记录已删除”；`/deleted` 是只读的已删除记录页，不提供网页写操作。

## 标识之间的关系

| 字段 | 示例 | 含义 |
|---|---|---|
| catalog_id | UUID | 当前 archive_root 的库身份 |
| archive_set_id | IPH-2025-0117 | 逻辑归档套装 |
| disc_id | IPA-001 / BD-B-0100 | 对应一张物理盘的业务编号 |
| disc_index | 123 | 本库跨类别递增索引；删除记录也不改变它 |
| volume_id | IPH-2025-0117-V0001 | 工具的逻辑卷 ID |
| volume_index / volume_count | 1 / 3 | 第几卷 / 共几卷 |
| volume_label | IPA-001 | 写入 UDF，资源管理器显示的卷标 |
| filesystem_serial | 实际回读值 | Windows 文件系统序列号；模拟时留空 |

不同 archive_root 有不同 catalog_id 和号池。NFC UID 不作业务主键；NFC 只存稳定 URL。逻辑 volume_id 和模板中的 volume_set **不冒充文件系统内部 UDF Volume Set Identifier**。第二副本仍是摘要备注，本版不自动把一个逻辑卷分配到多实体副本。

## 截图中的卷描述字段

当前归档方案固定 **UDF 2.50**。所有输入都保存进 `DISC.json`、`SET-MANIFEST.json`、`VOLUME-METADATA.txt` 以及 catalog；文件系统能写入哪些字段，取决于格式和后端。

| 字段 | 当前实际行为 |
|---|---|
| UDF 卷标 | IMAPI2 / ImgBurn 都写入。制作页的卷标模板控制此值 |
| ISO9660 / Joliet 卷标 | 保存到盘内清单。当前不生成这两种文件系统，因此不会写入它们的描述符 |
| System / Publisher / Data Preparer | 保存到盘内清单；当前 UDF 流程不把它们写成 ISO9660 的描述符 |
| Volume Set | 保存到盘内清单；本机 ImgBurn 2.5.8.0 实测会自行生成另一个 UDF 内部标识，忽略 Labels 页的同名值 |
| Application | ImgBurn 可写入 UDF Application，最多 23 ASCII 字节；IMAPI2 的已用接口不提供此设置。填入后须选 ImgBurn，否则实际刻录前明确拒绝 |

描述符行为应在本机使用合成小样本重新验证，测试入口见 `tests/test-imgburn-descriptors.ps1`；仅生成 ISO 文件，不是物理写入。公开源码不包含旧机器的验证报告，也不据此宣称当前光驱已验收。

所有模板支持普通文字和这些占位符：`{disc_id}`、`{set_id}`、`{volume_id}`、`{prefix}`、`{number}`、`{disc_index}`、`{volume_index}`、`{volume_count}`、`{catalog_id}`、`{set_token}`。

`{number}` 至少 4 位；`{disc_index}` 至少 6 位；卷序/总卷数至少 4 位。`{set_token}` 是 catalog_id 与 set_id 的稳定摘要前 16 个十六进制字符，仅用于模板，不是回读的文件系统标识。

UDF 卷标使用本工具的跨工具兼容规则：最多 32 个大写 ASCII 字母/数字/下划线/连字符。这是工具策略，不声称是 UDF 标准的完整字符或长度上限。Application 不接受首尾空白、Unicode 或超过 23 字节。其余清单字段最多 128 字符，可含中文。非法占位符和换行会报错，不悄悄截断。

示例：UDF 卷标 `{disc_id}`；Volume Set `{set_id}`；Publisher `PERSONAL ARCHIVE`；Data Preparer `LOCAL WORKFLOW`；Application `BDARCHIVE 0.3.0`。不要填真实备份密码；密码只记录保管位置。

GUI 的“保存为默认模板”会保存模板和所选刻录后端；已封存计划继续使用原值。命令行可传 `-VolumeTemplates @{volume_set='{set_id}';application='BDARCHIVE 0.3.0'}`，或编辑配置的 `numbering.volume_templates`。BAT 用户可直接编辑 JSON 配置。

## 旧库与导出

`manage-ids -Command init -Execute` 可补 catalog_id / disc_index 等缺失字段，只改 catalog，不改旧 plan 或盘内字节。遇到 archive.lock 占用时等待现有任务完成，不强抢锁。导出会生成 disc-index.json、disc-index.csv、disc-labels.csv；即使删除全部活动记录，也会重写空 CSV 表头，避免留下旧盒标。只有 catalog 索引补全后才能为旧记录显示稳定全库索引。
