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

### Required Inputs

For the mandatory inputs, create the following Github variables at the
organisation level so that all repositories can use them:

- NEXUS_IQ_SERVER
- NEXUS_IQ_USERNAME

Also, the following secret:

- NEXUS_IQ_PASSWORD

Pass the values of these variables to the action from the calling workflow.
