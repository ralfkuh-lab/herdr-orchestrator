#!/usr/bin/env python3
"""Pure parsers for Herdr terminal text; CLI adapters preserve herd.sh protocols.

Usage and dialog parsing are extracted. Terminal I/O, freshness checks and
view cleanup remain in herd.sh. Keep parsing changes separate from extraction.
"""
import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import math
import os
import re
import sys
from typing import Optional


@dataclass(frozen=True)
class UsageResult:
    pct5: str
    week: str
    reset5: str
    resetw: str
    ok: bool

    @property
    def exit_code(self) -> int:
        return 0 if self.ok else 1

    def to_tsv(self, name: str, kind: str) -> str:
        return (f"{name}\t{kind}\t5h={self.pct5}\tweek={self.week}"
                f"\treset5h={self.reset5}\tresetweek={self.resetw}")


@dataclass(frozen=True)
class CodexLogResult:
    """Limits from one codex rollout line, in the known usage column layout."""
    pct5: str
    week: str
    reset5: str
    resetweek: str
    age_min: int
    reached: Optional[str]

    def to_tsv(self) -> str:
        line = (f"codex-log\tcodex\t5h={self.pct5}\tweek={self.week}"
                f"\treset5h={self.reset5}\tresetweek={self.resetweek}"
                f"\tage={self.age_min}m")
        if self.reached:
            line += f"\treached={self.reached}"
        return line


