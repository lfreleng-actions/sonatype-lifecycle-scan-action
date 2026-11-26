#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Checks the job summary the action writes after a scan. It runs the
# same write-scan-summary.sh the action runs, against result files of
# the shapes run-iq-cli leaves behind and against hostile text, and
# needs no Nexus IQ server. Run as 'bash tests/write-scan-summary.sh'.
#
# The script must never change the action's result, so every case also
# checks that it exits 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="${SCRIPT_DIR}/.."
RENDER="${ACTION_DIR}/write-scan-summary.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0

ok() {
  passed=$((passed + 1))
  echo "ok   $1"
}

fail() {
  failed=$((failed + 1))
  echo "FAIL $1"
}

# Runs the renderer for one case. $1 names the case; the result file
# for it, if any, is "$WORK/$1/result-file.json". Writes the summary to
# "$WORK/$1.md" and standard output to "$WORK/$1.out".
run_case() {
  local name="$1" mode="${2:-full}" download="${3:-success}" rc=0
  mkdir -p "$WORK/$name"
  : > "$WORK/$name.md"
  SUMMARY_MODE="$mode" \
    APPLICATION_ID="${APP:-org-project}" \
    CLI_EXIT_CATEGORY="${CATEGORY:-SUCCESS}" \
    CLI_EXIT_MESSAGE="${MESSAGE:-The scan completed}" \
    SCAN_ID="${SCAN-0123abcd}" \
    RESULT_DOWNLOAD="$download" \
    RESULT_DIR="$WORK/$name" \
    GITHUB_STEP_SUMMARY="$WORK/$name.md" \
    bash "$RENDER" > "$WORK/$name.out" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "$name: exits 0"
  else
    fail "$name: exits 0 (got $rc)"
  fi
}

expect_in() {
  local label="$1" file="$2" text="$3"
  if grep -qF -- "$text" "$file"; then
    ok "$label"
  else
    fail "$label"
    echo "       missing: ${text}"
  fi
}

expect_not_in() {
  local label="$1" file="$2" text="$3"
  if grep -qF -- "$text" "$file"; then
    fail "$label"
    echo "       present: ${text}"
  else
    ok "$label"
  fi
}

# Writes a result file with policy alerts. Each argument is
# 'threat:policy:artifact', becoming one alert on a Maven component.
write_alerts() {
  local file="$1" total="$2" spec
  shift 2
  for spec in "$@"; do
    printf '%s\n' "$spec"
  done | jq -R -s --argjson total "$total" '
    split("\n") | map(select(. != "") | split(":")) as $rows
    | {scanId: "0123abcd", exitCode: 0, category: "SUCCESS",
       policyEvaluationResult: {
         totalComponentCount: $total,
         alerts: [$rows[] | {trigger: {
           policyName: .[1],
           policyViolationId: "v",
           threatLevel: (.[0] | tonumber),
           componentFacts: [{componentIdentifier: {
             format: "maven",
             coordinates: {groupId: "org.example", artifactId: .[2],
               version: "1.0"}}}]}}]}}' > "$file"
}

echo '--- a clean result'
mkdir -p "$WORK/clean"
write_alerts "$WORK/clean/result-file.json" 42
run_case clean
expect_in 'clean: heading' "$WORK/clean.md" '## Sonatype Lifecycle scan'
expect_in 'clean: application row' "$WORK/clean.md" \
  '| Application ID | org-project |'
expect_in 'clean: result row' "$WORK/clean.md" '| Result | ✅ SUCCESS |'
expect_in 'clean: scan ID row' "$WORK/clean.md" '| Scan ID | 0123abcd |'
expect_in 'clean: component count' "$WORK/clean.md" 'Components scanned: 42'
expect_in 'clean: no alerts' "$WORK/clean.md" 'No policy alerts.'
expect_in 'clean: zero critical' "$WORK/clean.md" '| Critical | 8 to 10 | 0 |'
expect_not_in 'clean: no notice' "$WORK/clean.out" '::notice'

echo '--- more than 25 alerts'
mkdir -p "$WORK/many"
specs=()
for i in $(seq 1 30); do
  # Threat levels 1..10 three times over; one 10 leads the table.
  specs+=("$(( (i - 1) % 10 + 1 )):Policy-${i}:artifact-${i}")
done
write_alerts "$WORK/many/result-file.json" 500 "${specs[@]}"
CATEGORY=POLICY_VIOLATION MESSAGE='Policy violations found' run_case many
rows="$(grep -c '^| [0-9]* | Policy-' "$WORK/many.md" || true)"
if [ "$rows" -eq 25 ]; then
  ok 'many: the alert table stops at 25 rows'
