# Offline type assets

These six fonts are decoded from the KSP Mission Display project's existing Fontsource WOFF1 containers. Glyph and name tables are unchanged; per-table checksums and the reconstructed sfnt checksum were verified. This is container decoding, not a new typeface.

- Barlow Condensed 400 / 600 — Barlow Project Authors; see `barlow-condensed-OFL.txt`.
- IBM Plex Sans 400 / 600 — IBM Corp.; see `ibm-plex-sans-OFL.txt`.
- IBM Plex Mono 400 / 600 — IBM Corp.; see `ibm-plex-mono-OFL.txt`.

`provenance.json` records reviewed source names, source SHA-256 and distributed SHA-256. The public-export guard pins all six distributed files and their three full licenses. No CDN or system font installation is required. The desktop loads fonts privately in its process; native Windows edit controls use system UI fonts for reliable GDI rendering. Chinese uses Microsoft YaHei UI: IBM Plex Sans SC is not bundled.

Container format reference: [W3C WOFF 1.0](https://www.w3.org/TR/WOFF/). Redistribution remains under each font's included SIL Open Font License, not the toolkit's MIT license.
