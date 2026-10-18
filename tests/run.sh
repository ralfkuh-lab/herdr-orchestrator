#!/usr/bin/env bash
# Test runner for scripts/herd.sh -- uses the fake herdr from tests/bin,
# needs neither a running daemon nor real panes nor backend quota.
#
# Layout:
#   tests/lib.sh               -- helpers, stubs, runner, fixtures, summary
#   tests/t-status-send.sh     -- status, send
#   tests/t-start.sh           -- start / build_cli, pi, permission precedence
#   tests/t-events.sh          -- event path, resync, reporting rules, adapter, dispatcher, shutdown path
#   tests/t-space-answer.sh    -- space isolation, answer, dialog prefilter, opencode
#   tests/t-wait.sh            -- wait event path, fix round stage 3, stage 4 event counterparts
#   tests/t-usage.sh           -- usage
#   tests/t-stop-list.sh       -- stop, list sessions
#   tests/t-muse.sh            -- muse start, muse states
#   tests/t-start-early-exit.sh -- start early exit (T156)
#   tests/t-security.sh        -- security hardening (TSEC1-16)
#
# Where new tests belong:
#   New block at the end of the matching t-*.sh; a new file only for a new
#   topic, then enter it here in run.sh in a fixed order.
#
# Call:
#   tests/run.sh                  # all tests
#   tests/run.sh --phase before   # characterization only (must be green before the rebuild)
#   tests/run.sh T3 T6            # individual tests

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

parse_args "$@"

# Source the test files in thematic order.
# The order follows the main blocks of herd.sh (lifecycle: status/send ->
# start -> events -> space/answer -> wait -> usage -> stop/list -> muse -> early-exit).
source "$DIR/t-status-send.sh"
source "$DIR/t-start.sh"
source "$DIR/t-events.sh"
source "$DIR/t-space-answer.sh"
source "$DIR/t-wait.sh"
source "$DIR/t-usage.sh"
source "$DIR/t-stop-list.sh"
source "$DIR/t-muse.sh"
source "$DIR/t-start-early-exit.sh"
source "$DIR/t-security.sh"

print_summary
