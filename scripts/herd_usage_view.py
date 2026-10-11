"""Pure reconstruction of agy usage pages, independent of terminal I/O.

Keep legacy blank-line and partial diagnostic behavior during extraction.
The caller owns scroll budgets, read retries and key delivery.
"""
from dataclasses import asdict, dataclass
import json
import re
from typing import Optional, Tuple


FOOTER = re.compile(r'\(([0-9]+)(?:–|-)([0-9]+)\s+of\s+([0-9]+)\s+lines\)')


@dataclass(frozen=True)
class AgyPage:
    first: int
    last: int
    total: int
    rows: tuple
    tall: Optional[str] = None

    @property
    def width(self) -> int:
        return max(1, self.last - self.first + 1)


def _legacy_join(lines) -> str:
    # The Bash accumulator drops initial empty lines, but retains later ones.
    text = ''
    for line in lines:
        text = text + '\n' + line if text else line
    return text


def parse_agy_page(text: str) -> AgyPage:
    # mapfile <<< "$snapshot" adds a newline and splits on LF only.
    lines = text.split('\n')
    for idx, line in enumerate(lines):
        match = FOOTER.search(line)
        if match:
            first, last, total = map(int, match.groups())
            width = max(1, last - first + 1)
            start = max(0, idx - width)
            rows = tuple((first + k, lines[start + k])
                         for k in range(min(width, idx - start)))
            return AgyPage(first, last, total, rows)
    start = next((i + 1 for i, line in enumerate(lines) if 'Models & Quota' in line), 0)
    end = next((i for i in range(start, len(lines)) if 'esc Close' in lines[i]), len(lines))
    return AgyPage(0, 0, 0, (), _legacy_join(lines[start:end]))


@dataclass(frozen=True)
class AgyCollection:
    first: int
    last: int
    total: int
    width: int
    budget: int
    rows: tuple
    tall: Optional[str] = None

    @property
    def has_footer(self) -> bool:
        return self.tall is None

    @classmethod
    def start(cls, page: AgyPage):
        return cls(page.first, page.last, page.total, page.width,
                   (page.total + page.width - 1) // page.width + 2,
                   page.rows, page.tall)

    def advance(self, page: AgyPage) -> Tuple['AgyCollection', bool]:
        if not self.has_footer or page.tall is not None or page.first <= self.first:
            return self, False
        rows = dict(self.rows)
        rows.update(page.rows)
        return AgyCollection(page.first, page.last, page.total, page.width,
                             self.budget, tuple(sorted(rows.items()))), True

    def render(self, field: str) -> str:
        if self.tall is not None:
            return self.tall
        rows = dict(self.rows)
        present = [(pos, rows[pos]) for pos in range(1, self.total + 1) if pos in rows]
        if field == 'error':
            # Down failure used a separate diagnostic accumulator in Bash.
            return '\n'.join(f'{pos}: {line}' for pos, line in present)
        text, probe = '', ''
        for pos, line in present:
            if text:
                text += '\n' + line
                probe += f'\n{pos}: {line}'
            else:
                text = line
                probe = f'{pos}: {line}'
        if field == 'text' or len(present) == self.total:
            return text
        return probe

    def to_json(self) -> str:
        return json.dumps(asdict(self), ensure_ascii=True, separators=(',', ':'))

    @classmethod
    def from_json(cls, text: str):
        data = json.loads(text)
        data['rows'] = tuple(tuple(row) for row in data['rows'])
        return cls(**data)


def collect_agy_input(text: str) -> str:
    """CLI protocol: JSON state line (empty initially), then the new snapshot.

    Output: updated JSON state, then numeric metadata for the Bash I/O loop.
    Text is never interpolated into shell code or passed as a command argument.
    """
    state, _, snapshot = text.partition('\n')
    page = parse_agy_page(snapshot)
    if state:
        result, accepted = AgyCollection.from_json(state).advance(page)
    else:
        result, accepted = AgyCollection.start(page), True
    metadata = (result.first, result.last, result.total, result.width,
                result.budget, int(result.has_footer), int(accepted))
    return result.to_json() + '\n' + '\t'.join(map(str, metadata))
