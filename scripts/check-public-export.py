"""Inspect Git candidate/index files without opening a live archive or running tools.

This release guard is heuristic. Review screenshots and commit ancestry separately.
Only Python's standard library and the local Git executable are required.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

BLOCKED_DIRS = {
    "archive", "work", "validation", "reports", "logs", "receipts", "staging",
    "build", "simulated", "restored", "images", "maintenance", "external-imports",
    "__pycache__", "vendor", "tools", "dist",
}
BLOCKED_SUFFIXES = {
    ".sqlite", ".db", ".log", ".bak", ".tmp", ".dwarfs", ".iso", ".udf", ".par2",
    ".ibb", ".exe", ".dll", ".msi", ".zip", ".7z", ".tar", ".gz", ".pyc",
    ".pem", ".key", ".pfx", ".p12", ".cr2", ".crw", ".nef", ".arw", ".dng",
    ".raw", ".mp4", ".mkv", ".mov", ".wav", ".mp3",
}
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".webp"}
# Reviewed offline font assets only. Adding a different binary requires a new
# provenance/license review and a deliberate update to this checked-in map.
# Original vector artwork, reproducible with packaging/build-icon.py.
APPROVED_ICON_SHA256 = 'e8894cd2b75dfd3e8cadff78e3033f00f4851b8aedf3396e32bf1880d3a483b4'
FONT_SUFFIXES = {".ttf", ".otf", ".woff", ".woff2", ".ttc"}
LICENSED_FONTS = {
    "assets/fonts/barlow-condensed-400.ttf": ("a8cc7ff9640feb14aedfbfd04fe4df72637cb6869329057ae319a4ad0e090a4a", "assets/fonts/barlow-condensed-OFL.txt"),
    "assets/fonts/barlow-condensed-600.ttf": ("1d98343f382436794ad6a305b4d970224e3c788e76c3cad44a3372a24203900f", "assets/fonts/barlow-condensed-OFL.txt"),
    "assets/fonts/ibm-plex-sans-400.ttf": ("b7687a7b11bf4972c2807e6f1701bb55d1837e6957373e6610a81e3bbd4423a9", "assets/fonts/ibm-plex-sans-OFL.txt"),
    "assets/fonts/ibm-plex-sans-600.ttf": ("846b4ae6213632652b5a500cb560d04be4e7183f85ca917a8b90b4a67cf624ad", "assets/fonts/ibm-plex-sans-OFL.txt"),
    "assets/fonts/ibm-plex-mono-400.ttf": ("7fd0247fd247f38713b9b411430e1901ff87fb1d6b9bea6e267ad44d2ebfe993", "assets/fonts/ibm-plex-mono-OFL.txt"),
    "assets/fonts/ibm-plex-mono-600.ttf": ("39e313ebb0e4dbecc7e839c664efa405092da434fa012493a23e2642dbad9666", "assets/fonts/ibm-plex-mono-OFL.txt"),
}
FONT_LICENSE_SHA256 = {
    "assets/fonts/barlow-condensed-OFL.txt": "046ee27d8bddc6b6ee08eee53c96dbf3ec1f6df561644e018507dd8ffcb11d31",
    "assets/fonts/ibm-plex-sans-OFL.txt": "d0283623ef57e722fd0eb688a8041589670c608ab780cd3612d06ba6f153d3fd",
    "assets/fonts/ibm-plex-mono-OFL.txt": "23b0a9d0c6d3f140a0b77e483c5cfa6bba574325ef5cb189ed9f2fec4884533f",
}
TEXT_PATTERNS = [
    ("absolute-user-profile", re.compile(r"[A-Za-z]:[\\/]+Users[\\/]+(?!Public(?:[\\/]|$)|<|\$|\{|\%)[^\\/\r\n\"']+", re.I)),
    ("private-photo-root", re.compile("Canon" + r"_Photos_(?:NG|Pending)", re.I)),
    ("private-archive-id", re.compile("PHOTO-RAW-" + "ARCHIVE-017|IPH-BACKUP-" + "20260905", re.I)),
    ("private-task-path", re.compile("referenced-chatgpt-" + "conversation-this-is-an-2", re.I)),
    ("private-key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b")),
    ("api-secret", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{24,}\b")),
    ("credential-assignment", re.compile(r"(?im)^\s*[\"']?(?:api_key|access_token|client_secret|password)[\"']?\s*[:=]\s*[\"']([^\"'\r\n]{8,})[\"']")),
]


def inspect_file(name: str, data: bytes) -> list[dict]:
    path = PurePosixPath(name)
    issues = []
    lower_parts = [part.lower() for part in path.parts]
    suffix = path.suffix.lower()
    base = path.name.lower()
    if any(part in BLOCKED_DIRS for part in lower_parts[:-1]):
        issues.append({"file": name, "rule": "runtime-or-bundle-directory"})
    if suffix in BLOCKED_SUFFIXES or base in {"archive.config.json", "archive.config.local.json", "release-manifest.json"} or (base.startswith(".env") and base != ".env.example"):
        issues.append({"file": name, "rule": "private-or-generated-file"})
    if suffix == '.ico':
        if name != 'assets/branding/bdarchive.ico' or hashlib.sha256(data).hexdigest() != APPROVED_ICON_SHA256:
            issues.append({'file': name, 'rule': 'unreviewed-or-changed-application-icon'})
        return issues
    if suffix in FONT_SUFFIXES:
        approved = LICENSED_FONTS.get(name)
        if approved is None:
            issues.append({"file": name, "rule": "unreviewed-font"})
        elif not data.startswith(b"\x00\x01\x00\x00") or hashlib.sha256(data).hexdigest() != approved[0]:
            issues.append({"file": name, "rule": "licensed-font-bytes-changed"})
        return issues
    if suffix in IMAGE_SUFFIXES:
        if not lower_parts or lower_parts[0] != "docs":
            issues.append({"file": name, "rule": "unreviewed-legacy-image"})
        return issues
    if b"\x00" in data:
        issues.append({"file": name, "rule": "unexpected-binary"})
        return issues
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        issues.append({"file": name, "rule": "non-utf8-source"})
        return issues
    for rule, pattern in TEXT_PATTERNS:
        for match in pattern.finditer(text):
            issues.append({"file": name, "line": text.count("\n", 0, match.start()) + 1, "rule": rule})
    return issues


def inspect_font_licenses(files: dict[str, bytes]) -> list[dict]:
    issues = []
    required = {entry[1] for name, entry in LICENSED_FONTS.items() if name in files}
    for name in sorted(required):
        if name not in files:
            issues.append({"file": name, "rule": "font-license-missing"})
        elif hashlib.sha256(files[name]).hexdigest() != FONT_LICENSE_SHA256[name]:
            issues.append({"file": name, "rule": "font-license-changed"})
    return issues

def git(root: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.PIPE)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", action="store_true", help="Read all indexed files from Git blobs, not working copies")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        argv = ["ls-files", "-z", "--cached"]
        if not args.staged:
            argv += ["--others", "--exclude-standard"]
        names = sorted(set(n.decode("utf-8") for n in git(root, *argv).split(b"\x00") if n))
        if not names:
            raise ValueError("No Git candidate files found; stage the intended public source first.")
        issues = []
        images = []
        files = {}
        for name in names:
            candidate = root / name
            # Git index mode 120000 is a symlink. Do not dereference it.
            stage = git(root, "ls-files", "--stage", "--", name)
            if stage.startswith(b"120000 ") or candidate.is_symlink():
                issues.append({"file": name, "rule": "symlink-requires-review"})
                continue
            if args.staged:
                data = git(root, "show", ":" + name)
            else:
                data = candidate.read_bytes()
            files[name] = data
            issues.extend(inspect_file(name, data))
            if PurePosixPath(name).suffix.lower() in IMAGE_SUFFIXES:
                images.append(name)
        issues.extend(inspect_font_licenses(files))
        result = {"status": "FAIL" if issues else "PASS", "mode": "index" if args.staged else "candidates", "files_checked": len(names), "issues": issues, "images_require_manual_review": images, "scope": "Heuristic text and path checks only; pixels, Git ancestry and live archives not inspected."}
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 1 if issues else 0
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(json.dumps({"status": "ERROR", "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