def parse_usage(text: str, kind: str) -> UsageResult:
    """Parse one captured view without I/O; preserve partial fields on errors.

    agy input is the reconstructed quota view, not a single scrolling page.
    Unknown backends and incomplete input return an unsuccessful result.
    """
    pct5 = "?"
    week = "?"
    reset5 = "?"
    resetw = "?"
    reset5_optional = resetw_optional = False
    ok = True

    try:
        if kind == "codex":
            # Weekly limit: the required anchor; a block without a weekly line yields no partial fields.
            # Find the last occurrence of "Weekly limit:" at the start of a line (F1).
            # 5h limit has been optional since codex 0.156; reserve lines are ignored.
            lines = [re.sub(r"^[│┃|]\s*|\s*[│┃|]$", "", l) for l in text.splitlines()]
            weekly_indices = [
                i for i, l in enumerate(lines)
                if re.match(r"^\s*weekly limit:", l, re.IGNORECASE)
            ]
            if weekly_indices:
                w_idx = weekly_indices[-1]
                start_idx = weekly_indices[-2] + 1 if len(weekly_indices) > 1 else 0

                pre_text = "\n".join(lines[start_idx:w_idx])
                m5_line = re.search(r"(?:^|\n)\s*5h limit:\s*", pre_text, re.IGNORECASE)
                if m5_line:
                    # codex >= 0.153.4 shows a bar "[████░░░░]" between label and
                    # percentage — skip it optionally (older layouts have none).
                    m5 = re.search(r"5h limit:\s*(?:\[[^\]]*\]\s*)?([0-9]+%\s*left)(.*?)$", pre_text[m5_line.start():], re.DOTALL | re.IGNORECASE)
                    if m5:
                        pct5 = " ".join(m5.group(1).split())
                        rest = " ".join(m5.group(2).split())
                        mr = re.search(r"\(resets\s+([^)]+)\)", rest, re.IGNORECASE)
                        if mr:
                            reset5 = mr.group(1).strip()
                        else:
                            # F2: a missing reset parenthesis part is ? and ok=False
                            reset5 = "?"
                            ok = False
                    else:
                        ok = False
                else:
                    pct5 = "–"
                    reset5 = "–"

                post_clean = "\n".join(lines[w_idx:])
                mw = re.search(r"^\s*Weekly limit:\s*(?:\[[^\]]*\]\s*)?([0-9]+%\s*left)(.*?)(?=\n[^\n]*\blimit:|\n\s*\n|╰|─|$)", post_clean, re.DOTALL | re.IGNORECASE)
                if mw:
                    week = " ".join(mw.group(1).split())
                    rest = " ".join(mw.group(2).split())
                    mr = re.search(r"\(resets\s+([^)]+)\)", rest, re.IGNORECASE)
                    if mr:
                        resetw = mr.group(1).strip()
                    else:
                        # F2: a missing reset parenthesis part is ? and ok=False
                        resetw = "?"
                        ok = False
                else:
                    ok = False
            else:
                ok = False

        elif kind == "grok":
            # F6: grok has no 5h window -> immediately set to –
            pct5 = "–"
            reset5 = "–"
            # F12: do not hard-wire the plan title to SuperGrok; take the last occurrence (F1)
            matches = list(re.finditer(r"Weekly limit\s*\([^)]+\)", text, re.IGNORECASE))
            if matches:
                last_m = matches[-1]
                sec = text[last_m.start():]
                m_end = re.search(r"\n\s*[└─]", sec)
                if m_end:
                    sec = sec[:m_end.start()]
                bar_m = re.search(r"((?:█|░){5,})", sec)
                if bar_m:
                    bar = bar_m.group(1)
                    filled = bar.count("█")
                    empty = bar.count("░")
                    total = filled + empty
                    pct_used = round(filled / total * 100) if total > 0 else 0
                    pct_left = 100 - pct_used
                    week = f"{pct_left}% left (bar {filled}/{total})"
                else:
                    ok = False
                mr = re.search(r"Resets:\s*([^\n│┃|]+)", sec)
                if mr:
                    resetw = mr.group(1).strip()
                else:
                    ok = False
            else:
                ok = False

        elif kind == "claude":
            # Take the last occurrence of "Current session" (F1)
            matches = list(re.finditer(r"Current session", text, re.IGNORECASE))
            if matches:
                last_m = matches[-1]
                sec = text[last_m.start():]
                m_sess = re.search(r"Current session\s*(.*?)(?=Current week|$)", sec, re.DOTALL | re.IGNORECASE)
                if m_sess:
                    s = m_sess.group(1)
                    mp = re.search(r"(?<![0-9.+-])([0-9]+)%\s*used\b", s)
                    if mp and 0 <= int(mp.group(1)) <= 100:
                        pct5 = f"{100 - int(mp.group(1))}% left"
                    else:
                        ok = False
                    mr = re.search(r"Resets[^\S\n]+([^\n│┃|]+)", s)
                    if mr and mr.group(1).strip():
                        reset5 = mr.group(1).strip()
                    elif (mp and mp.group(1) == "0"
                          and not re.search(r"\bResets\b", s, re.IGNORECASE)):
                        # Claude shows no reset before the session window starts.
                        # An existing but empty reset line is not such a case.
                        reset5_optional = True
                    else:
                        ok = False
                else:
                    ok = False

                m_week = re.search(r"Current week\s*\(all models\)\s*(.*?)(?=Current week\s*\(|\Z)", sec, re.DOTALL | re.IGNORECASE)
                if m_week:
                    w = m_week.group(1)
                    mp = re.search(r"([0-9]+)%\s*used", w)
                    if mp:
                        week = f"{100 - int(mp.group(1))}% left"
                    else:
                        ok = False
                    mr = re.search(r"Resets[^\S\n]+([^\n│┃|]+)", w)
                    if mr and mr.group(1).strip():
                        resetw = mr.group(1).strip()
                    else:
                        ok = False
                else:
                    ok = False
            else:
                ok = False

        elif kind == "agy":
            # Reconstructed text no longer contains footer or key lines (position-based collection).
            # The overlay has only ONE generation; the first Gemini group is authoritative.
            matches = list(re.finditer(r"GEMINI MODELS", text))
            if matches:
                first_m = matches[0]
                sec = text[first_m.start():]
                m_end = re.search(r"\n\s*[A-Z][A-Z ]*MODELS", sec[len("GEMINI MODELS"):])
                if m_end:
                    sec = sec[:len("GEMINI MODELS") + m_end.start()]

                # Strip Account: lines and Models & Quota from the section before the reset match (N1/muse-MINOR 1),
                # instead of only discarding the hit (e.g. for refreshes in\nAccount: test\n4h 22m).
                sec = "\n".join([
                    line for line in sec.splitlines()
                    if not line.strip().startswith("Account:") and "Models & Quota" not in line
                ])

                # 5h section = from Five Hour Limit Remaining to the next MODELS heading or end of text
                idx5 = sec.find("Five Hour Limit Remaining")
                if idx5 != -1:
                    s5 = sec[idx5 + len("Five Hour Limit Remaining"):]
                    m_end5 = re.search(r"(?:Weekly Limit Remaining|\n\s*[A-Z][A-Z ]*MODELS)", s5)
                    if m_end5:
                        s5 = s5[:m_end5.start()]

                    # FIRST NN% remaining, otherwise the bar value
                    mp = re.search(r"([0-9]+)%\s*remaining", s5)
                    if not mp:
                        mp = re.search(r"\[[^\]]*\]\s*([0-9]+)(?:\.[0-9]+)?%", s5)
                    if mp:
                        pct5 = f"{mp.group(1)}% left"
                    else:
                        ok = False

                    # Search for the reset independently of the percentage; delimit reset fields against Account/header (R2-5)
                    mr = re.search(r"(?:Refreshes|Resets) in\s+([^\n│┃|]+)", s5)
                    if mr and not mr.group(1).strip().startswith("Account:"):
                        reset5 = mr.group(1).strip()
                    elif (mp and re.search(r"(?<![0-9.])100(?:\.0+)?%", mp.group(0))
                          and re.search(r"\bQuota available\b", s5)
                          and not re.search(r"(?:Refreshes|Resets) in", s5)):
                        reset5_optional = True  # reset not yet finalized, stays ?.
                    else:
                        ok = False
                else:
                    ok = False

                # Weekly section = from Weekly Limit Remaining to Five Hour Limit Remaining
                idxw = sec.find("Weekly Limit Remaining")
                if idxw != -1:
                    sw = sec[idxw + len("Weekly Limit Remaining"):]
                    m_endw = re.search(r"(?:Five Hour Limit Remaining|\n\s*[A-Z][A-Z ]*MODELS)", sw)
                    if m_endw:
                        sw = sw[:m_endw.start()]

                    mp = re.search(r"([0-9]+)%\s*remaining", sw)
                    if not mp:
                        mp = re.search(r"\[[^\]]*\]\s*([0-9]+)(?:\.[0-9]+)?%", sw)
                    if mp:
                        week = f"{mp.group(1)}% left"
                    else:
                        ok = False

                    mr = re.search(r"(?:Refreshes|Resets) in\s+([^\n│┃|]+)", sw)
                    if mr and not mr.group(1).strip().startswith("Account:"):
                        resetw = mr.group(1).strip()
                    elif (mp and re.search(r"(?<![0-9.])100(?:\.0+)?%", mp.group(0))
                          and re.search(r"\bQuota available\b", sw)
                          and not re.search(r"(?:Refreshes|Resets) in", sw)):
                        resetw_optional = True  # reset not yet finalized, stays ?.
                    else:
                        ok = False
                else:
                    ok = False
            else:
                # F11: without a GEMINI MODELS header do not parse at all, all four fields stay ?
                ok = False
        elif kind == "muse":
            # Take the last occurrence of "Subscription" (do not hard-wire the plan title behind it)
            matches = list(re.finditer(r"Subscription", text, re.IGNORECASE))
            if matches:
                last_m = matches[-1]
                sec = text[last_m.start():]
                delim_5 = r"(?=[│┃|]|\n\s*(?:Weekly|as of|[─│┃|]|\s*$)|\Z)"
                # Empty-value guard (post-review 2026-09-03): after "Resets" the
                # next field must not follow directly, else an empty reset would swallow the weekly line.
                m5 = re.search(r"Current\s+([0-9]+)%\s*used\s*·\s*Resets\s+(?!\s*(?:Weekly|as of)\b|\s*[─│┃|])(.*?)" + delim_5, sec, re.DOTALL | re.IGNORECASE)
                if m5 and m5.group(2).strip():
                    pct5 = f"{100 - int(m5.group(1))}% left"
                    reset5 = re.sub(r"\s+", " ", m5.group(2)).strip()
                else:
                    ok = False

                delim_w = r"(?=[│┃|]|\n\s*(?:as of|[─│┃|]|\s*$)|\Z)"
                mw = re.search(r"Weekly\s+([0-9]+)%\s*used\s*·\s*Resets\s+(?!\s*as of\b|\s*[─│┃|])(.*?)" + delim_w, sec, re.DOTALL | re.IGNORECASE)
                if mw and mw.group(2).strip():
                    week = f"{100 - int(mw.group(1))}% left"
                    resetw = re.sub(r"\s+", " ", mw.group(2)).strip()
                else:
                    ok = False
            else:
                ok = False
        else:
            ok = False
    except Exception:
        ok = False

    if (not reset5 or not resetw or "?" in (pct5, week)
            or (reset5 == "?" and not reset5_optional)
            or (resetw == "?" and not resetw_optional)):
        ok = False

    return UsageResult(pct5, week, reset5, resetw, ok)


