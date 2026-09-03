#!/usr/bin/env bash
# tests/fm-model-switch.test.sh - behavior tests for bin/fm-model-switch.sh.
#
# Every case runs against a temporary copy of a realistic config/crew-dispatch.json
# and a temporary copy of a realistic ~/.no-mistakes/config.yaml, pointed at
# through FM_DISPATCH_FILE_OVERRIDE and FM_NOMISTAKES_CONFIG_OVERRIDE so the
# real machine-wide no-mistakes install and this repo's own local config are
# never touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-model-switch.sh"
TMP_ROOT=$(fm_test_tmproot fm-model-switch)

# A realistic instance of the no-mistakes global config: extensive header
# comments, several unrelated settings, an active "agent:" line, and a
# trailing newline - the shape the real ~/.no-mistakes/config.yaml has.
write_nomistakes_config() {
  local path=$1 agent=$2
  cat > "$path" <<EOF
# no-mistakes global configuration

# Agent to use for code generation. This may also be an ordered fallback list,
# for example: agent: [codex, claude]
# Options: auto, claude, codex, rovodev, opencode, pi, copilot, cursor, acp:<target>
# "auto" detects the first available native agent or ACP alias on your system
# "cursor" is an ACP alias for acp:cursor using cursor-agent acp via acpx
agent: $agent

# Maximum time the CI monitor babysits an open PR with no base-branch movement
# before giving up.
ci_timeout: "168h"

# Reuse one durable fixer session per run across review-fix turns.
reuse_session: true
EOF
}

new_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/config"
  cp "$ROOT/docs/examples/crew-dispatch.json" "$dir/config/crew-dispatch.json"
  write_nomistakes_config "$dir/nomistakes-config.yaml" claude
  printf '%s\n' "$dir"
}

run_switch() {
  local dir=$1
  shift
  FM_DISPATCH_FILE_OVERRIDE="$dir/config/crew-dispatch.json" \
    FM_NOMISTAKES_CONFIG_OVERRIDE="$dir/nomistakes-config.yaml" \
    "$SCRIPT" "$@"
}

# --- switching between two valid harnesses updates both files, preserving
#     unrelated content byte-for-byte -----------------------------------------

DIR=$(new_case switch-two-valid)
before_dispatch="$DIR/config/crew-dispatch.json.before"
before_nm="$DIR/nomistakes-config.yaml.before"
cp "$DIR/config/crew-dispatch.json" "$before_dispatch"
cp "$DIR/nomistakes-config.yaml" "$before_nm"

out=$(run_switch "$DIR" codex) || fail "switch to codex failed: $out"

# Every "harness" value in the dispatch file (default and every rule's use)
# must now read codex, and none of the original grok/claude/pi harness values
# may remain.
if grep -q '"harness": "grok"' "$DIR/config/crew-dispatch.json" \
  || grep -q '"harness": "claude"' "$DIR/config/crew-dispatch.json" \
  || grep -q '"harness": "pi"' "$DIR/config/crew-dispatch.json"; then
  fail "an old harness value survived the switch to codex"
fi
grep -c '"harness": "codex"' "$DIR/config/crew-dispatch.json" > /dev/null \
  || fail "no codex harness values found after switching to codex"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$DIR/config/crew-dispatch.json" \
  || fail "crew-dispatch.json is not valid JSON after switching"

# Effort was not passed, so every rule-specific effort (low/high) and the
# original default effort (medium) must survive unchanged.
assert_grep '"effort": "low"' "$DIR/config/crew-dispatch.json" "rule effort 'low' must survive an effort-less switch"
assert_grep '"effort": "high"' "$DIR/config/crew-dispatch.json" "rule effort 'high' must survive an effort-less switch"
assert_grep '"effort": "medium"' "$DIR/config/crew-dispatch.json" "default effort 'medium' must survive an effort-less switch"

# Every "when"/"why" line is untouched: diff after masking only harness values
# must show no other change.
sed -E 's/"harness": "[a-z-]+"/"harness": "X"/g' "$before_dispatch" > "$DIR/before.masked"
sed -E 's/"harness": "[a-z-]+"/"harness": "X"/g' "$DIR/config/crew-dispatch.json" > "$DIR/after.masked"
diff "$DIR/before.masked" "$DIR/after.masked" > /dev/null \
  || fail "crew-dispatch.json changed something other than harness values"
pass "switching harness updates every default/rule harness value and preserves all other dispatch content"

assert_grep 'agent: codex' "$DIR/nomistakes-config.yaml" "no-mistakes agent: line must read the new harness"
sed -E 's/^agent: .*$/agent: X/' "$before_nm" > "$DIR/nm-before.masked"
sed -E 's/^agent: .*$/agent: X/' "$DIR/nomistakes-config.yaml" > "$DIR/nm-after.masked"
diff "$DIR/nm-before.masked" "$DIR/nm-after.masked" > /dev/null \
  || fail "no-mistakes config.yaml changed something other than the agent: line"
pass "switching harness updates only the no-mistakes agent: line and preserves every comment and other setting"

# Switch again to a second valid harness (pi) to confirm the round trip is not
# a one-shot fluke and both files converge on the newly requested harness.
out=$(run_switch "$DIR" pi) || fail "switch to pi failed: $out"
grep -q '"harness": "codex"' "$DIR/config/crew-dispatch.json" \
  && fail "codex harness value survived a subsequent switch to pi"
