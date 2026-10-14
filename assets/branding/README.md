# BDArchive application mark

Original disc-and-archive-tray vector artwork for this project, distributed under the project MIT license. No third-party artwork or personal data.

`python packaging/build-icon.py` reproduces `bdarchive.svg` and the antialiased RGBA ICO (16, 20, 24, 32, 48, 64, 128, 256 pixels). The EXE resource, native window icon and React brand mark share this artwork. Public-source checking pins the ICO hash; review and update it deliberately after an artwork change.

Small 16-64 px frames are 32-bit DIB for native .NET Framework/GDI compatibility; 128-256 px frames are PNG. Both preserve alpha.
