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


class AgyClaudeTests(unittest.TestCase):
    def setUp(self):
        self.text = (FIXTURES / 'agy-usage-claude-gpt.txt').read_text(encoding='utf-8')

    def test_three_groups_from_real_usage_screen(self):
        result = parse_usage(self.text, 'agy')
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.to_tsv('probe', 'agy'),
                         'probe\tagy\t5h=100% left\tweek=100% left\treset5h=?\tresetweek=?'
                         '\targon_5h=–\targon_week=95% left\targon_reset5h=–'
                         '\targon_resetweek=91h 22m\tclaude_5h=39% left\tclaude_week=69% left'
                         '\tclaude_reset5h=4h 55m\tclaude_resetweek=167h 55m')

    def test_missing_resets_do_not_leak_from_other_groups(self):
        for value, field in [('4h 55m', 'claude_reset5h'),
                             ('167h 55m', 'claude_resetweek')]:
            with self.subTest(field=field):
                result = parse_usage(self.text.replace('Refreshes in ' + value, ''), 'agy')
                self.assertEqual(result.exit_code, 1)
                self.assertEqual(dict(result.extra)[field], '?')
                self.assertEqual(dict(result.extra)['argon_resetweek'], '91h 22m')

    def test_present_group_requires_both_windows(self):
        for label, field in [('Five Hour Limit', 'claude_5h'),
                             ('Weekly Limit', 'claude_week')]:
            with self.subTest(field=field):
                gemini, claude = self.text.split('CLAUDE AND GPT MODELS', 1)
                result = parse_usage(gemini + 'CLAUDE AND GPT MODELS'
                                     + claude.replace(label, 'Unavailable Limit', 1), 'agy')
                self.assertEqual(result.exit_code, 1)
                self.assertEqual(dict(result.extra)[field], '?')

    def test_absent_group_adds_no_fields(self):
        gemini, rest = self.text.split('CLAUDE AND GPT MODELS', 1)
        argon = 'GEMINI 4 ARGON' + rest.split('GEMINI 4 ARGON', 1)[1]
        result = parse_usage(gemini + argon, 'agy')
        self.assertEqual(result.exit_code, 0)
        self.assertFalse(any(key.startswith('claude_') for key, _ in result.extra))
        self.assertEqual(dict(result.extra)['argon_week'], '95% left')

    def test_truncated_group_reports_unknown_fields(self):
        text = self.text.split('CLAUDE AND GPT MODELS', 1)[0] + 'CLAUDE AND GPT MODELS\n'
        result = parse_usage(text, 'agy')
        self.assertEqual(result.exit_code, 1)
        self.assertEqual(dict(result.extra), {
            'claude_5h': '?', 'claude_week': '?',
            'claude_reset5h': '?', 'claude_resetweek': '?'})


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
