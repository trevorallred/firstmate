#!/usr/bin/env bash
# fm-model-switch.sh - switch which harness (and optionally effort) new crew
# dispatch and new no-mistakes validation runs use, in one captain-invoked
# command.
#
# Usage:
#   fm-model-switch.sh <harness> [effort]
#   fm-model-switch.sh --help
#
# <harness> must be one of the verified adapters listed in AGENTS.md /
# harness-adapters: claude, codex, opencode, pi, pi-signed, grok, kimi, cursor.
# [effort] is optional and must be one of low, medium, high, xhigh, max.
#
# This is a captain-invoked convenience script, not a background/automatic
# routing system: it adds no polling, quota-checking, or automatic routing
# logic of its own. AGENTS.md section 4's dispatch-profile precedence and
# effort-fallback rules are unchanged; this script only changes the concrete
# values those rules read.
#
# It updates two files together so the captain never has to hand-edit both:
#
#   1. config/crew-dispatch.json (docs/configuration.md "Crew dispatch
#      profiles" owns the schema). This script sets every "harness" value in
#      the file - the top-level default's and every rule's "use" - to the
#      given harness, in a single pass, so effort tiering by task shape stays
#      intact rather than collapsing to one rule. The flat top-level default's
#      effort is set to [effort] when given; every rule's own effort is left
#      exactly as authored, regardless of [effort]. Every other byte of the
#      file - rule "when"/"why" text, model fields, key order, whitespace - is
#      left untouched: this script edits the raw text of only the "harness"
#      and (top-level default only) "effort" field values, it never
#      re-serializes the JSON, so hand-authored formatting survives exactly.
#      A missing file is a refusal, not a script that offers to create one:
#      docs/examples/crew-dispatch.json is the starting point for a captain
#      who wants one.
#
#   2. The no-mistakes global config's "agent:" field (default
#      ~/.no-mistakes/config.yaml, see that file's own header comment for the
#      full schema) - the model the no-mistakes validation pipeline itself
#      uses for review/test/fix/etc. steps on EVERY project on this machine.
#      Only that one line changes; every other line and comment in the file,
#      including its surrounding blank lines, is preserved exactly.
#      no-mistakes does not support every verified firstmate harness as an
#      "agent:" value (see that file's own "# Options:" comment, which this
#      script reads rather than hardcoding, so a future no-mistakes release
#      that adds an option needs no change here). A harness no-mistakes does
#      not support is a refusal, not a downgrade to some other value.
#
# Config changes here take effect for new invocations only. This script never
# restarts the no-mistakes daemon (AGENTS.md section 1 rule 7: it is one
# instance serving every lane) and never touches an in-flight no-mistakes run
# or crew dispatch decision already under way.
#
# Read-only/no-op safe: if a target file already holds the requested value(s),
# that file is left byte-for-byte untouched and reported unchanged.
#
# Env overrides (for tests; never needed in normal operation):
#   FM_CONFIG_OVERRIDE            overrides the resolved config/ directory
#                                 (same override fm-harness.sh honors), so
#                                 FM_DISPATCH_FILE_OVERRIDE is only needed to
#                                 point at a file outside that directory.
#   FM_DISPATCH_FILE_OVERRIDE     overrides the crew-dispatch.json path
#                                 outright (default: $CONFIG/crew-dispatch.json)
#   FM_NOMISTAKES_CONFIG_OVERRIDE overrides the no-mistakes config.yaml path
#                                 (default: $HOME/.no-mistakes/config.yaml)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

DISPATCH_FILE="${FM_DISPATCH_FILE_OVERRIDE:-$CONFIG/crew-dispatch.json}"
NOMISTAKES_CONFIG="${FM_NOMISTAKES_CONFIG_OVERRIDE:-$HOME/.no-mistakes/config.yaml}"

VERIFIED_HARNESSES="claude codex opencode pi pi-signed grok kimi cursor"
VALID_EFFORTS="low medium high xhigh max"

usage() {
  cat <<'EOF'
Usage: fm-model-switch.sh <harness> [effort]

Switch which harness config/crew-dispatch.json picks for new crew tasks and
which model ~/.no-mistakes/config.yaml's agent: field uses for new validation
runs, together, in one command.

  <harness>  claude | codex | opencode | pi | pi-signed | grok | kimi | cursor
  [effort]   low | medium | high | xhigh | max (optional; sets the flat
             crew-dispatch default effort only, leaving every rule's own
             effort exactly as authored)
EOF
}

refuse() {
  echo "refuse: $1" >&2
  exit 1
}

case "${1:-}" in
  -h|--help|"") usage; [ "${1:-}" = "" ] && exit 2 || exit 0 ;;
esac

harness=$1
effort=${2:-}

case " $VERIFIED_HARNESSES " in
  *" $harness "*) ;;
  *) refuse "'$harness' is not a verified firstmate harness (one of: $VERIFIED_HARNESSES)" ;;
