"""Negative checks inspect source strings without executing browser code."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
path = Path(__file__).resolve().parent.parent / 'dev/browser-audit.py'
spec = importlib.util.spec_from_file_location('browser_audit', path)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class BrowserAuditTests(unittest.TestCase):
    def test_direct_qualified_computed_and_aliased_capabilities(self):
        for source in [
            'new Worker("pod.js")', 'new window.Worker("pod.js")',
            'new globalThis.Worker("pod.js")', 'new self["Worker"]("pod.js")',
            'navigator["locks"].request("pod", callback)',
            'const Spawn = Worker; new Spawn("pod.js")',
            'const locks = navigator.locks; locks.request("pod", callback)',
            'self["postMessage"]({})', 'globalThis["indexedDB"].open("db")',
            'eval(source)', 'new Function(source)',
            'new BroadcastChannel("doorbell")',
            r'globalThis["\u0057orker"]', r'new \u0057orker("pod.js")',
            '`text ${new Worker("pod.js")}`',
            'const url = "https://example.test"; new Worker(url)',
        ]:
            with self.subTest(source=source):
                self.assertTrue(audit.code_tokens(source) & audit.FORBIDDEN)

    def test_comments_are_ignored_without_hiding_following_code(self):
        source = '''/* Worker navigator indexedDB */
        const value = "safe"; // postMessage eval Function
        const template = `safe ${/* Worker */ value}`;
        '''
        self.assertFalse(audit.code_tokens(source) & audit.FORBIDDEN)
        self.assertEqual(audit.code_tokens('(* Worker (* navigator *) *) let x = 1', ocaml=True)
                         & audit.FORBIDDEN, set())
        self.assertIn('Worker', audit.code_tokens('const x = "/* safe */"; new Worker(x)'))

    def test_html_accepts_only_the_declared_script_sequence(self):
        valid = ''.join(f'<script src="{name}"></script>' for name in audit.PAGE_SCRIPTS)
        self.assertEqual(audit.PageScripts().validate(valid), [])
        for source in [
            valid + '<script>new Worker("pod.js")</script>',
            valid + '<script src="https://example.test/extra.js"></script>',
            valid + '<script src="pod.js"></script>',
            valid + '<button onclick="run()">Run</button>',
            valid.replace('src="page.js"', 'src="page.js" src="pod.js"'),
            valid.replace('src="page.js"', 'src="nested/page.js"'),
        ]:
            with self.subTest(source=source):
                self.assertTrue(audit.PageScripts().validate(source))

    def test_manifest_rejects_extra_missing_nested_and_module_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            browser = Path(directory)
            for name in audit.FILES:
                (browser / name).write_text('')
            self.assertEqual(audit.tree_errors(browser), [])
            for name in ['extra.mjs', 'nested/extra.js']:
                file = browser / name
                file.parent.mkdir(exist_ok=True)
                file.write_text('')
                self.assertTrue(audit.tree_errors(browser))
                file.unlink()
                if file.parent != browser:
                    file.parent.rmdir()
            (browser / 'page.js').unlink()
            self.assertTrue(audit.tree_errors(browser))


if __name__ == '__main__':
    unittest.main()