assert_grep 'agent: pi' "$DIR/nomistakes-config.yaml" "no-mistakes agent: line must follow a second switch to pi"
pass "switching between two valid harnesses converges both files on the newly requested harness each time"

# --- an invalid harness name is refused without modifying either file -------

DIR=$(new_case invalid-harness)
cp "$DIR/config/crew-dispatch.json" "$DIR/config/crew-dispatch.json.before"
cp "$DIR/nomistakes-config.yaml" "$DIR/nomistakes-config.yaml.before"

run_switch "$DIR" not-a-real-harness > "$DIR/out.log" 2> "$DIR/err.log"
rc=$?
expect_code 1 "$rc" "an unverified harness name must be refused with a non-zero exit"
assert_grep "refuse" "$DIR/err.log" "refusal must be reported"
diff "$DIR/config/crew-dispatch.json.before" "$DIR/config/crew-dispatch.json" > /dev/null \
  || fail "an invalid harness must not modify crew-dispatch.json"
diff "$DIR/nomistakes-config.yaml.before" "$DIR/nomistakes-config.yaml" > /dev/null \
  || fail "an invalid harness must not modify no-mistakes config.yaml"
pass "an invalid harness name is refused and leaves both files byte-for-byte unmodified"

# A verified firstmate harness that no-mistakes itself has no agent: value for
# (grok is not in that file's documented Options: list) must also be refused,
# not silently written as an unsupported value.
DIR=$(new_case unsupported-by-nomistakes)
cp "$DIR/config/crew-dispatch.json" "$DIR/config/crew-dispatch.json.before"
cp "$DIR/nomistakes-config.yaml" "$DIR/nomistakes-config.yaml.before"

run_switch "$DIR" grok > "$DIR/out.log" 2> "$DIR/err.log"
rc=$?
expect_code 1 "$rc" "a verified harness unsupported by no-mistakes must be refused"
assert_grep "refuse" "$DIR/err.log" "refusal must be reported"
assert_grep "grok" "$DIR/err.log" "refusal must name the unsupported harness"
diff "$DIR/config/crew-dispatch.json.before" "$DIR/config/crew-dispatch.json" > /dev/null \
  || fail "an unsupported-by-no-mistakes harness must not modify crew-dispatch.json"
diff "$DIR/nomistakes-config.yaml.before" "$DIR/nomistakes-config.yaml" > /dev/null \
  || fail "an unsupported-by-no-mistakes harness must not modify no-mistakes config.yaml"
pass "a verified harness with no matching no-mistakes agent: option is refused and leaves both files unmodified"

# --- running with the same harness twice is a safe no-op the second time ----

DIR=$(new_case idempotent-rerun)
run_switch "$DIR" opencode > /dev/null || fail "first switch to opencode failed"
cp "$DIR/config/crew-dispatch.json" "$DIR/config/crew-dispatch.json.after-first"
cp "$DIR/nomistakes-config.yaml" "$DIR/nomistakes-config.yaml.after-first"

out=$(run_switch "$DIR" opencode) || fail "second identical switch failed: $out"
assert_contains "$out" "unchanged" "a repeated identical switch must report no changes"
diff "$DIR/config/crew-dispatch.json.after-first" "$DIR/config/crew-dispatch.json" > /dev/null \
  || fail "a repeated identical switch must not change crew-dispatch.json"
diff "$DIR/nomistakes-config.yaml.after-first" "$DIR/nomistakes-config.yaml" > /dev/null \
  || fail "a repeated identical switch must not change no-mistakes config.yaml"
pass "running with the same harness twice is a byte-for-byte no-op the second time"

# --- the optional effort argument updates only the flat default effort -----

DIR=$(new_case effort-arg-flat-default-only)
run_switch "$DIR" claude xhigh > /dev/null || fail "switch with effort argument failed"

# Rule-specific efforts (low, high) must be exactly as authored: unaffected by
# the requested flat default effort.
assert_grep '"effort": "low"' "$DIR/config/crew-dispatch.json" "a rule's own effort must survive an effort argument unchanged"
assert_grep '"effort": "high"' "$DIR/config/crew-dispatch.json" "a rule's own effort must survive an effort argument unchanged"

# The top-level default's effort(s) must now read the requested effort, and
# the original default effort (medium) must be gone from the default block.
if ! python3 - "$DIR/config/crew-dispatch.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

default = data["default"]
entries = default if isinstance(default, list) else [default]
for entry in entries:
    assert entry.get("effort") == "xhigh", f"expected default effort xhigh, got {entry!r}"
    assert entry.get("harness") == "claude", f"expected default harness claude, got {entry!r}"

for rule in data["rules"]:
    use = rule["use"]
    use_entries = use if isinstance(use, list) else [use]
    for entry in use_entries:
        assert entry.get("harness") == "claude", f"expected rule harness claude, got {entry!r}"
PY
then
  fail "the effort argument must set only the flat default effort, leaving rule harness/effort otherwise as specified"
fi
pass "the optional effort argument updates only the flat crew-dispatch default effort, never a rule-specific effort"

echo "# fm-model-switch.test.sh: all assertions passed"
