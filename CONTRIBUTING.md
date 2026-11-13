# Contributing to bucketool

Thanks for helping. bucketool backs up production data, so changes are held to one rule:
**a backup that is reported good must be complete, and an older backup must never change.**

## Ground rules

- Keep `bucketool.sh` a single file with no dependencies beyond bash 4.4+, python3 (stdlib only),
  coreutils/tar/flock and rclone or aws-cli. New Python goes into the embedded helper.
- Never pass credentials on a command line. Endpoint secrets travel as environment variables.
- Never let rclone or aws-cli write into an existing file of a snapshot: paths are unlinked first.
- Every new config key goes into both `bucketool.example.yml` and `bucketool.example.json`
  (the unit tests fail when they disagree) and into the README.
- Behaviour changes get a line in `CHANGELOG.md`.

## Checks before a pull request

```bash
bash -n bucketool.sh install.sh tests/e2e.sh
shellcheck --severity=warning --shell=bash bucketool.sh install.sh tests/e2e.sh
python3 tests/test_py.py                 # embedded helper
tests/e2e.sh                             # full round trip against a throwaway MinIO (docker)
E2E_ENGINE=aws tests/e2e.sh              # the same through aws-cli
```

CI runs all of these on every push and pull request, including the encryption cases (`age`).

## Commits

Small, focused commits with an imperative subject (`fix: ...`, `feat: ...`, `docs: ...`) and a
body that explains *why*. Do not commit real configs, env files, keys or backup artifacts —
`.gitignore` blocks them and CI fails if one is tracked.

## Releases

Bump `BUCKETOOL_VERSION` in `bucketool.sh`, add a `## x.y.z` section to `CHANGELOG.md`, then:

```bash
git tag -a vX.Y.Z -m "bucketool vX.Y.Z" && git push origin vX.Y.Z
```

The release workflow checks the tag against the script, attaches `bucketool.sh`, `install.sh`
and `SHA256SUMS` (which `bucketool self-update` verifies).
