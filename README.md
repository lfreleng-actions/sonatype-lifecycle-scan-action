<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# 🔍 Sonatype Lifecycle Scan

Runs a Sonatype Lifecycle (Nexus IQ) scan.

## sonatype-lifecycle-scan-action

## Usage Example

<!-- markdownlint-disable MD046 -->

```yaml
steps:
  - name: "Sonatype Lifecycle Scan"
    uses: lfreleng-actions/sonatype-lifecycle-scan-action@main
    with:
      nexus_iq_password: ${{ secrets.nexus_iq_password }}
      scan_targets: 'my-project-folder'
```

<!-- markdownlint-enable MD046 -->

## Inputs

<!-- markdownlint-disable MD013 -->

| Name                    | Required | Default   | Description                                              |
| ----------------------- | -------- | --------- | -------------------------------------------------------- |
| nexus_iq_server         | True     |           | Nexus IQ Server URL                                      |
| nexus_iq_username       | True     |           | Nexus IQ USERNAME                                        |
| nexus_iq_password       | True     |           | Nexus IQ Password                                        |
| java_distribution       | False    | temurin   | JAVA SE distribution to setup/run for Nexus CLI tool     |
| java_version            | False    | 17        | Java runtime to setup/run for Nexus CLI tool             |
| iq_cli_version          | False    | 2.13.0-01 | Specific version of Nexus CLI to setup/run               |
| application_id          | False    |           | Organisation and project name in Nexus IQ                |
| scan_targets            | False    | .         | Location of file(s) or folder(s) to scan                 |
| ignore_scanning_errors  | False    | false     | Ignore scanning errors (invalid/inaccessible files)      |
| ignore_system_errors    | False    | false     | Ignore system errors (IO, network, server, etc.)         |
| fail_on_policy_warnings | False    | false     | Fail the scan when policy evaluation warnings occur      |
| advanced_properties     | False    |           | System properties for the Nexus IQ CLI (key=value pairs) |
| summary                 | False    | outcome   | Job summary content: `outcome`, `full` or `none`         |
| no_checkout             | False    | false     | Do not checkout local repository; used for testing       |
| debug                   | False    | false     | Enable debugging output                                  |

<!-- markdownlint-enable MD013 -->

### Excluding Folders from the Scan

The Nexus IQ CLI has no dedicated exclusion flag; pass scanner system
properties through `advanced_properties` instead. This matters when
build steps populate the workspace with content that breaks or skews
the scan (e.g. scaffolding templates containing placeholder
`package.json` files, tool caches, or downloaded runtimes).

```yaml
steps:
  - name: "Sonatype Lifecycle Scan"
    uses: lfreleng-actions/sonatype-lifecycle-scan-action@main
    with:
      nexus_iq_password: ${{ secrets.nexus_iq_password }}
      advanced_properties: |
        dirExcludes=**/.*,**/CVS,**/node_modules/@schematics/**
```

`dirExcludes`/`fileExcludes` accept comma-separated Ant-style patterns
and replace the scanner defaults (`**/.*,**/CVS`), so keep those
defaults when adding new patterns. Do not put spaces in a property
value: properties split on whitespace and newlines, so a space would
break the value into separate tokens. To keep invalid files from
failing the scan without excluding them, set
`ignore_scanning_errors: 'true'` instead.

### Workspace Variables in Inputs

The `advanced_properties` and `scan_targets` inputs expand a fixed
list of names before the Nexus IQ CLI runs:

`GITHUB_WORKSPACE`, `GITHUB_REPOSITORY`, `GITHUB_REF_NAME`,
`GITHUB_SHA`, `GITHUB_RUN_ID`, `RUNNER_TEMP`, `RUNNER_OS`

Both the `${NAME}` and `$NAME` forms work:

```yaml
advanced_properties: |
  dirExcludes=${GITHUB_WORKSPACE}/generated/**
```