@dataclass(frozen=True)
class DialogPlan:
    """Shell plan and ordered diagnostic lines, without terminal side effects."""

    output: str
    diagnostics: tuple = ()


def extract_bar_options(lines):
    bar_line = None
    for ln in lines:
        if "⇆" in ln and re.search(r"select.*enter.*confirm", ln, re.I):
            bar_line = ln
    if not bar_line:
        keywords = ["allow once", "allow always", "reject"]
        for ln in lines:
            if sum(1 for kw in keywords if kw in ln.lower()) >= 2:
                bar_line = ln
    if not bar_line:
        return []
    clean_line = re.sub(r"^\s*[┃│|]\s*", "", bar_line)
    prefix = re.split(r"(?:ctrl\+f\s+fullscreen|⇆\s*select)", clean_line, flags=re.I)[0]
    raw_tokens = [t.strip() for t in re.split(r"\s{2,}", prefix) if t.strip()]
    help_pat = re.compile(r"^(?:[┃│|]|ctrl\+.*|.*fullscreen|⇆.*|.*select|enter\s+confirm|esc\b.*)$", re.I)
    bar_opts = [t for t in raw_tokens if not help_pat.match(t)]
    return bar_opts if len(bar_opts) >= 2 else []


def marked_bar_option(ansi: str, opts) -> str:
    """Return the selected option, or NOMARK for unrecognized ANSI styling."""
    pat = re.compile(
        r"(?:\x1b\[38;2;0;0;0m\x1b\[48;2;206;203;0m|\x1b\[48;2;206;203;0m\x1b\[38;2;0;0;0m)"
        r"([^\x1b]+?)"
        r"\x1b\[0m"
    )
    matches = pat.findall(ansi)
    marked = None
    for m in reversed(matches):
        m_clean = m.strip()
        for opt in opts:
            if m_clean.lower() == opt.lower():
                marked = opt
                break
        if marked:
            break
    if marked:
        return marked
    else:
        return "NOMARK"


