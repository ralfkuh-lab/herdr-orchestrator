# Dialogs: answer in detail

- If `answer` reports a follow-up dialog still open, only the previous request
  was confirmed. Read the new request again and assess it individually, even
  with the same options. For known Claude tool dialogs with a visible request,
  `answer` additionally compares the dialog identity; if it is missing or stays
  the same, a dialog that is still open is cautiously reported as an error.
  The text match is normalized (typographic apostrophes/quotation marks, NBSP,
  case) and prefers exact over prefix over substring matches — so
  `answer x "Yes"` matches `Yes` even if `Yes, and don't ask again …` stands
  next to it. grok dialogs (`1 (●) Text`) are selected with the digit key, which
  also confirms there; arrow keys+Enter apply to the other formats. For opencode
  permission dialogs with a horizontal option bar (e.g. `Allow once`,
  `Allow always`, `Reject`) whose highlight is only visible in ANSI format,
  `answer` navigates with `right`/`left` (shortest path with wrap-around),
  verifies the highlight in the ANSI read and confirms with `enter`.
  Otherwise, options count only as a contiguous run `1, 2, …` (at least two) —
  single lines that coincidentally look like an option result in
  "no selection dialog".
  `key <name> enter|esc` stays for single keys; **never blindly
  `key down`+`enter`** — the preselected option varies (incident 2026-07-14:
  blindly confirmed = "No, reject", 22 min of work aborted).

- **The permission mode is NOT remotely controllable after the fact**:
  `key <name> shift+tab` (claude's local mode cycler) has no effect over ConPTY
  at idle — and with an OPEN dialog it changes the selection instead ("Yes"
  becomes "Yes, and …"); a blind `key enter` afterwards picks the wrong option
  (verified 2026-07-27). So: always set the mode at `start`, never readjust it
  with a keypress.
