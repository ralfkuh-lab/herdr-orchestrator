source "$COLLECTOR"
SCRIPT_DIR="$REPO/scripts"
sleep() { :; }
herdr() {
  printf '%s\n' "$*" >> "$CASE_DIR/keys"
  if [ -f "$CASE_DIR/fail" ]; then echo 'injected down failure'; return 1; fi
}
usage_read_pane() {
  local n=$(cat "$CASE_DIR/count")
  n=$((n+1)); echo "$n" > "$CASE_DIR/count"
  if [ -f "$CASE_DIR/$n" ]; then cat "$CASE_DIR/$n"; else cat "$CASE_DIR/last"; fi
}
USAGE_LAST_RAW_BUF=''
USAGE_LAST_PARSE_RC=0
buf=$(cat "$CASE_DIR/initial")
usage_agy_collect pane "$buf" 0
rc=$?
printf '%s\0%s\0%s\0%s' "$buf" "$USAGE_LAST_RAW_BUF" "$USAGE_LAST_PARSE_RC" "$rc"