def check_bar_dialog(post_buf: str, old_opts) -> str:
    """Classify the view after confirmation as SAME, FOLLOW or GONE."""
    lines = post_buf.splitlines()
    new_bar_opts = extract_bar_options(lines)
    has_blocked = bool(re.search(r"permission required|allow once.*reject|reject.*allow once|⇆.*select.*enter.*confirm", post_buf, re.I))

    def norm_set(seq):
        return {re.sub(r"\s+", " ", s).strip().lower() for s in seq if s.strip()}

    old_set = norm_set(old_opts)
    new_set = norm_set(new_bar_opts)

    if new_bar_opts:
        if new_set == old_set:
            return "SAME"
        else:
            return "FOLLOW\t" + " | ".join(new_bar_opts)
    elif has_blocked:
        return "SAME"
    else:
        return "GONE"


def match_bar_option(target: str, opts) -> str:
    """Match a label by exact, prefix, then substring precedence."""
    def norm(s):
        s = s.replace("\u00a0", " ")
        for c in "\u2019\u2018\u02bc\u00b4":
            s = s.replace(c, "\x27")
        for c in "\u201c\u201d\u201e":
            s = s.replace(c, "\x22")
        return re.sub(r"\s+", " ", s).strip().lower()

    target_n = norm(target)
    norms = [norm(t) for t in opts]
    hits = [i for i, n in enumerate(norms) if n == target_n]
    if len(hits) != 1:
        if len(hits) > 1:
            return "AMBIG"
        hits = [i for i, n in enumerate(norms) if n.startswith(target_n)]
        if len(hits) != 1:
            if len(hits) > 1:
                return "AMBIG"
            hits = [i for i, n in enumerate(norms) if target_n in n]
            if not hits:
                return "NOMATCH"
            if len(hits) > 1:
                return "AMBIG"
    idx = hits[0]
    return f"{idx}\t{opts[idx]}"