Every other `${...}` reaches the CLI as written, and a name outside
the list stays literal even where the environment holds a value for
it: the step's environment can hold credentials, and an open
substitution would put one in a CLI argument. Nothing in the expansion
executes, so `$(...)`, backticks and `$((...))` reach the CLI as
written too. The same expansion, with the same name list, applies to
the argument inputs of [maven-build-action][mba] and
[sonarqube-cloud-scan-action][scsa].

[mba]: https://github.com/lfreleng-actions/maven-build-action
[scsa]: https://github.com/lfreleng-actions/sonarqube-cloud-scan-action

### Required Inputs

For the mandatory inputs, create the following Github variables at the
organisation level so that all repositories can use them:

- NEXUS_IQ_SERVER
- NEXUS_IQ_USERNAME

Also, the following secret:

- NEXUS_IQ_PASSWORD

Pass the values of these variables to the action from the calling workflow.

## Outputs

<!-- markdownlint-disable MD013 -->

| Name              | Description                                                         |
| ----------------- | ------------------------------------------------------------------- |
| scan_id           | ID of the scan; empty when the CLI produced no scan result          |
| report_url        | URL of the IQ policy evaluation report; empty without a scan result |
| priorities_url    | URL of the IQ application priorities, where the server returns one  |
| cli_exit_code     | Exit code of the Nexus IQ CLI (0 on success)                        |
| cli_exit_category | Exit category, e.g. `SUCCESS` or `POLICY_VIOLATION`                 |
| cli_exit_message  | Exit message of the Nexus IQ CLI                                    |

<!-- markdownlint-enable MD013 -->

The three `cli_exit_*` outputs carry a value whenever the scan step
ran, including when it failed before scanning. The exit codes are
0 `SUCCESS`, 1 `POLICY_VIOLATION`, 2 `SCANNING_ERROR`,
3 `REACHABILITY_ERROR`, 4 `CONFIGURATION_ERROR`, 5 `CONNECTIVITY_ERROR`,
6 `LOCAL_IO_ERROR`, 7 `AUTH_ERROR` and 99 `INTERNAL_ERROR`.

## Job Summary

After the scan, whether it passed or failed, the action adds a section
to the job summary of the run. The `summary` input selects its content:

- `outcome` (default): a table of the application ID, the result (the
  CLI exit category), the CLI exit message and the scan ID. The scan
  step runs as it does without a summary and uploads no artifact.
- `full`: the outcome table, then the number of components
  scanned, the number of policy alerts in each threat band (Critical 8
  to 10, Severe 4 to 7, Moderate 2 to 3, Low 1) and the 25
  highest-threat alerts with their policy, component and threat level.
  A line after the table gives the number of alerts it left out. A
  separate row counts alert entries the action cannot read, and the
  summary then says the counts are incomplete.
- `none`: no section, and no result artifact.

The links to the IQ policy evaluation report and application
priorities that `sonatype/actions/run-iq-cli` writes to the summary
appear as before.

For `full`, the action has `run-iq-cli` upload the CLI result file as
a run artifact, then downloads it to read the details. The artifact
name carries the run ID, the run attempt, the job ID and a random
part, so two jobs of one run that call the action do not collide.
When the details are unavailable (a failed download, a missing,
malformed or oversized result file, a scan that failed before policy
evaluation), the summary shows the outcome table alone and a notice
on the run says what was missing. The steps that download the result
and write the summary never change the result: the action fails when
the scan step fails and at no other time.

`full` is opt-in because of what it costs: the upload happens inside
the scan step, and `run-iq-cli` fails that step when the upload
fails, whatever the scan found. With `full`, an artifact storage
quota or service failure fails the scan. The unique artifact name
rules out a clash, not those. The default `outcome` and `none` upload
nothing, so neither adds this way for the scan to fail.

The section uses `jq`, which GitHub-hosted runners provide. On a
self-hosted runner without `jq`, the action writes no section and
logs a notice instead.

The summary and the result artifact are as visible as the run itself:
anyone who can see the workflow run, which for a public repository is
anyone, can read the component names, policy names and threat levels
they hold. Keep the default `outcome`, or set `summary: none`, where
that detail should stay on the Nexus IQ server.