esac

if [ -n "$effort" ]; then
  case " $VALID_EFFORTS " in
    *" $effort "*) ;;
    *) refuse "'$effort' is not a valid effort (one of: $VALID_EFFORTS)" ;;
  esac
fi

[ -f "$DISPATCH_FILE" ] || refuse "crew dispatch file not found: $DISPATCH_FILE"
[ -f "$NOMISTAKES_CONFIG" ] || refuse "no-mistakes config not found: $NOMISTAKES_CONFIG"

command -v python3 >/dev/null 2>&1 || refuse "python3 is required to edit $DISPATCH_FILE without reformatting it"

# Resolve the no-mistakes agent: value for this harness from that file's own
# documented "# Options:" comment line, rather than hardcoding the mapping, so
# a future no-mistakes release that adds/drops a supported agent needs no
# change here.
options_line=$(grep -m1 '^# Options:' "$NOMISTAKES_CONFIG" || true)
[ -n "$options_line" ] || refuse "could not find a '# Options:' line documenting supported agent values in $NOMISTAKES_CONFIG"
options_csv=${options_line#*Options:}
agent_supported=0
IFS=',' read -ra nm_options <<< "$options_csv"
for opt in "${nm_options[@]}"; do
  opt=$(printf '%s' "$opt" | tr -d '[:space:]')
  if [ "$opt" = "$harness" ]; then
    agent_supported=1
    break
  fi
done
[ "$agent_supported" -eq 1 ] || refuse "no-mistakes has no 'agent:' value for harness '$harness' (documented options:$options_csv)"

dispatch_tmp=""
nomistakes_tmp=""
cleanup_staged() {
  [ -n "$dispatch_tmp" ] && rm -f "$dispatch_tmp" 2>/dev/null || true
  [ -n "$nomistakes_tmp" ] && rm -f "$nomistakes_tmp" 2>/dev/null || true
}

# --- config/crew-dispatch.json -----------------------------------------------
#
# Edited as raw text (never re-serialized) so hand-authored formatting,
# comments-adjacent JSON key order, and every rule's "when"/"why" prose survive
# byte-for-byte. See this script's header for exactly what changes.
#
# Both files below are staged first (computed and, if changed, written to a
# sibling temp file via mktemp - never a direct `open(path, "w")` overwrite)
# and only renamed into place once every validation and staging step for both
# files has already succeeded. This keeps a crash/kill/disk-full mid-write from
# truncating either file, and keeps the two config files from ever landing on
# a rename-only inconsistency window instead of the much wider one a full
# read-validate-write per file would leave.
new_dispatch=$(FM_MODEL_SWITCH_HARNESS="$harness" FM_MODEL_SWITCH_EFFORT="$effort" python3 - "$DISPATCH_FILE" <<'PY'
import json
import os
import re
import sys
import tempfile

path = sys.argv[1]
harness = os.environ["FM_MODEL_SWITCH_HARNESS"]
effort = os.environ.get("FM_MODEL_SWITCH_EFFORT") or None

with open(path, "r", encoding="utf-8") as f:
    raw = f.read()

try:
    data = json.loads(raw)
except Exception as exc:  # noqa: BLE001 - reported to the caller, not swallowed
    sys.stderr.write(f"ERROR: {path} is not valid JSON: {exc}\n")
    sys.exit(1)


def bracket_span(text, start):
    depth = 0
    in_str = False
    esc = False
    i = start
    n = len(text)
    while i < n:
        c = text[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c in "{[":
                depth += 1
            elif c in "}]":
                depth -= 1
                if depth == 0:
                    return i + 1
        i += 1
    raise ValueError("unbalanced brackets in " + path)


out = raw

if effort is not None and isinstance(data, dict) and "default" in data:
    m = re.search(r'"default"\s*:\s*', raw)
    if m:
        val_start = m.end()
        while raw[val_start].isspace():
            val_start += 1
        val_end = bracket_span(raw, val_start)
        segment = raw[val_start:val_end]

        def set_effort(obj_match):
            obj = obj_match.group(0)
            if re.search(r'"effort"\s*:', obj):
                return re.sub(
                    r'("effort"\s*:\s*")[^"]*(")',
                    lambda mm: mm.group(1) + effort + mm.group(2),
                    obj,
                    count=1,
                )
            return re.sub(
                r'("harness"\s*:\s*"[^"]*")',
                lambda mm: mm.group(1) + f', "effort": "{effort}"',
                obj,
                count=1,
            )

        new_segment = re.sub(r"\{[^{}]*\}", set_effort, segment)
        out = out[:val_start] + new_segment + out[val_end:]

# Every "harness" field in the file - the top-level default's and every rule's
# "use" - names the crew dispatch target, so one global value substitution
# covers both without needing to walk object/array shapes separately.
out = re.sub(
    r'("harness"\s*:\s*")[^"]*(")',
    lambda mm: mm.group(1) + harness + mm.group(2),
    out,
)

# Fail closed rather than write a result that no longer parses.
json.loads(out)

# Staged here (rather than printed for the caller to redirect) so a trailing
# newline - or its deliberate absence - survives exactly: command substitution
# in the calling shell strips trailing newlines, which a round trip through it
# would silently lose. Written to a sibling temp file, not the target path
# directly; the caller only renames it into place once both files are staged.
if out == raw:
    print("UNCHANGED")
else:
    dest_dir = os.path.dirname(os.path.abspath(path)) or "."
    orig_mode = os.stat(path).st_mode
    fd, tmp_path = tempfile.mkstemp(prefix=".fm-model-switch.dispatch.", dir=dest_dir)
    try:
        os.chmod(tmp_path, orig_mode)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(out)
            f.flush()
            os.fsync(f.fileno())
    except BaseException:
        os.unlink(tmp_path)
        raise
    print(f"CHANGED {tmp_path}")
PY
)
dispatch_result=$?
[ "$dispatch_result" -eq 0 ] || { cleanup_staged; exit 1; }
case "$new_dispatch" in
  "CHANGED "*) dispatch_changed=1; dispatch_tmp=${new_dispatch#CHANGED } ;;
  *) dispatch_changed=0; dispatch_tmp="" ;;
esac

# --- ~/.no-mistakes/config.yaml agent: field ---------------------------------
#
# Only the single active "agent:" line changes; every comment, blank line, and
# every other setting - including a missing/present trailing newline - is
# preserved exactly. The active line is anchored at column 0 so commented
# example lines ("# ... agent: [codex, claude]") are never touched. Staged to
# a sibling temp file by the python process for the same trailing-newline-
# precision reason given above; the caller renames it into place below.
new_nm_result=$(FM_MODEL_SWITCH_HARNESS="$harness" python3 - "$NOMISTAKES_CONFIG" <<'PY'
import os
import re
import sys
import tempfile

path = sys.argv[1]
harness = os.environ["FM_MODEL_SWITCH_HARNESS"]

with open(path, "r", encoding="utf-8") as f:
    raw = f.read()

out, n = re.subn(r"^agent:.*$", f"agent: {harness}", raw, count=1, flags=re.MULTILINE)
if n != 1:
    sys.stderr.write(f"ERROR: could not find an active 'agent:' line in {path}\n")
    sys.exit(1)

if out == raw:
    print("UNCHANGED")
else:
    dest_dir = os.path.dirname(os.path.abspath(path)) or "."
    orig_mode = os.stat(path).st_mode
    fd, tmp_path = tempfile.mkstemp(prefix=".fm-model-switch.nomistakes.", dir=dest_dir)
    try:
        os.chmod(tmp_path, orig_mode)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(out)
            f.flush()
            os.fsync(f.fileno())
    except BaseException:
        os.unlink(tmp_path)
        raise
    print(f"CHANGED {tmp_path}")
PY
)
nomistakes_result=$?
[ "$nomistakes_result" -eq 0 ] || { cleanup_staged; exit 1; }
case "$new_nm_result" in
  "CHANGED "*) nomistakes_changed=1; nomistakes_tmp=${new_nm_result#CHANGED } ;;
  *) nomistakes_changed=0; nomistakes_tmp="" ;;
