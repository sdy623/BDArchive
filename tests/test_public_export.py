"""Synthetic tests for the source-only release guard; no filesystem deletion."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("public_export", Path(__file__).resolve().parents[1] / "scripts/check-public-export.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PublicExportTests(unittest.TestCase):
    def font_files(self):
        root = Path(__file__).resolve().parents[1]
        return {path.relative_to(root).as_posix(): path.read_bytes()
                for path in (root / 'assets/fonts').glob('*') if path.is_file()}

    def test_approved_font_exact_bytes_are_allowed(self):
        files = self.font_files()
        fonts = {name: data for name, data in files.items() if name.endswith('.ttf')}
        self.assertEqual(6, len(fonts))
        for name, data in fonts.items():
            self.assertEqual([], MODULE.inspect_file(name, data), name)

    def test_changed_or_relocated_font_is_rejected(self):
        name = 'assets/fonts/barlow-condensed-400.ttf'
        data = self.font_files()[name]
        self.assertTrue(MODULE.inspect_file(name, data[:-1] + bytes([data[-1] ^ 1])))
        self.assertTrue(MODULE.inspect_file('other/' + Path(name).name, data))

    def test_unknown_font_is_not_allowed_even_when_plain_text(self):
        self.assertTrue(MODULE.inspect_file('assets/fonts/unreviewed.ttf', b'not a font'))
        self.assertTrue(MODULE.inspect_file('assets/fonts/unreviewed.woff2', b'not a font'))

    def test_fonts_require_exact_license_notices(self):
        self.assertTrue(hasattr(MODULE, "inspect_font_licenses"), "License validation is missing")
        files = self.font_files()
        self.assertEqual([], MODULE.inspect_font_licenses(files))
        del files['assets/fonts/barlow-condensed-OFL.txt']
        self.assertIn('font-license-missing', {x['rule'] for x in MODULE.inspect_font_licenses(files)})
        files = self.font_files()
        files['assets/fonts/ibm-plex-sans-OFL.txt'] += b'changed'
        self.assertIn('font-license-changed', {x['rule'] for x in MODULE.inspect_font_licenses(files)})
    def test_generic_source_allowed(self):
        self.assertEqual([], MODULE.inspect_file("scripts/demo.ps1", b"Write-Output 'fixture'\n"))

    def test_private_config_rejected(self):
        self.assertTrue(MODULE.inspect_file("archive.config.json", b"{}"))

    def test_runtime_rejected(self):
        self.assertTrue(MODULE.inspect_file("work/run/result.json", b"{}"))

    def test_personal_profile_rejected(self):
        source = ("C:" + "\\Users\\" + "ExamplePerson\\Videos").encode()
        self.assertTrue(MODULE.inspect_file("README.md", source))

    def test_token_rejected(self):
        self.assertTrue(MODULE.inspect_file("README.md", ("ghp_" + "X" * 36).encode()))

    def test_binary_not_source(self):
        self.assertTrue(MODULE.inspect_file("examples/demo.dat", b"\x00\x01\x02"))

    def test_old_screenshot_rejected(self):
        self.assertTrue(MODULE.inspect_file("examples/ui-preview.png", b"\x89PNG"))

    def test_new_doc_screenshot_requires_manual_review_not_text_scan(self):
        self.assertEqual([], MODULE.inspect_file("docs/preview-en.png", b"\x89PNG"))

    def test_external_tool_binary_rejected(self):
        self.assertTrue(MODULE.inspect_file("downloads/helper.exe", b"MZ"))


if __name__ == "__main__":
    unittest.main()