def parse_dialog(text: str, target: str) -> DialogPlan:
    """Plan a selection from visible text; never read or operate a terminal."""
    diagnostics = []
    want_first = (target == "__FIRST__")
    def norm(s):
        s = s.replace("\u00a0", " ")
        for c in "\u2019\u2018\u02bc\u00b4":
            s = s.replace(c, "\x27")
        for c in "\u201c\u201d\u201e":
            s = s.replace(c, "\x22")
        return re.sub(r"\s+", " ", s).strip().lower()
    lines = text.splitlines()
    # Option lines, form 1+2+grok+muse: optional box prefix (┃ grok command
    # approval 2026-09-02; │ codex frame), then optional selection marker
    # (› ❯ > ▶ — kimi uses ▶), then numbering ("1." / "1)") OR muse
    # ("1  text", min. 2 spaces) OR radio ("(●)"/"( )"/"(x)") OR grok
    # "1 (●) text" (digit, whitespace, radio) and the text.
    # Numbered hits only as a consecutive run starting at 1 (min. 2 entries);
    # runs by NUMBER SEQUENCE, not line adjacency — wrapped
    # option texts do not interrupt, a number jump does. Several
    # valid runs: the LAST one (the dialog is at the bottom). Radio-only: min. 2.
    pat = re.compile(
        r"^\s*(?:[┃│]\s*)?(?P<sel>[›❯>▶]\s+)?"
        r"(?:(?P<num>\d{1,2})[.)]\s+|(?P<num2>\d{1,2})\s{2,}|(?P<gnum>\d{1,2})\s+\((?P<gradio>[●○xX ])\)\s*|\((?P<radio>[●○xX ])\)\s*)"
        r"(?P<text>\S.*)$")
    opts = []
    numbered = []
    radio_only = []
    for ln in lines:
        m = pat.match(ln)
        if not m or not (m.group("num") or m.group("num2") or m.group("gnum") or m.group("radio") is not None or m.group("gradio") is not None):
            continue
        radio_ch = (m.group("gradio") or m.group("radio") or "")
        selected = bool(m.group("sel")) or radio_ch.strip().lower() in ("●", "x")
        text = m.group("text").strip()
        if m.group("num") or m.group("num2") or m.group("gnum"):
            val = int(m.group("num") or m.group("num2") or m.group("gnum"))
            is_num2 = bool(m.group("num2"))
            has_sel = bool(m.group("sel"))
            numbered.append((val, text, selected, m.group("gnum"), is_num2, has_sel))
        else:
            radio_only.append((text, selected, None))
    def is_valid_run(acc):
        if len(acc) < 2 or acc[0][0] != 1:
            return False
        # num2 (digit without a period) counts only if at least one line of the
        # detected run carries the selection marker (the muse trust dialog has > 1;
        # pure tables/prose without a marker like 1  a / 2  b are discarded).
        if any(it[4] for it in acc) and not any(it[5] for it in acc):
            return False
        return True
    def last_num_run(items):
        found = []
        acc = []
        for it in items:
            if not acc or it[0] == acc[-1][0] + 1:
                acc.append(it)
                continue
            if is_valid_run(acc):
                found.append(acc)
            acc = [it]
        if is_valid_run(acc):
            found.append(acc)
        return found[-1] if found else None
    run = last_num_run(numbered)
    if run:
        opts = [(t, s, g) for _n, t, s, g, _is_num2, _has_sel in run]
    elif len(radio_only) >= 2:
        opts = radio_only
    if not opts:
        bar_opts = extract_bar_options(lines)
        if bar_opts:
            return DialogPlan("BAR\t" + "\t".join(bar_opts), tuple(diagnostics))
        # Form 3: selector-only lists without number/radio (agy/Antigravity:
        # "> Yes, I trust this folder" / "  No, exit"). Only the marked line
        # is unambiguously recognizable; unmarked options sit directly above/
        # below it in the same text column. Deliberately narrow so prose
        # does not pass as an option: exactly ONE marker line, contiguous
        # block, indentation of the text column +-3, short lines (2..60), no
        # question/colon/frame lines, max. 8 options. Optional box
        # prefix as in form 1/2; col counts it, otherwise neighbors fall
        # out of the +-3 window. Prompt-echo trap (grok 2026-09-02): the
        # marked line itself is subject to the same 2-60 characters and must
        # not end in a time (12h as well as 24h, with/without seconds) — otherwise
        # it is grok's composer echo.
        selpat = re.compile(r"^(\s*(?:[┃│]\s*)?)([›❯>▶])\s+(\S.*)$")
        marked = [(i, m) for i, ln in enumerate(lines) if (m := selpat.match(ln))]
        if len(marked) == 1:
            idx, m = marked[0]
            marked_text = m.group(3).strip()
            if (2 <= len(marked_text) <= 60
                    and not re.search(r"\b[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?(?: ?[AP]M)?\s*$", marked_text)):
                col = len(m.group(1)) + len(m.group(2)) + 1
                def plain_opt(ln):
                    m2 = re.match(r"^(\s*(?:[┃│]\s*)?)(\S.*)$", ln)
                    if not m2: return None
                    text = m2.group(2).strip()
                    if not (2 <= len(text) <= 60): return None
                    if abs(len(m2.group(1)) - col) > 3: return None
                    if text.endswith((":", "?")) or re.match(r"^[─│╭╰┌└├═|+-]", text): return None
                    return text
                block = [(idx, marked_text, True)]
                for j in range(idx - 1, -1, -1):
                    t = plain_opt(lines[j])
                    if t is None: break
                    block.insert(0, (j, t, False))
                for j in range(idx + 1, len(lines)):
                    t = plain_opt(lines[j])
                    if t is None: break
                    block.append((j, t, False))
                if 2 <= len(block) <= 8:
                    opts = [(t, s, None) for _, t, s in block]
    if not opts:
        return DialogPlan("NOOPTS", tuple(diagnostics))
    # Identity only for known Claude tool dialogs with a visible request.
    # Do not hash the whole viewport: scrollback and selection markers change
    # even while the same request is still open. Missing context stays
    # unknown; answer must not derive a confirmed follow-up dialog from it.
    if run:
        starts = [i for i, ln in enumerate(lines)
                  if (m := pat.match(ln)) and m.group("num") == "1"
                  and m.group("text").strip() == opts[0][0]]
        if starts:
            prefix = lines[:starts[-1]]
            headings = [i for i, ln in enumerate(prefix)
                        if re.fullmatch(r"\s*(?:Web Search|Fetch|Bash command)\s*", ln)]
            if headings:
                block = prefix[headings[-1]:]
                # Only up to the confirmation question, without selection/footer.
                stop = next((i for i, ln in enumerate(block)
                             if re.match(r"\s*Do you want to (?:proceed|allow)\b", ln)), len(block))
                block = block[:stop]
                payload = " ".join(" ".join(ln.split()) for ln in block[1:]).strip()
                if payload:
                    import hashlib
                    identity = hashlib.sha256((block[0].strip() + "\n" + payload).encode()).hexdigest()
                    diagnostics.append("IDENTITY\t" + identity)
    for t, s, _k in opts:
        mark = "*" if s else " "
        diagnostics.append(f"OPT\t{mark}\t{t}")
    if want_first:
        if opts[0][2]:
            return DialogPlan(f"key:{opts[0][2]}\t{opts[0][0]}", tuple(diagnostics))
        else:
            cur = next((i for i, row in enumerate(opts) if row[1]), 0)
            return DialogPlan(f"{0 - cur}\t{opts[0][0]}", tuple(diagnostics))
    target_n = norm(target)
    norms = [norm(t) for t, _, _ in opts]
    hits = [i for i, n in enumerate(norms) if n == target_n]
    if len(hits) != 1:
        if len(hits) > 1:
            return DialogPlan("AMBIG", tuple(diagnostics))
        hits = [i for i, n in enumerate(norms) if n.startswith(target_n)]
        if len(hits) != 1:
            if len(hits) > 1:
                return DialogPlan("AMBIG", tuple(diagnostics))
            hits = [i for i, n in enumerate(norms) if target_n in n]
            if not hits:
                return DialogPlan("NOMATCH", tuple(diagnostics))
            if len(hits) > 1:
                return DialogPlan("AMBIG", tuple(diagnostics))
    cur = next((i for i, row in enumerate(opts) if row[1]), 0)
    idx = hits[0]
    text, _sel, gnum = opts[idx]
    if gnum:
        return DialogPlan(f"key:{gnum}\t{text}", tuple(diagnostics))
    else:
        return DialogPlan(f"{idx - cur}\t{text}", tuple(diagnostics))


