#!/usr/bin/env bash
# Waits for an agy interval in which herdr reports done/idle while the visible
# pane is still streaming (esc to cancel / Braille spinner in the last 10
# lines), and captures EXACTLY THEN the recordings the maintainer asked for.
set -u
name="${1:?agent name}"
out="${2:?output dir}"
mkdir -p "$out"
deadline=$(( $(date +%s) + 900 ))
n=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  st="$(herdr agent get "$name" 2>/dev/null | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["result"]["agent"]["agent_status"])
except Exception: print("?")')"
  n=$((n+1))
  case "$st" in
    done|idle)
      vis="$(herdr pane read "$name" --source visible --lines 40 --format text 2>/dev/null | tail -n 10)"
      if printf '%s\n' "$vis" | grep -qiE 'esc to cancel' \
         || printf '%s\n' "$vis" | LC_ALL=C grep -qE $'\xe2(\xa0[\x81-\xbf]|[\xa1-\xa3][\x80-\xbf])'; then
        ts="$(date +%H:%M:%S)"
        echo "TREFFER $ts status=$st (Poll $n) — Mitschnitt laeuft"
        herdr agent read "$name" --source detection --format text > "$out/agy-false-done.txt" 2>"$out/err-text.log"
        herdr agent read "$name" --source detection --format ansi > "$out/agy-false-done.ansi" 2>"$out/err-ansi.log"
        herdr agent explain "$name" --json > "$out/agy-false-done-explain.json" 2>"$out/err-explain.log"
        herdr agent get "$name" > "$out/agent-get-at-capture.json" 2>/dev/null
        printf '%s\n' "$vis" > "$out/visible-tail10-at-capture.txt"
        echo "$ts status=$st" > "$out/capture-time.txt"
        ls -la "$out"
        exit 0
      fi
      ;;
  esac
  sleep 2
done
echo "KEIN TREFFER binnen 15 min (letzter Status: $st, Polls: $n)"
exit 1
