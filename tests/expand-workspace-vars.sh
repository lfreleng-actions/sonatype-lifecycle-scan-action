#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Checks the workspace-variable expansion the action applies to
# advanced_properties and scan_targets. The list of names it expands is
# a security boundary: the calling step's environment can hold
# credentials, so a change that widened the list or swapped it for a
# blanket expansion would place one in a CLI argument. The function is
# sourced from the file the action itself sources, and the step body is
# extracted from action.yaml, so this checks what the action runs.
#
# Single quotes throughout the cases below: the point is to hand the
# function the literal text a caller writes, and let it do the
# expanding. SC2016 reads that as a mistake. SC1091 objects to the
# sourced path not being followed; the file sits beside this script.
# shellcheck disable=SC2016,SC1091

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="${SCRIPT_DIR}/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=../expand-workspace-vars.sh
. "${ACTION_DIR}/expand-workspace-vars.sh"

export GITHUB_WORKSPACE=/home/runner/work/p/p
export GITHUB_REPOSITORY=org/proj
export GITHUB_REF_NAME=main
export GITHUB_SHA=deadbeef
export GITHUB_RUN_ID=42
export RUNNER_TEMP=/tmp/rt
export RUNNER_OS=Linux
# Stand-ins for the credentials the calling step can hold.
export GITHUB_TOKEN=token-must-not-appear
export NEXUS_IQ_PASSWORD=token-must-not-appear
export GITHUB_REPOSITORY_OWNER=org

passed=0
failed=0

check() {
  local input="$1" want="$2" got
  got="$(expand_workspace_vars "$input")"
  if [ "$got" = "$want" ]; then
    passed=$((passed + 1))
    echo "ok   ${input}"
  else
    failed=$((failed + 1))
    echo "FAIL ${input}"
    echo "       want: ${want}"
    echo "       got : ${got}"
  fi
}


echo '--- the allowed names expand'
check 'dirExcludes=${GITHUB_WORKSPACE}/generated' \
  'dirExcludes=/home/runner/work/p/p/generated'
check '$GITHUB_WORKSPACE/go.sum' '/home/runner/work/p/p/go.sum'
check '${RUNNER_TEMP}/x ${RUNNER_OS}' '/tmp/rt/x Linux'

echo '--- credentials stay literal'
check 'p=${NEXUS_IQ_PASSWORD}' 'p=${NEXUS_IQ_PASSWORD}'
check 'p=$GITHUB_TOKEN' 'p=$GITHUB_TOKEN'

echo '--- a name sharing a prefix with an allowed one stays literal'
check 'o=${GITHUB_REPOSITORY_OWNER}' 'o=${GITHUB_REPOSITORY_OWNER}'

echo '--- nothing runs'
check 'x=$(id -u)' 'x=$(id -u)'
check 'x=`id -u`' 'x=`id -u`'
check 'x=$((1+1))' 'x=$((1+1))'

echo '--- multiline properties expand per line'
check "$(printf 'a=1\nb=${GITHUB_WORKSPACE}/f')" \
  "$(printf 'a=1\nb=/home/runner/work/p/p/f')"

# --- the step body wires the expansion into its outputs ---
# Pull the 'Expand workspace variables' step's run block out of the
# action: from the "run: |" that follows "id: expand" until the
# indentation drops back below the block's eight spaces.
awk '
  /^      id: expand$/ { in_step = 1 }
  in_step && /^      run: \|$/ { in_run = 1; next }
  in_run {
    if ($0 ~ /^        / || $0 == "") { print; next }
    exit
  }
' "${ACTION_DIR}/action.yaml" | sed 's/^        //' > "$WORK/step.sh"

if ! grep -q 'expand-workspace-vars.sh' "$WORK/step.sh"; then
  echo 'Extraction failed: step body does not source the helper' >&2
  exit 1
fi

export GITHUB_ACTION_PATH="$ACTION_DIR"
export GITHUB_OUTPUT="$WORK/gh-output"
: > "$GITHUB_OUTPUT"
ADVANCED_PROPERTIES="$(printf 'a=1\nb=${GITHUB_WORKSPACE}/f')" \
  SCAN_TARGETS='${GITHUB_WORKSPACE}/go.sum' \
  bash "$WORK/step.sh" > /dev/null