else
  fail "many: the alert table stops at 25 rows (got ${rows})"
fi
expect_in 'many: says how many were left out' "$WORK/many.md" \
  '5 more policy alerts not shown'
expect_in 'many: failed result row' "$WORK/many.md" \
  '| Result | ❌ POLICY&#95;VIOLATION |'
expect_in 'many: critical band' "$WORK/many.md" '| Critical | 8 to 10 | 9 |'
expect_in 'many: severe band' "$WORK/many.md" '| Severe | 4 to 7 | 12 |'
expect_in 'many: moderate band' "$WORK/many.md" '| Moderate | 2 to 3 | 6 |'
expect_in 'many: low band' "$WORK/many.md" '| Low | 1 | 3 |'
expect_in 'many: total' "$WORK/many.md" '| All alerts | | 30 |'
first="$(grep -m1 '^| [0-9]* | Policy-' "$WORK/many.md")"
if [ "${first#| 10 |}" != "$first" ]; then
  ok 'many: highest threat first'
else
  fail 'many: highest threat first'
  echo "       got: ${first}"
fi
expect_not_in 'many: threat 1 left out' "$WORK/many.md" '| 1 | Policy-'

echo '--- the early-failure shape'
mkdir -p "$WORK/early"
printf '%s\n' '{"exitCode": 5, "category": "CONNECTIVITY_ERROR",' \
  '"message": "Could not reach the server"}' \
  > "$WORK/early/result-file.json"
CATEGORY=CONNECTIVITY_ERROR MESSAGE='Could not reach the server' SCAN='' \
  run_case early
expect_in 'early: outcome table' "$WORK/early.md" \
  '| Message | Could not reach the server |'
expect_in 'early: empty scan ID' "$WORK/early.md" '| Scan ID | n/a |'
expect_not_in 'early: no details' "$WORK/early.md" 'Components scanned'
expect_in 'early: notice' "$WORK/early.out" \
  '::notice title=Sonatype scan summary::Scan details unavailable'

echo '--- malformed JSON'
mkdir -p "$WORK/malformed"
printf '{"policyEvaluationResult": {' > "$WORK/malformed/result-file.json"
run_case malformed
expect_in 'malformed: outcome table' "$WORK/malformed.md" '| Result |'
expect_not_in 'malformed: no details' "$WORK/malformed.md" \
  'Components scanned'
expect_in 'malformed: notice' "$WORK/malformed.out" \
  'the result file is not a JSON object'

echo '--- a missing result file'
run_case missing
expect_in 'missing: outcome table' "$WORK/missing.md" '| Result |'
expect_in 'missing: notice' "$WORK/missing.out" \
  'no result file in the downloaded artifact'
run_case nodownload full failure
expect_in 'no download: outcome table' "$WORK/nodownload.md" '| Result |'
expect_in 'no download: notice' "$WORK/nodownload.out" \
  'the result artifact was not downloaded'

echo '--- several JSON values in one file'
mkdir -p "$WORK/multiple"
write_alerts "$WORK/multiple/one.json" 3 '9:Security:lib'
cat "$WORK/multiple/one.json" "$WORK/multiple/one.json" \
  > "$WORK/multiple/result-file.json"
rm "$WORK/multiple/one.json"
run_case multiple
expect_in 'multiple: outcome table' "$WORK/multiple.md" '| Result |'
expect_not_in 'multiple: no details' "$WORK/multiple.md" \
  'Components scanned'
expect_in 'multiple: notice' "$WORK/multiple.out" \
  'the result file is not a JSON object'

echo '--- an oversized result file'
mkdir -p "$WORK/oversized"
head -c $((32 * 1024 * 1024 + 1)) /dev/zero \
  > "$WORK/oversized/result-file.json"
run_case oversized
expect_in 'oversized: outcome table' "$WORK/oversized.md" '| Result |'
expect_in 'oversized: notice' "$WORK/oversized.out" 'larger than 32 MiB'

echo '--- an absent field'
mkdir -p "$WORK/partial"
printf '%s\n' '{"policyEvaluationResult": {"alerts": []}}' \
  > "$WORK/partial/result-file.json"
run_case partial
expect_in 'partial: count shown as unavailable' "$WORK/partial.md" \
  'Components scanned: n/a'
expect_in 'partial: notice' "$WORK/partial.out" \
  'the result holds no component count'

echo '--- no alert list'
mkdir -p "$WORK/noalerts"
printf '%s\n' '{"policyEvaluationResult": {"totalComponentCount": 4}}' \
  > "$WORK/noalerts/result-file.json"