esac

# Both files are validated and staged; commit them together now so the window
# in which one target could be switched while the other still holds its old
# value is just these two renames, not the full read-validate-write above.
if [ "$dispatch_changed" -eq 1 ]; then
  if ! mv -f "$dispatch_tmp" "$DISPATCH_FILE" 2>/dev/null; then
    cleanup_staged
    refuse "could not write $DISPATCH_FILE"
  fi
fi

if [ "$nomistakes_changed" -eq 1 ]; then
  if ! mv -f "$nomistakes_tmp" "$NOMISTAKES_CONFIG" 2>/dev/null; then
    rm -f "$nomistakes_tmp" 2>/dev/null || true
    refuse "could not write $NOMISTAKES_CONFIG (crew dispatch was already switched to '$harness')"
  fi
fi

echo "crew dispatch: $DISPATCH_FILE"
if [ "$dispatch_changed" -eq 1 ]; then
  echo "  default/rule harness -> $harness"
  [ -n "$effort" ] && echo "  default effort -> $effort"
else
  echo "  unchanged (already $harness${effort:+, effort $effort})"
fi

echo "no-mistakes: $NOMISTAKES_CONFIG"
if [ "$nomistakes_changed" -eq 1 ]; then
  echo "  agent -> $harness"
else
  echo "  unchanged (already agent: $harness)"
fi

echo "New crew dispatch and no-mistakes validation runs will use this from their next invocation; no in-flight run or daemon was touched."
