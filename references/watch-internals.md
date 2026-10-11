# watch: where the states come from

`watch` subscribes to the **events of the herdr daemon**
(`pane.agent_status_changed` plus `pane.closed`/`pane.exited`) instead of
polling every 2 seconds; the pane content is now only read as a cross-check
(dialog/limit/login after an idle event, stall fingerprint on `working`).

The cross-check also knows a **"not yet"**: agy (Gemini), grok and claude report
`idle`/`done` while they are still generating or waiting on a background task of
their own (agy: spinner, `esc to cancel`, line `● [HH:MM:SS] … running`; grok:
`N command still running`, with a blinking marker before it; claude: footer
`· N shells, M monitors ·` or turn end `… N monitors still running`). If the
pane of such a backend shows that, the quiet window is reset instead of
reporting `idle` — until the pane is clean or, after 15 minutes, the busy cap
reports `unknown`.

For claude, the case "turn finished, only background tasks left" (no running
status line `Verb… (…)`) is separate: after 3 minutes
(`HERD_EVENTS_BG_MAX_SEC`) a one-time `<name> background` appears. Read the
pane: if the completion marker is there and the shell has merely been left
lying around (old test or build run), have the agent terminate the background
shells via `send`, after which `idle` follows. If it is waiting for real work
(long test run, monitor), keep watching — `watch` reports `working` or `idle`
as soon as something happens. Briefs to claude implementers should therefore
include the sentence "do not leave background shells open before finishing".
The patterns apply only to the respective backend; nothing changes for all
others. Measured 2026-09-02: for agy, herdr switched several times between
`working` and `done` within one turn, with `done` phases of up to 50 s. The
external interface is unaffected — the same lines, the same exit codes.

`events.subscribe` was a preview in herdr 0.7.5 and is **stable** since 0.8.2
(protocol 20, verified 2026-09-02). Since 2026-09-02, **`wait`** also runs on
the event engine (one agent, exactly one event, output only the state;
`--status X` is a heuristic-free raw mode of the state machine), and `status`
shares ONE classification with the event path (`classify_text`, exactly one
pane read). The old poll path was deleted on 2026-09-09 (stage 4);
`HERD_WATCH_ENGINE` applies to `watch` and `wait` alike:

| Value | Behavior |
|---|---|
| `auto` (default) | event path (identical to `events`) |
| `events` | event path. If the event API is missing, `watch`/`wait` end with **exit 2** |
| `poll` | removed (stage 4) — exit 2, hint pointing to `auto\|events` |

The check runs anew on **every** `wait` and `watch` call (the daemon may
restart in between) and costs two short RPCs. Without a reachable event API
(herdr ≥ 0.8.2 and python3 are required), `wait`/`watch` end hard with exit 2.