run_case noalerts
expect_in 'no alerts: count shown' "$WORK/noalerts.md" \
  'Components scanned: 4'
expect_in 'no alerts: alerts unavailable' "$WORK/noalerts.md" \
  'Policy alerts: n/a'
expect_not_in 'no alerts: no zero counts' "$WORK/noalerts.md" \
  '| Critical |'
expect_not_in 'no alerts: not reported clean' "$WORK/noalerts.md" \
  'No policy alerts.'
expect_in 'no alerts: notice' "$WORK/noalerts.out" \
  'the result holds no policy alerts'

echo '--- alerts lacking fields'
mkdir -p "$WORK/alertgaps"
jq -n '{policyEvaluationResult: {totalComponentCount: 3, alerts: [
    {trigger: {policyName: "A", componentFacts: [{componentIdentifier:
      {coordinates: {artifactId: "a"}}}]}},
    {trigger: {threatLevel: 5, componentFacts: []}},
    {trigger: {threatLevel: 7, policyName: "C"}},
    "not an alert"]}}' > "$WORK/alertgaps/result-file.json"
run_case alertgaps
for what in 'threat level' 'policy name' 'component' 'readable entry'; do
  count="$(grep -c "the result holds no ${what} for every policy alert" \
    "$WORK/alertgaps.out" || true)"
  if [ "$count" -eq 1 ]; then
    ok "alert gaps: one notice for a missing ${what}"
  else
    fail "alert gaps: one notice for a missing ${what} (got ${count})"
  fi
done
expect_in 'alert gaps: every entry counted' "$WORK/alertgaps.md" \
  '| All alerts | | 4 |'
expect_in 'alert gaps: unreadable entry counted' "$WORK/alertgaps.md" \
  '| Unreadable | | 1 |'
expect_in 'alert gaps: alert without a level counted' "$WORK/alertgaps.md" \
  '| No band | other or none | 1 |'
expect_in 'alert gaps: counts marked incomplete' "$WORK/alertgaps.md" \
  'Alert counts are incomplete: 1 of 4 alert entries could not be read.'
expect_in 'alert gaps: readable alerts still listed' "$WORK/alertgaps.md" \
  '| 7 | C |'

echo '--- only unreadable alert entries'
mkdir -p "$WORK/unreadable"
printf '%s\n' \
  '{"policyEvaluationResult": {"totalComponentCount": 2, "alerts": [null]}}' \
  > "$WORK/unreadable/result-file.json"
run_case unreadable
expect_not_in 'unreadable: not reported clean' "$WORK/unreadable.md" \
  'No policy alerts.'
expect_in 'unreadable: counted' "$WORK/unreadable.md" '| Unreadable | | 1 |'
expect_in 'unreadable: total' "$WORK/unreadable.md" '| All alerts | | 1 |'
expect_in 'unreadable: counts marked incomplete' "$WORK/unreadable.md" \
  'Alert counts are incomplete'
expect_not_in 'unreadable: no empty alert table' "$WORK/unreadable.md" \
  '| Threat | Policy | Component |'
expect_in 'unreadable: notice' "$WORK/unreadable.out" \
  'the result holds no readable entry for every policy alert'

echo '--- hostile text'
mkdir -p "$WORK/hostile"
# Backticks are the hostile text here, not a command substitution.
# shellcheck disable=SC2016
hostile_policy='Evil | </td><script>alert(1)</script> `x` &amp;'
hostile_policy+=$'\n''::error::injected'$'\r''[link](https://e.invalid)'
hostile_component=$'a|b\n| 10 | Forged | row |\n<img src=x>'
jq -n --arg p "$hostile_policy" --arg c "$hostile_component" '
  {policyEvaluationResult: {totalComponentCount: 1, alerts: [
    {trigger: {policyName: $p, threatLevel: 9, componentFacts: [
      {componentIdentifier: {coordinates: {artifactId: $c,
        version: ($c + ("x" * 500))}}}]}}]}}' \
  > "$WORK/hostile/result-file.json"
APP='app|<b>' MESSAGE=$'line one\n::warning::two | <i>' run_case hostile
for bad in '<' '>' '`' '](' '| Forged |'; do
  expect_not_in "hostile: no raw '${bad}' in the summary" \
    "$WORK/hostile.md" "$bad"
done
expect_in 'hostile: policy escaped' "$WORK/hostile.md" \
  'Evil &#124; &lt;/td&gt;&lt;script&gt;'