step_output_value() {
  # Prints the value of one multiline output from GITHUB_OUTPUT.
  awk -v key="$1" '
    $0 ~ "^" key "<<" { delim = substr($0, length(key) + 3); on = 1; next }
    on && $0 == delim { on = 0; next }
    on { print }
  ' "$GITHUB_OUTPUT"
}

got="$(step_output_value advanced_properties)"
want="$(printf 'a=1\nb=/home/runner/work/p/p/f')"
if [ "$got" = "$want" ]; then
  passed=$((passed + 1))
  echo 'ok   the step emits expanded multiline advanced_properties'
else
  failed=$((failed + 1))
  echo 'FAIL the step emits expanded multiline advanced_properties'
  echo "       want: ${want}"
  echo "       got : ${got}"
fi

got="$(step_output_value scan_targets)"
if [ "$got" = '/home/runner/work/p/p/go.sum' ]; then
  passed=$((passed + 1))
  echo 'ok   the step emits expanded scan_targets'
else
  failed=$((failed + 1))
  echo 'FAIL the step emits expanded scan_targets'
  echo "       got : ${got}"
fi

# --- the whitespace warning fires only for a consumed reference ---
export GITHUB_WORKSPACE='/home/run ner/p'
: > "$GITHUB_OUTPUT"
ADVANCED_PROPERTIES='dirExcludes=${GITHUB_WORKSPACE}/x' SCAN_TARGETS='.' \
  bash "$WORK/step.sh" > "$WORK/warn-ref.out"
if grep -q '::warning::GITHUB_WORKSPACE holds whitespace' \
  "$WORK/warn-ref.out"; then
  passed=$((passed + 1))
  echo 'ok   a referenced name resolving to whitespace warns'
else
  failed=$((failed + 1))
  echo 'FAIL a referenced name resolving to whitespace warns'
fi

: > "$GITHUB_OUTPUT"
ADVANCED_PROPERTIES='label=GITHUB_WORKSPACE' SCAN_TARGETS='.' \
  bash "$WORK/step.sh" > "$WORK/warn-bare.out"
if grep -q '::warning::' "$WORK/warn-bare.out"; then
  failed=$((failed + 1))
  echo 'FAIL a bare name in literal text draws no warning'
else
  passed=$((passed + 1))
  echo 'ok   a bare name in literal text draws no warning'
fi

: > "$GITHUB_OUTPUT"
ADVANCED_PROPERTIES='p=${GITHUB_WORKSPACE_SUFFIX}' SCAN_TARGETS='.' \
  bash "$WORK/step.sh" > "$WORK/warn-prefix.out"
if grep -q '::warning::' "$WORK/warn-prefix.out"; then
  failed=$((failed + 1))
  echo 'FAIL a prefix-sharing reference draws no warning'
else
  passed=$((passed + 1))
  echo 'ok   a prefix-sharing reference draws no warning'
fi

# A reference ending one input must not run into the start of the
# other and read as a longer identifier: the inputs are independent
# values, so the boundary between them is real.
: > "$GITHUB_OUTPUT"
ADVANCED_PROPERTIES='d=$GITHUB_WORKSPACE' SCAN_TARGETS='_SUFFIX/x' \
  bash "$WORK/step.sh" > "$WORK/warn-join.out"
if grep -q '::warning::GITHUB_WORKSPACE holds whitespace' \
  "$WORK/warn-join.out"; then
  passed=$((passed + 1))
  echo 'ok   input boundaries do not merge references'
else
  failed=$((failed + 1))
  echo 'FAIL input boundaries do not merge references'
fi
export GITHUB_WORKSPACE=/home/runner/work/p/p

# An option-shaped value must arrive verbatim: echo would read '-n'
# as its own flag and emit an empty output instead of the value.
: > "$GITHUB_OUTPUT"
ADVANCED_PROPERTIES='-e' SCAN_TARGETS='-n' \
  bash "$WORK/step.sh" > /dev/null
got="$(step_output_value scan_targets)"
got2="$(step_output_value advanced_properties)"
if [ "$got" = '-n' ] && [ "$got2" = '-e' ]; then
  passed=$((passed + 1))
  echo 'ok   option-shaped values emit verbatim'
else
  failed=$((failed + 1))
  echo 'FAIL option-shaped values emit verbatim'
  echo "       scan_targets: '${got}'  advanced_properties: '${got2}'"
fi

echo
echo "passed: ${passed}  failed: ${failed}"
[ "$failed" -eq 0 ]
