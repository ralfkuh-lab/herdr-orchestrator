"""Frozen legacy protocols plus independent invariants for dialog selection."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from herd_parse import parse_dialog, marked_bar_option, check_bar_dialog, match_bar_option

REFERENCE = json.loads((ROOT / 'tests/fixtures/dialog/expected.json').read_text(encoding='utf-8'))


class DialogParserTests(unittest.TestCase):
    def test_legacy_results(self):
        for case in REFERENCE['cases']:
            with self.subTest(name=case['name'], command=case['command'], args=case['args']):
                text = REFERENCE['views'][case['view']]
                stdout, stderr = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    if case['command'] == 'dialog':
                        result = parse_dialog(text, case['args'][0])
                        output = result.output
                        diagnostics = ''.join(line + '\n' for line in result.diagnostics)
                    elif case['command'] == 'bar-match':
                        output = match_bar_option(case['args'][0], case['args'][1:])
                        diagnostics = ''
                    else:
                        fn = marked_bar_option if case['command'] == 'bar-marked' else check_bar_dialog
                        output, diagnostics = fn(text, case['args']), ''
                self.assertEqual(stdout.getvalue() + stderr.getvalue(), '')
                self.assertEqual(output + '\n', case['stdout'])
                self.assertEqual(diagnostics, case['stderr'])

    def test_cli_protocol(self):
        for case in REFERENCE['cases']:
            with self.subTest(name=case['name'], command=case['command'], args=case['args']):
                args = ['--target=' + case['args'][0]] if case['command'] == 'dialog' else ['--', *case['args']]
                if case['command'] == 'bar-match':
                    args = ['--target=' + case['args'][0], '--', *case['args'][1:]]
                p = subprocess.run([sys.executable, str(ROOT / 'scripts/herd_parse.py'),
                                    case['command'], *args],
                                   input=REFERENCE['views'][case['view']], text=True,
                                   capture_output=True, timeout=5)
                self.assertEqual((p.stdout, p.stderr, p.returncode),
                                 (case['stdout'], case['stderr'], case['exit_code']))

    def test_selection_and_ambiguity(self):
        self.assertEqual(parse_dialog(' 1. Yes\n❯ 2. No', 'Yes').output, '-1\tYes')
        self.assertEqual(parse_dialog('1 (●) Yes\n2 ( ) No', 'No').output, 'key:2\tNo')
        self.assertEqual(parse_dialog('❯ 1. Yes once\n2. Yes always', 'Yes').output, 'AMBIG')
        self.assertEqual(parse_dialog('1  Yes\n2  No', 'Yes').output, 'NOOPTS')

    def test_identity_tracks_request_not_scroll_or_selection(self):
        def identity(view):
            return parse_dialog(view, 'Yes').diagnostics[0]
        before = 'Bash command\n git status\nDo you want to proceed?\n❯ 1. Yes\n2. No'
        after = 'Older text\nBash command\n git   status\nDo you want to proceed?\n1. Yes\n❯ 2. No'
        self.assertTrue(identity(before).startswith('IDENTITY\t'))
        self.assertEqual(identity(before), identity(after))
        self.assertNotEqual(identity(before), identity(before.replace('git status', 'git diff')))
        self.assertFalse(any(x.startswith('IDENTITY') for x in parse_dialog('1. Yes\n2. No', 'Yes').diagnostics))

    def test_bar_followup_and_ansi_padding(self):
        self.assertEqual(check_bar_dialog('No  Yes  ⇆ select enter confirm', ['Yes', 'No']), 'SAME')
        self.assertEqual(check_bar_dialog('Allow  Reject  ⇆ select enter confirm', ['Yes', 'No']), 'FOLLOW\tAllow | Reject')
        self.assertEqual(check_bar_dialog('Permission required', ['Yes', 'No']), 'SAME')
        self.assertEqual(check_bar_dialog('Working', ['Yes', 'No']), 'GONE')
        self.assertEqual(marked_bar_option('\x1b[48;2;206;203;0mYes\x1b[0m', ['Yes']), 'NOMARK')

    def test_independent_immutable_results(self):
        from dataclasses import FrozenInstanceError
        first = parse_dialog('❯ 1. Yes\n2. No', 'Yes')
        parse_dialog('', 'No')
        self.assertEqual(first.diagnostics, ('OPT\t*\tYes', 'OPT\t \tNo'))
        with self.assertRaises(FrozenInstanceError):
            first.output = 'NOOPTS'

    def test_cli_accepts_option_like_targets_and_labels(self):
        for command, args, text, expected in [
            ('dialog', ['--target=--yes'], '1. --yes\n2. No', '0\t--yes\n'),
            ('bar-check', ['--', '--yes', 'No'], '--yes  No  ⇆ select enter confirm', 'SAME\n'),
            ('bar-marked', ['--', '--yes'], '\x1b[38;2;0;0;0m\x1b[48;2;206;203;0m--yes\x1b[0m', '--yes\n'),
        ]:
            p = subprocess.run([sys.executable, str(ROOT / 'scripts/herd_parse.py'), command, *args],
                               input=text, text=True, capture_output=True, timeout=5)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stdout, expected)


if __name__ == '__main__':
    unittest.main()