expect_in 'hostile: ampersand escaped' "$WORK/hostile.md" '&amp;amp;'
expect_in 'hostile: component capped' "$WORK/hostile.md" '…'
# Every table row keeps its own cell count: three cells, four pipes.
bad_rows="$(grep '^| [0-9]' "$WORK/hostile.md" \
  | awk -F'|' 'NF != 5' || true)"
if [ -z "$bad_rows" ]; then
  ok 'hostile: alert rows keep their cell count'
else
  fail 'hostile: alert rows keep their cell count'
  echo "       rows: ${bad_rows}"
fi
expect_not_in 'hostile: nothing from the result on stdout' \
  "$WORK/hostile.out" 'injected'
expect_not_in 'hostile: no message on stdout' "$WORK/hostile.out" \
  '::warning::'
size="$(wc -c < "$WORK/hostile.md" | tr -d '[:space:]')"
if [ "$size" -lt 16384 ]; then
  ok 'hostile: section stays small'
else
  fail "hostile: section stays small (${size} bytes)"
fi

echo '--- summary modes'
mkdir -p "$WORK/outcome"
write_alerts "$WORK/outcome/result-file.json" 7 '9:Security:lib'
run_case outcome outcome
expect_in 'outcome: outcome table' "$WORK/outcome.md" '| Result |'
expect_not_in 'outcome: no details' "$WORK/outcome.md" 'Components scanned'
expect_not_in 'outcome: no notice' "$WORK/outcome.out" '::notice'
mkdir -p "$WORK/none"
write_alerts "$WORK/none/result-file.json" 7 '9:Security:lib'
run_case none none
if [ ! -s "$WORK/none.md" ]; then
  ok 'none: writes nothing'
else
  fail 'none: writes nothing'
fi

echo '--- action wiring'
# The summary steps follow the scan step; neither may see a credential.
summary_steps="$(awk '/- name: .Download scan result./ { on = 1 } on' \
  "${ACTION_DIR}/action.yaml")"
if [ -z "$summary_steps" ]; then
  fail 'wiring: summary steps found in action.yaml'
elif grep -qE 'nexus_iq_(password|username)' <<< "$summary_steps"; then
  fail 'wiring: summary steps receive no credentials'
else
  ok 'wiring: summary steps receive no credentials'
fi
if grep -q 'write-scan-summary.sh' <<< "$summary_steps"; then
  ok 'wiring: the action runs write-scan-summary.sh'
else
  fail 'wiring: the action runs write-scan-summary.sh'
fi

# The default must leave the scan step as it was: no result-file, so
# run-iq-cli uploads no artifact. result-file takes the name the
# artifact step sets, and that step runs for 'full' alone, so any other
# mode leaves it empty. yq ships on GitHub-hosted runners.
action_yq() {
  yq "$1" "${ACTION_DIR}/action.yaml"
}
if [ "$(action_yq '.inputs.summary.default')" = 'outcome' ]; then
  ok "default: summary defaults to 'outcome'"
else
  fail "default: summary defaults to 'outcome'"
fi
# shellcheck disable=SC2016 # literal GitHub expressions, not shell
artifact_name='${{ steps.artifact.outputs.name }}'
if [ "$(action_yq '.runs.steps[] | select(.id == "scan")
    | .with."result-file"')" = "$artifact_name" ] \
  && [ "$(action_yq '.runs.steps[] | select(.id == "artifact")
    | .if')" = "inputs.summary == 'full'" ]; then
  ok 'default: result-file is set for full alone'
else
  fail 'default: result-file is set for full alone'
fi
if action_yq '.runs.steps[] | select(.id == "download") | .if' \
  | grep -qF "inputs.summary == 'full'"; then
  ok 'default: the result is downloaded for full alone'
else
  fail 'default: the result is downloaded for full alone'
fi

# The input check accepts the three modes and rejects anything else.
action_yq '.runs.steps[]
  | select(.name == "Check action inputs/environment") | .run' \
  > "$WORK/check-inputs.sh"
check_summary() {
  NEXUS_IQ_SERVER=https://iq.invalid NEXUS_IQ_USERNAME=user \
    NEXUS_IQ_PASSWORD=secret SUMMARY="$1" \
    bash "$WORK/check-inputs.sh" > /dev/null 2>&1
}
for mode in outcome full none; do
  if check_summary "$mode"; then
    ok "input check: accepts '${mode}'"
  else
    fail "input check: accepts '${mode}'"
  fi
done
for mode in '' Full outcome,full; do
  if check_summary "$mode"; then
    fail "input check: rejects '${mode}'"
  else
    ok "input check: rejects '${mode}'"
  fi
done

echo
echo "passed: ${passed}  failed: ${failed}"
[ "$failed" -eq 0 ]