def usage_poll_iterations(wait: str, poll: str) -> int:
    """Preserve ceil(wait / poll), including zero/negative interval handling."""
    import math
    w, p = float(wait), float(poll)
    if w <= 0:
        return 0
    if p <= 0:
        return 1
    return int(math.ceil(w / p))


# --- codex limits from session logs (usage --log codex) ----------------------
# Pure evaluation: gets the lines and an aware `now`, reads no files
# and does not look at the clock itself. File search and output are done by run_codex_log.

CODEX_LOG_MAX_FILES = 20
CODEX_LOG_STALE_MINUTES = 60
_WINDOW_SLOTS = {300: "5h", 10080: "week"}


def _parse_codex_timestamp(value):
    if not isinstance(value, str):
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        stamp = datetime.fromisoformat(text)
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp


def _codex_window(window, reset_tz, fmt):
    """Remaining percent (conservatively rounded down) and reset of a window.

    Unusable values (non-finite percent, unformattable reset) drop the window
    instead of aborting the evaluation.
    """
    used = window.get("used_percent")
    if not isinstance(used, (int, float)) or isinstance(used, bool):
        return None
    try:
        if not math.isfinite(used):
            return None
    except OverflowError:  # integer beyond the float range
        return None
    left = math.floor(100 - used)
    resets = window.get("resets_at")
    if resets is None:
        reset = "?"
    elif isinstance(resets, (int, float)) and not isinstance(resets, bool):
        try:
            if reset_tz == "local":
                # System zone per reset time: accounts for daylight saving time
                # of the reset day, not the current offset of `now`.
                reset = datetime.fromtimestamp(resets).strftime(fmt)
            else:
                reset = datetime.fromtimestamp(resets, reset_tz).strftime(fmt)
        except (OverflowError, OSError, ValueError):
            return None
    else:
        reset = "?"
    return f"{left}% left", reset


