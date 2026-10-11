"""Direct usage-parser regression tests, captured before extraction at 7fca6f5.

Run: python3 -m unittest discover -s tests -p 'test_usage_parser.py' -v
No Herdr, terminal, network, or backend process is involved.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from herd_parse import parse_usage  # noqa: E402

FIXTURES = ROOT / 'tests/fixtures/usage'
CASES = json.loads((FIXTURES / 'expected.json').read_text(encoding='utf-8'))['cases']


def input_text(case):
    return case['text'] if 'text' in case else (FIXTURES / case['fixture']).read_text(encoding='utf-8')


class UsageReferenceTests(unittest.TestCase):
    pass


def reference_test(case):
    def test(self):
        result = parse_usage(input_text(case), case['kind'])
        self.assertEqual(result.to_tsv('probe', case['kind']) + '\n', case['stdout'])
        self.assertEqual(result.exit_code, case['exit_code'])
    return test


for case in CASES:
    setattr(UsageReferenceTests, 'test_' + case['id'].replace('-', '_'), reference_test(case))


class UsageInterfaceTests(unittest.TestCase):
    def test_cli_matches_all_reference_cases(self):
        for case in CASES:
            with self.subTest(case=case['id']):
                result = subprocess.run(
                    [sys.executable, str(ROOT / 'scripts/herd_parse.py'), 'usage',
                     '--name=probe', '--kind=' + case['kind']],
                    input=input_text(case), text=True, encoding='utf-8',
                    capture_output=True, env={**os.environ, 'PYTHONUTF8': '1'},
                    cwd=FIXTURES)
                self.assertEqual((result.stdout, result.stderr, result.returncode),
                                 (case['stdout'], '', case['exit_code']))

    def test_names_are_only_output_labels(self):
        text = (FIXTURES / 'claude-usage-unused.txt').read_text(encoding='utf-8')
        result = parse_usage(text, 'claude')
        self.assertEqual(result.to_tsv('label-α', 'claude'),
                         'label-α\tclaude\t5h=100% left\tweek=88% left\treset5h=?'
                         '\tresetweek=Sep 18, 9:59am (Europe/Berlin)')

    def test_calls_do_not_share_state(self):
        text = (FIXTURES / 'claude-usage-unused.txt').read_text(encoding='utf-8')
        first = parse_usage(text, 'claude')
        self.assertEqual(parse_usage('', 'grok').exit_code, 1)
        self.assertEqual(parse_usage('', 'unknown').exit_code, 1)
        self.assertEqual(parse_usage(text, 'claude'), first)

    def test_import_has_no_cli_side_effect(self):
        result = subprocess.run([sys.executable, '-c', 'import herd_parse'],
                                cwd=ROOT / 'scripts', capture_output=True, text=True)
        self.assertEqual((result.stdout, result.stderr, result.returncode), ('', '', 0))


if __name__ == '__main__':
    unittest.main()
