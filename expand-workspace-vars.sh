#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Defines expand_workspace_vars, sourced by the action step that hands
# the caller's inputs to the Nexus IQ CLI. It lives in a file rather
# than inline so the test suite sources the same code the action runs.
#
# The CLI receives advanced_properties and scan_targets exactly as the
# caller wrote them: nothing between the workflow file and the CLI
# re-expands ${...} inside a value. Jenkins expanded these in a shell
# before the CLI started, so a caller writing an absolute workspace
# path reasonably expects the same. The function below is the same one
# maven-build-action and sonarqube-cloud-scan-action apply to their
# argument inputs, so the expansion behaves identically across the
# lfreleng-actions scan and build actions.
#
# Expand a fixed list of workspace variables. Bash string operations
# rather than eval or a subprocess: nothing here executes, so $(...),
# backticks and $((...)) stay inert, and the caller gains no
# dependency beyond the shell it already runs in. The name list is
# explicit because the calling step's environment can hold
# credentials; anything outside the list passes through literally.
expand_workspace_vars() {
  local text="$1" out='' head rest raw name value
  local allow=' GITHUB_WORKSPACE GITHUB_REPOSITORY GITHUB_REF_NAME'
  allow="$allow GITHUB_SHA GITHUB_RUN_ID RUNNER_TEMP RUNNER_OS "
  while [ "${text#*'$'}" != "$text" ]; do
    head="${text%%'$'*}"
    rest="${text:${#head}+1}"
    if [[ "$rest" =~ ^\{[A-Za-z_][A-Za-z0-9_]*\} ]]; then
      raw="${BASH_REMATCH[0]}"
      name="${raw:1:${#raw}-2}"
    elif [[ "$rest" =~ ^[A-Za-z_][A-Za-z0-9_]* ]]; then
      raw="${BASH_REMATCH[0]}"
      name="$raw"
    else
      # A '$' introducing anything else -- '(', a backtick, a
      # digit -- keeps its literal text and its meaning here,
      # which is none.
      out="$out$head\$"
      text="$rest"
      continue
    fi
    if [ "${allow#* "$name" }" != "$allow" ]; then
      value="${!name-}"
    else
      value="\$$raw"
    fi
    out="$out$head$value"
    text="${rest:${#raw}}"
  done
  printf '%s' "$out$text"
}
