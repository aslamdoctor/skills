# Shared bats helpers for the smith tests. Load with: load helper
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

setup() {
	RUN=$BATS_TEST_TMPDIR/run
	STUB_DIR=$BATS_TEST_TMPDIR/stub
	mkdir -p "$RUN" "$STUB_DIR"
	export RUN STUB_DIR
	export PATH="$REPO_ROOT/tests/smith/stubs:$PATH"
	export S="$REPO_ROOT/skills/smith/scripts"
}

# stub_reply <cmd> <key> <json> [exit]
# Per-call replies: write $STUB_DIR/<cmd>.<key>.<N>.json for the Nth call (the last file repeats). A <cmd>.<key>.sleep file holding N makes the call sleep N seconds.
stub_reply() {
	printf '%s\n' "$3" >"$STUB_DIR/$1.$2.json"
	if [ -n "${4:-}" ]; then printf '%s\n' "$4" >"$STUB_DIR/$1.$2.exit"; fi
}

# stub_calls <cmd>: the call log, one call per line
stub_calls() { cat "$STUB_DIR/$1.log" 2>/dev/null || true; }

# write_run <json>
write_run() { printf '%s\n' "$1" >"$RUN/run.json"; }
