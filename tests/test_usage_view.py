"""Frozen Bash collector results and independent page reconstruction checks."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from herd_usage_view import AgyCollection, parse_agy_page, collect_agy_input
from herd_parse import usage_poll_iterations

CASES = json.loads((ROOT / 'tests/fixtures/usage/agy-collection.json').read_text(encoding='utf-8'))['cases']


class UsageViewTests(unittest.TestCase):
    def test_frozen_collector_output_and_terminal_actions(self):
        source = (ROOT / 'scripts/herd.sh').read_text(encoding='utf-8')
        collector = source[source.index('USAGE_AGY_HAS_FOOTER=0'):source.index('\nusage_one()')]
        for case in CASES:
            with self.subTest(case=case['name']), tempfile.TemporaryDirectory() as tmp:
                work = Path(tmp)
                (work / 'collector.sh').write_bytes(collector.encode('utf-8'))
                (work / 'initial').write_bytes(case['snapshots'][0].encode('utf-8'))
                (work / 'last').write_bytes(case['snapshots'][-1].encode('utf-8'))
                (work / 'count').write_bytes(b'0')
                for i, snapshot in enumerate(case['snapshots'][1:], 1):
                    (work / str(i)).write_bytes(snapshot.encode('utf-8'))
                if case.get('fail'):
                    (work / 'fail').touch()
                p = subprocess.run(['bash', str(ROOT / 'tests/fixtures/usage/collect-harness.sh')],
                                   env={**os.environ, 'COLLECTOR': str(work / 'collector.sh'),
                                        'CASE_DIR': tmp, 'REPO': str(ROOT)},
                                   capture_output=True, timeout=10)
                self.assertEqual(p.returncode, 0, p.stderr)
                text, raw, parse_rc, rc = p.stdout.decode().split('\0')
                actual = dict(text=text, raw=raw, parse_rc=int(parse_rc), rc=int(rc),
                              stderr=p.stderr.decode(), reads=int((work / 'count').read_text(encoding='utf-8')),
                              keys=(work / 'keys').read_text(encoding='utf-8') if (work / 'keys').exists() else '')
                self.assertEqual(actual, case['expected'])

    def test_pure_reconstruction_against_frozen_text(self):
        for case in CASES:
            with self.subTest(case=case['name']):
                state = AgyCollection.start(parse_agy_page(case['snapshots'][0].rstrip('\n')))
                for snapshot in case['snapshots'][1:case['expected']['reads'] + 1]:
                    state, _ = state.advance(parse_agy_page(snapshot.rstrip('\n')))
                if case.get('fail'):
                    self.assertEqual(state.render('error'), case['expected']['raw'])
                else:
                    self.assertEqual(state.render('text'), case['expected']['text'])
                    self.assertEqual(state.render('raw'), case['expected']['raw'])

    def test_positions_overlap_and_blank_lines(self):
        first = parse_agy_page('Chrome\nA\n\nC\n(1–3 of 5 lines)\nesc Close')
        self.assertEqual(first.rows, ((1, 'A'), (2, ''), (3, 'C')))
        original = AgyCollection.start(first)
        following = parse_agy_page('C updated\nD\nE\n(3-5 of 5 lines)')
        result, accepted = original.advance(following)
        self.assertTrue(accepted)
        self.assertEqual(result.render('text'), 'A\n\nC updated\nD\nE')
        self.assertEqual(original.rows, first.rows)
        self.assertEqual(result.budget, original.budget)
        self.assertEqual(result.advance(following), (result, False))

    def test_incomplete_and_send_failure_diagnostics(self):
        state = AgyCollection.start(parse_agy_page('\nB\n(1-2 of 4 lines)'))
        self.assertEqual(state.render('text'), 'B')
        self.assertEqual(state.render('raw'), '2: B')
        self.assertEqual(state.render('error'), '1: \n2: B')
        state, accepted = state.advance(parse_agy_page('D\n(4-4 of 4 lines)'))
        self.assertTrue(accepted)
        self.assertEqual(state.render('raw'), '2: B\n4: D')

    def test_transport_preserves_arbitrary_text_without_io(self):
        text = 'Models & Quota\nQuotes " and tabs\t, Unicode ä, backslash \\ and $(echo no)\n\nesc Close'
        capture = io.StringIO()
        with contextlib.redirect_stdout(capture), contextlib.redirect_stderr(capture):
            response = collect_agy_input('\n' + text)
        self.assertEqual(capture.getvalue(), '')
        wire, metadata = response.split('\n')
        state = AgyCollection.from_json(wire)
        self.assertEqual(state.render('text'), text.split('\n', 1)[1][:-len('\nesc Close')])
        self.assertEqual(metadata.split('\t')[-2:], ['0', '1'])
        self.assertEqual(AgyCollection.from_json(state.to_json()), state)

    def test_cli_preserves_bytes_with_herd_utf8_environment(self):
        # herd.sh exports PYTHONUTF8=1; this enables surrogateescape on stdio.
        env = {**os.environ, 'PYTHONUTF8': '1'}
        body = b'Alpha\r\ninvalid: \xff\n'
        p = subprocess.run([sys.executable, str(ROOT / 'scripts/herd_parse.py'), 'agy-collect'],
                           input=b'\nModels & Quota\n' + body + b'esc Close',
                           env=env, capture_output=True, timeout=5)
        self.assertEqual(p.returncode, 0, p.stderr)
        state = p.stdout.split(b'\n', 1)[0]
        for field in ('text', 'raw'):
            rendered = subprocess.run([sys.executable, str(ROOT / 'scripts/herd_parse.py'),
                                       'agy-render', '--field=' + field], input=state,
                                      env=env, capture_output=True, timeout=5)
            self.assertEqual((rendered.stdout, rendered.stderr, rendered.returncode),
                             (body[:-1], b'', 0))

    def test_poll_iterations_and_cli(self):
        for wait, poll, expected in [('6', '.5', 12), ('1', '.3', 4), ('0', '.5', 0),
                                     ('-1', '0', 0), ('1', '0', 1), ('1', '-2', 1),
                                     ('0.0001', '1', 1)]:
            with self.subTest(wait=wait, poll=poll):
                self.assertEqual(usage_poll_iterations(wait, poll), expected)
                p = subprocess.run([sys.executable, str(ROOT / 'scripts/herd_parse.py'),
                                    'usage-polls', '--wait=' + wait, '--poll=' + poll],
                                   capture_output=True, text=True, timeout=5)
                self.assertEqual((p.stdout, p.stderr, p.returncode), (str(expected) + '\n', '', 0))
        for wait, poll in [('bad', '.5'), ('1', 'nan'), ('inf', '.5')]:
            with self.assertRaises((ValueError, OverflowError)):
                usage_poll_iterations(wait, poll)


if __name__ == '__main__':
    unittest.main()
