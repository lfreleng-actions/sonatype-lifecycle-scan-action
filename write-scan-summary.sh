#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Writes the outcome of a Nexus IQ scan to the job summary. Run by the
# action after the scan step, whether that step passed or failed, as
# 'bash write-scan-summary.sh'; the test suite runs the same file.
#
# Environment:
#   SUMMARY_MODE       'outcome' or 'full'
#   APPLICATION_ID     application the scan evaluated
#   CLI_EXIT_CATEGORY  run-iq-cli output cli-exit-category
#   CLI_EXIT_MESSAGE   run-iq-cli output cli-exit-message
#   SCAN_ID            run-iq-cli output scan-id
#   RESULT_DOWNLOAD    outcome of the step that fetched the result file
#   RESULT_DIR         directory that step downloaded it into
#   GITHUB_STEP_SUMMARY  file the section is appended to
#
# The summary must never change the result of the action, so this
# script exits 0 on every path. Where the details 'full' asks for are
# unavailable it still writes the outcome table and says what was
# missing in a ::notice::.
#
# Every value written comes from the scan: component coordinates come
# from the change under test and policy names from the server, so all
# of it is treated as hostile. Each value is capped in length and has
# control characters replaced and Markdown/HTML metacharacters turned
# into entities before it reaches a table cell. None of it is printed
# to standard output, where the runner would read workflow commands;
# the notices printed there are fixed text.
#
# The jq programs below sit in single quotes so the shell leaves their
# '$' alone; SC2016 reads that as a mistake.
# shellcheck disable=SC2016

# Largest result file read; above it the details are skipped.
MAX_RESULT_BYTES=$((32 * 1024 * 1024))
# Rows in the alert table.
MAX_ALERT_ROWS=25

notice() {
  printf '::notice title=Sonatype scan summary::%s\n' "$1"
}

