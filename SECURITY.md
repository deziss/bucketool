# Security policy

## Supported versions

Only the latest release receives fixes. Update with `sudo bucketool self-update`.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private reporting:
[Security → Report a vulnerability](https://github.com/deziss/bucketool/security/advisories/new).

Include the version (`bucketool --version`), the engine (rclone or aws), and steps to reproduce.
You will get an acknowledgement within a few days and a fix or mitigation plan after triage.

## Scope

In scope: credential exposure (argv, logs, files), backups reported good while incomplete,
modification of older backups, restores or drills writing to the wrong bucket, path traversal
from object keys or archive members, and self-update integrity.

Backups contain your data: protect `backup_dir`, the env file and the age identity file with
filesystem permissions or disk encryption — bucketool cannot defend a host that is already
compromised.