def _codex_line(rl, reset_tz):
    """(pct5, reset5, week, resetweek, reached) of one rate_limits line.

    Windows are assigned via window_minutes, not via primary/
    secondary; unknown windows and missing values are ignored. If a window is
    missing, its field stays `–`. Without a recognized window: None.
    """
    values = {"5h": ("–", "–"), "week": ("–", "–")}
    valid = False
    for key in ("primary", "secondary"):
        window = rl.get(key)
        if not isinstance(window, dict):
            continue
        minutes = window.get("window_minutes")
        if not isinstance(minutes, (int, float)) or isinstance(minutes, bool):
            continue
        slot = _WINDOW_SLOTS.get(minutes)
        if slot is None:
            continue
        fmt = "%H:%M" if slot == "5h" else "%Y-%m-%d %H:%M"
        parsed = _codex_window(window, reset_tz, fmt)
        if parsed is None:
            continue
        values[slot] = parsed
        valid = True
    if not valid:
        return None
    reached = rl.get("rate_limit_reached_type")
    return (values["5h"][0], values["5h"][1], values["week"][0],
            values["week"][1], str(reached) if reached else None)


def parse_codex_log(lines, now, reset_tz=None):
    """Evaluate the last valid rate_limits line; None if there is none.

    Broken JSON lines and lines without rate_limits are skipped.
    `now` must be aware and only provides the age. `reset_tz` controls the
    reset time zone: None = time zone of `now` (controlled callers/tests),
    "local" = system zone per reset time (DST-correct, CLI), or a tzinfo.
    """
    if reset_tz is None:
        reset_tz = now.tzinfo if now.tzinfo is not None else timezone.utc
    selected = None
    for raw in lines:
        try:
            obj = json.loads(raw)
        except (json.JSONDecodeError, TypeError, ValueError):
            continue
        if not isinstance(obj, dict):
            continue
        payload = obj.get("payload")
        if not isinstance(payload, dict):
            continue
        rl = payload.get("rate_limits")
        if not isinstance(rl, dict):
            continue
        fields = _codex_line(rl, reset_tz)
        if fields is None:
            continue
        stamp = _parse_codex_timestamp(obj.get("timestamp"))
        if stamp is None:
            continue
        selected = (stamp, fields)
    if selected is None:
        return None
    stamp, (pct5, reset5, week, resetweek, reached) = selected
    age_min = max(0, int((now - stamp).total_seconds() // 60))
    return CodexLogResult(pct5, week, reset5, resetweek, age_min, reached)


def codex_log_files(sessions_dir, limit=CODEX_LOG_MAX_FILES):
    """Rollout files under sessions_dir by mtime descending, at most limit."""
    import glob
    paths = glob.glob(os.path.join(sessions_dir, "**", "rollout-*.jsonl"),
                      recursive=True)
    def mtime(path):
        try:
            return os.path.getmtime(path)
        except OSError:
            return float("-inf")
    paths.sort(key=mtime, reverse=True)
    return paths[:limit]


def run_codex_log(codex_home=None, now=None, out=None, err=None):
    """File search + output for `usage --log codex`; without herdr and without TUI."""
    out = sys.stdout if out is None else out
    err = sys.stderr if err is None else err
    if codex_home is None:
        codex_home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    if now is None:
        now = datetime.now().astimezone()
    sessions_dir = os.path.join(codex_home, "sessions")
    result = None
    for path in codex_log_files(sessions_dir):
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                # Pass the handle through directly: no second buffer for large rollouts.
                result = parse_codex_log(handle, now, reset_tz="local")
        except OSError:
            continue
        if result is not None:
            break
    if result is None:
        print(f"[herd] usage --log codex: no valid rate_limits line in the "
              f"{CODEX_LOG_MAX_FILES} newest files under {sessions_dir}", file=err)
        return 1
    print(result.to_tsv(), file=out)
    if result.age_min > CODEX_LOG_STALE_MINUTES:
        print(f"[herd] usage --log codex: snapshot is {result.age_min} min old "
              f"(value from the last codex turn)", file=err)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    usage = commands.add_parser("usage", help="parse a quota view from stdin")
    usage.add_argument("--name", required=True)
    usage.add_argument("--kind", required=True)
    dialog = commands.add_parser("dialog", help="plan a dialog selection from stdin")
    dialog.add_argument("--target", required=True)
    marked = commands.add_parser("bar-marked", help="read the selected ANSI bar option")
    marked.add_argument("options", nargs="*")
    check = commands.add_parser("bar-check", help="check a bar after confirmation")
    check.add_argument("options", nargs="*")
    match = commands.add_parser("bar-match", help="match a target to bar options")
    match.add_argument("--target", required=True)
    match.add_argument("options", nargs="*")
    commands.add_parser("agy-collect", help="reconstruct one usage page from stdin")
    render = commands.add_parser("agy-render", help="render collected usage text")
    render.add_argument("--field", choices=("text", "raw", "error"), required=True)
    polls = commands.add_parser("usage-polls", help="calculate usage polling iterations")
    polls.add_argument("--wait", required=True)
    polls.add_argument("--poll", required=True)
    commands.add_parser("codex-log", help="read limits from codex session rollouts")
    args = parser.parse_args(argv)
    if args.command == "codex-log":
        return run_codex_log()
    if args.command == "agy-collect":
        from herd_usage_view import collect_agy_input
        print(collect_agy_input(sys.stdin.read()))
        return 0
    if args.command == "agy-render":
        from herd_usage_view import AgyCollection
        print(AgyCollection.from_json(sys.stdin.read()).render(args.field), end="")
        return 0
    if args.command == "usage-polls":
        print(usage_poll_iterations(args.wait, args.poll))
        return 0
    if args.command == "dialog":
        plan = parse_dialog(sys.stdin.read(), args.target)
        for line in plan.diagnostics:
            print(line, file=sys.stderr)
        print(plan.output)
        return 0
    if args.command == "bar-marked":
        print(marked_bar_option(sys.stdin.read(), args.options))
        return 0
    if args.command == "bar-check":
        print(check_bar_dialog(sys.stdin.read(), args.options))
        return 0
    if args.command == "bar-match":
        print(match_bar_option(args.target, args.options))
        return 0
    result = parse_usage(sys.stdin.read(), args.kind)
    print(result.to_tsv(args.name, args.kind))
    return result.exit_code


if __name__ == "__main__":
    sys.exit(main())
