# BDArchive 0.3.0 validation / 验证

Release-candidate checks executed on Windows x64 on 2026-10-14. Private raw logs stay outside the public tree.

| Command / check | Observed result | Scope |
|---|---|---|
| `python -m unittest discover -s tests -p 'test_*.py'` | 108 passed | Synthetic data, mocks and loopback HTTP |
| `npm run test:identifiers` in `ui` | 8 passed | Counter binding, prefix change, explicit draft and refresh |
| `npm run build` in `ui` | TypeScript and Vite succeeded | Production frontend build |
| `tests/run-tests.ps1` with isolated `-WorkRoot` | 15 passed | Synthetic PowerShell archive workflow; no physical burn |
| Native `BDArchive.exe --desktop-smoke-test <report> --config <synthetic-config>` | PASS | Actual WebView2 window, bundled Python, English/Chinese, catalog browser, counter controls, safe DRY_RUN worker and clean shutdown |
| Native font and icon probes | PASS | 150% display scale; Chinese uses Microsoft YaHei UI, no NSimSun; bundled IBM Plex Mono semibold; native window and EXE icons present |
| Welcome screenshots | Manually reviewed | Empty/synthetic data only; no private catalog/configuration |

The synthetic counter fixture intentionally contains existing IDs and an advanced global index. The UI reads successors P0131 / G0008 / B0025 / M0001 and global index 73 without allocating a number; it preserves explicit drafts until refresh. These are test fixtures, not a bundled user library.

**Not run:** physical optical burning/readback, live iPhone restore, source deletion, multi-monitor DPI transitions, and third-party archive-tool integration for this release. A test PASS is not an optical-media verification PASS. The redesigned UI is currently dark-only and exposes restore preview only; guarded restore CLI remains available.

Windows 10/11 x64, .NET Framework 4.7.2+, WebView2 Runtime; Python 3.12 and PowerShell 7 were used for local tests. The native package embeds its pinned Python runtime. Release binaries are unsigned.

# Validation / 验证

This public source tree starts a new, privacy-clean history. Old machine-specific reports, hardware identifiers, media manifests and real hashes are not included; screenshots use synthetic data only. No historical pass count is presented as a result for this revision.

本公开源码从独立历史开始，不包含旧机器报告、硬件标识、真实介质清单 / 哈希；截图仅使用合成数据；不把旧版本通过数当作当前版本验收结果。

## Reproduce safe checks / 复现安全测试

From the repository root on Windows, with PowerShell 7 and Python 3.10+:

```powershell
Copy-Item archive.config.example.json archive.config.json
python scripts/check-public-export.py
python -m unittest discover -s tests -p 'test_*.py' -v
.\tests\run-tests.ps1 -Python (Get-Command python).Source
```

`run-tests.ps1` creates its own synthetic sources and archive under `work/tests/<unique-id>` and does not request a real burn. Python tests use temporary directories and synthetic metadata; HTTP tests run a loopback service. Do not point a test at an existing user archive. Test files and logs stay ignored by Git.

核心 PowerShell 测试在 `work/tests/<唯一ID>` 创建合成源与隔离归档，不请求真实刻录。Python 测试使用临时目录、合成 metadata，HTTP 测试仅启动 loopback 服务。不要把测试目录改成实际归档库。测试产物不进入 Git。

The checked-in Windows CI workflow runs privacy checks, Python unit tests and the synthetic PowerShell suite. It deliberately does not download DwarFS, ImgBurn, drivers or media tools. A successful workflow demonstrates only the listed test scope; it does not certify disc readability.

## GUI checks / 界面检查

For a visual pass, launch each locale using a **synthetic configuration**:

```powershell
.\START.bat -Language en
.\START.bat -Language zh-CN
```

Check keyboard focus, tab order, narrow-window scrolling, status contrast, long Unicode paths, confirmation/cancellation, and visible progress. Test at the display scales available on the host and drag between monitors when possible. Simulated font scaling is not a substitute for a real DPI change. Never confirm a physical burn during a UI-only check.

检查键盘焦点、Tab 顺序、窄窗口滚动、状态对比度、Unicode 长路径、确认 / 取消和进度。在实际可用缩放比例下测试，条件允许时跨屏拖动。字体放大压力测试不等于真实 DPI 切换；纯界面检查不得确认刻盘。

## Scope boundaries / 验收边界

| Check | What it can establish | What it cannot establish |
|---|---|---|
| Parser / import | Source syntax and loading | Correct GUI layout or hardware operation |
| Synthetic unit tests | Capacity, IDs, manifests, locks, state transitions and guarded deletion | Performance on real data or optical reliability |
| GUI screenshot / smoke | Constructed UI, tested locale and scale | Every screen size, display or accessibility tool |
| Optional DwarFS fixture | Installed CLI integration on synthetic shards | iPhone application-level restore or backup-password correctness |
| ISO authoring fixture | UDF image generation | Physical burn, finalize or optical readback |
| Real-disc SHA-256 verification | Readback matches that sealed manifest | Long-term media lifetime or a second independent copy |

Optional integration scripts under `tests/` may need locally installed tools. Read their parameters before running. Keep real drive/media validation outside CI and obtain user confirmation for every physical burn. Retain PASS, FAIL, CANCELLED, NOT_RUN and SIMULATED_PASS accurately; do not upgrade a skipped check to PASS.

## Public release review / 公开前检查

1. Review only the intended source diff; exclude local configuration, runtime folders and third-party binaries.
2. Run `python scripts/check-public-export.py` on candidate files.
3. Stage explicitly reviewed source files; run `python scripts/check-public-export.py --staged` to read the index snapshot.
4. Inspect newly generated screenshots manually. Automatic text scanning does not inspect pixels.
5. Verify the public branch contains only the intended clean initial commit and no private ancestry before publishing.

Automated scanning checks common private paths, credentials and forbidden outputs; it cannot prove absence of all sensitive data. Keep full local execution logs outside the public source tree. Any current-revision test results must state the actual command, runtime, result and exclusions; do not copy the old private report.

## UI regression commands

```powershell
./tests/test-localization.ps1
./tests/test-fonts.ps1
./tests/test-theme.ps1
./tests/test-ui-language.ps1
./tests/test-ui-action-layout.ps1
./tests/test-first-run.ps1
./tests/test-worker-dialog.ps1
./tests/test-resume-settings.ps1 -Gui
```

UI tests create actual Windows controls using only synthetic fixture data. The action-layout test checks fixed action bars, stage ordering, explicit local-build enable, a dry-run preview worker and absence of physical-burn execution. Large-font stress is not the same as moving a window between physical displays. Third-party DwarFS/ImgBurn integration and real optical burning/readback require a separate, explicitly authorized hardware test.
