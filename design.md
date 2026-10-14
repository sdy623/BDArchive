# BD Archive Workbench / React design system

## Direction / 方向

Use the KSP Mission Display palette and typography, not its flight telemetry or branding. Source references: `mission-display/DESIGN.md` section 10 and `mission-display/app/globals.css`; attribution and font licenses are in THIRD_PARTY_NOTICES.md. The frontend is React 19 + TypeScript + Vite. Legacy WinForms remains opt-in compatibility code, not the current design.

本次重做控件和交互结构，而不是仅换色：小圆角按钮、自定义选择框、侧栏、分步表单、上下文操作和对话框统一实现。

## Component contracts

- **Buttons:** restrained 6 px corners, clear primary/secondary/danger hierarchy; distinct hover, active, disabled and keyboard focus. One primary action per work area.
- **Selectors:** React listbox, not native HTML select or WinForms ComboBox. Arrow keys, Home/End, Enter/Space, Escape, typeahead and outside-click dismissal. Current and focused options are distinguishable; disabled controls never open.
- **Checkbox / switch / radio:** custom visual treatment over semantic interactive controls, accessible labels, visible focus, non-color state indicator. No default OS bevels.
- **Menus / dialogs:** anchored to the action context; dialogs restore focus and constrain keyboard interaction. Physical-burn text starts empty; no prefilled approval.
- **Navigation:** persistent grouped sidebar, active route indicator, responsive compact layout. Prepare uses Source → Plan → Build; jobs remain independently visible.
- **Lists:** real catalog records, searchable IDs, selected-record detail. Empty means empty; do not invent counts or verified states.
- **Logs:** actual worker output. Unknown progress stays indeterminate, never a fabricated percentage.

## Visual identity

Near-black canvas, layered dark blue surfaces, cyan emphasis, amber caution, red destructive warning, readable off-white body. Soft borders, 10 px card radii and modest shadows create hierarchy. Barlow Condensed for compact headings; IBM Plex Sans for UI; IBM Plex Mono for IDs/logs; Microsoft YaHei UI fallback for CJK. Offline OFL font files retain their licenses.

## Localization and scaling

English and Simplified Chinese share one state model. Language changes preserve selected record, entered fields and job state. Backend diagnostics retain original text. Layout uses CSS pixels and responsive grids; test browser zoom/HiDPI independently from old native HFONT tests. At small widths, controls wrap rather than overlap. Keyboard focus must remain visible.

## Safety boundary

UI is not permission. The localhost Python bridge validates Host/Origin, random session token and allowlisted commands/parameters. Config writes are explicit and constrained. Default requests are dry-run. Real burn requires a short-lived review tied to the current disc, stage and drive plus the exact user-entered `BURN <disc_id>` phrase; the PowerShell backend independently checks it. No source-deletion or destructive catalog-cleanup HTTP endpoint is exposed. Existing native CLI operations retain their own authorization gates.

## Verification boundary

Frontend build/typecheck, loopback HTTP tests, browser interaction tests and synthetic PowerShell tests are separate from physical hardware acceptance. No screenshot, dry-run or simulation implies a physical burn or readback. Public screenshots must use only synthetic paths and catalog data. See VALIDATION.md for executed scope.

### Corner-density revision
Buttons, inputs and navigation use 6 px corners; cards 10 px; option menus 8 px; badges 3 px; dialogs 12 px. Only true radio/disc/status indicators remain circular. Avoid pill-shaped containers and nested oversized rounding.