# Shared jq definitions. cell($max) renders any value as safe table
# cell text no longer than $max characters (before escaping).
JQ_DEFS='
def obj: if type == "object" then . else {} end;
def threat:
  (.trigger | obj | .threatLevel)
  | if type == "number" then .
    elif type == "string" then (tonumber? // null)
    else null end;
def coordinates:
  .trigger | obj | .componentFacts
  | if type == "array" then .[0] else null end
  | obj | .componentIdentifier | obj | .coordinates | obj;
def cell($max):
  (if . == null then "" elif type == "string" then . else tojson end)
  | gsub("[\\p{Cc}\\p{Cf}\\p{Zl}\\p{Zp}]"; " ")
  | gsub("^ +| +$"; "")
  | if length > $max then .[0:$max - 1] + "…" else . end
  | if . == "" then "n/a" else
      gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")
      | gsub("\\|"; "&#124;") | gsub("`"; "&#96;")
      | gsub("\\\\"; "&#92;") | gsub("\\["; "&#91;")
      | gsub("\\]"; "&#93;") | gsub("\\*"; "&#42;")
      | gsub("_"; "&#95;") | gsub("~"; "&#126;")
    end;
'

# Section heading and the outcome table, from the scan step outputs.
OUTCOME_JQ='
"## Sonatype Lifecycle scan",
"",
"| Field | Value |",
"| ----- | ----- |",
"| Application ID | \($app | cell(200)) |",
"| Result | \(if $category == "SUCCESS" then "✅" else "❌" end)"
  + " \($category | cell(40)) |",
"| Message | \($message | cell(500)) |",
"| Scan ID | \($scan | cell(100)) |",
""
'

# Lists, one per line, each detail the result file lacks. The names
# are literals from this program, never data from the file, and each
# appears once however many alerts lack it.
MISSING_JQ='
(.policyEvaluationResult | type) as $t
| if $t != "object" then "policy evaluation result"
  else
    .policyEvaluationResult as $per
    | (if ($per.totalComponentCount | type) != "number"
       then "component count" else empty end),
      (if ($per.alerts | type) != "array" then "policy alerts"
       else
         $per.alerts as $alerts
         | (if any($alerts[]; type != "object")
            then "readable entry for every policy alert" else empty end),
           ([$alerts[] | select(type == "object")]) as $objs
           | (if any($objs[]; threat == null)
              then "threat level for every policy alert" else empty end),
             (if any($objs[]; .trigger | obj | .policyName
                 | type != "string" or . == "")
              then "policy name for every policy alert" else empty end),
             (if any($objs[]; coordinates | length == 0)
              then "component for every policy alert" else empty end)
       end)
  end
'

# Component count, alerts per threat band and the highest-threat
# alerts. Threat levels that are not numbers sort last and fall in no
# band. Without an alerts array the counts would read as zero, so only
# the component count is shown and the alerts are reported unavailable.
# Entries that are not alerts are counted apart and mark the counts
# incomplete; only an empty alert array reads as no policy alerts.
DETAILS_JQ='
def component:
  coordinates as $c
  | ([$c | to_entries[] | select(.key != "version")
      | .value | select(. != null and . != "")
      | if type == "string" then . else tojson end] | join(":")) as $name
  | ($c.version | if . == null then "" elif type == "string" then .
      else tojson end) as $version
  | [$name, $version] | map(select(. != "")) | join(" @ ");
def band($lo; $hi): map(select(. != null and . >= $lo and . <= $hi)) | length;
.policyEvaluationResult | obj as $per
| "### Policy evaluation",
  "",
  "Components scanned: \($per.totalComponentCount
    | if type == "number" then tostring else "n/a" end)",
  "",
  if ($per.alerts | type) != "array" then
    "Policy alerts: n/a, the result holds no alert list.",
    ""
  else
    ($per.alerts | map(select(type == "object"))) as $alerts
    | (($per.alerts | length) - ($alerts | length)) as $unreadable
    | ($alerts | map(threat | if . == null then null else floor end)) as $levels
    | ($alerts | map({t: threat, policy: (.trigger | obj | .policyName),
        component: component}) | sort_by(-(.t // -1))) as $sorted
    | "| Threat band | Threat levels | Alerts |",
    "| ----------- | ------------- | -----: |",
    "| Critical | 8 to 10 | \($levels | band(8; 10)) |",
    "| Severe | 4 to 7 | \($levels | band(4; 7)) |",
    "| Moderate | 2 to 3 | \($levels | band(2; 3)) |",
    "| Low | 1 | \($levels | band(1; 1)) |",
    (($levels | length) - ($levels | band(1; 10))) as $unbanded
    | (if $unbanded > 0 then "| No band | other or none | \($unbanded) |"
       else empty end),
    (if $unreadable > 0 then "| Unreadable | | \($unreadable) |"
     else empty end),
    "| All alerts | | \($per.alerts | length) |",
    "",
    (if $unreadable > 0 then
       "Alert counts are incomplete: \($unreadable) of"
         + " \($per.alerts | length) alert entries could not be read. The IQ policy evaluation report lists every"
         + " alert.",
       ""
     else empty end),
    if ($per.alerts | length) == 0 then "No policy alerts.", ""
    elif ($sorted | length) == 0 then empty
    else
      "| Threat | Policy | Component |",
      "| -----: | ------ | --------- |",
      ($sorted[0:$rows][]
        | "| \(.t | cell(10)) | \(.policy | cell(120))"
          + " | \(.component | cell(200)) |"),
      "",
      (($sorted | length) - $rows) as $left
      | if $left > 0 then
          "\($left) more policy alerts not shown; the IQ policy"
            + " evaluation report lists every alert.",
          ""
        else empty end
    end
  end
'

# Picks the result file out of the downloaded artifact.
find_result_file() {
  local dir="$1" f found='' count=0
  if [ -f "$dir/result-file.json" ]; then
    printf '%s' "$dir/result-file.json"
    return 0
  fi
  for f in "$dir"/*.json; do
    if [ -f "$f" ]; then
      found="$f"
      count=$((count + 1))
    fi
  done
  [ "$count" -eq 1 ] && printf '%s' "$found"
}

# Sets DETAILS to the 'full' section, or prints a notice saying why it
# cannot. Called directly, not in a command substitution, so the
# notices reach standard output and DETAILS holds only Markdown.
DETAILS=''
render_details() {
  local file size missing line
  if [ "${RESULT_DOWNLOAD-}" != 'success' ]; then
    notice 'Scan details unavailable: the result artifact was not downloaded'
    return 0
  fi
  file="$(find_result_file "${RESULT_DIR-}")"
  if [ -z "$file" ]; then
    notice 'Scan details unavailable: no result file in the downloaded artifact'
    return 0
  fi
  size="$(wc -c < "$file" | tr -d '[:space:]')"
  if [ -z "$size" ] || [ "$size" -gt "$MAX_RESULT_BYTES" ]; then
    notice 'Scan details unavailable: the result file is larger than 32 MiB'
    return 0
  fi
  # jq reads a stream of values, so a file of several objects would pass
  # a plain type check and render one details section per object.
  if ! jq -n -e '[inputs] | length == 1 and (.[0] | type == "object")' \
    "$file" > /dev/null 2>&1; then
    notice 'Scan details unavailable: the result file is not a JSON object'
    return 0
  fi
  missing="$(jq -r "${JQ_DEFS}${MISSING_JQ}" "$file" 2> /dev/null)"
  if [ "$missing" = 'policy evaluation result' ]; then
    notice 'Scan details unavailable: the result holds no policy evaluation'
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    notice "Scan details incomplete: the result holds no ${line}"
  done <<< "$missing"
  if ! DETAILS="$(jq -r --argjson rows "$MAX_ALERT_ROWS" \
    "${JQ_DEFS}${DETAILS_JQ}" "$file" 2> /dev/null)"; then
    DETAILS=''
    notice 'Scan details unavailable: the result file could not be rendered'
  fi
}

main() {
  local mode="${SUMMARY_MODE-}" section
  case "$mode" in
    outcome | full) ;;
    *) return 0 ;;
  esac
  if [ -z "${GITHUB_STEP_SUMMARY-}" ]; then
    notice 'No job summary written: GITHUB_STEP_SUMMARY is not set'
    return 0
  fi
  if ! command -v jq > /dev/null 2>&1; then
    notice 'No job summary written: jq is not installed on this runner'
    return 0
  fi
  if ! section="$(jq -rn \
    --arg app "${APPLICATION_ID-}" \
    --arg category "${CLI_EXIT_CATEGORY-}" \
    --arg message "${CLI_EXIT_MESSAGE-}" \
    --arg scan "${SCAN_ID-}" \
    "${JQ_DEFS}${OUTCOME_JQ}")"; then
    notice 'No job summary written: the outcome table could not be rendered'
    return 0
  fi
  if [ "$mode" = 'full' ]; then
    render_details
    [ -n "$DETAILS" ] && section="${section}"$'\n\n'"${DETAILS}"
  fi
  printf '%s\n' "$section" >> "$GITHUB_STEP_SUMMARY" \
    || notice 'No job summary written: the summary file is not writable'
  return 0
}

main
exit 0
