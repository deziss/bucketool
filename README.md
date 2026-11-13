# s3sync — S3 / MinIO bucket backup, restore & verify

[![license: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

One shell script, one config file (YAML **or** JSON). Backs up any S3-compatible bucket —
AWS S3, MinIO, Ceph RGW, Cloudflare R2, Wasabi, Garage, DigitalOcean Spaces — to local disk, proves
the backup is complete, restores it anywhere, and runs unattended from systemd.

- **Snapshots** — every backup is a full, browsable copy, but unchanged objects are hardlinks to
  the previous backup and cost no extra disk. Thirty nightly snapshots of a 500 GB bucket
  that changes 1 GB a day take about 530 GB, not 15 TB.
- **Archives** — or one `tar.zst`, `tar.gz` or `zip` file per run, optionally encrypted with
  [age](https://age-encryption.org).
- **Verified** — a manifest records size, modification time and SHA-256 of every object.
  `verify` re-checks the backup on disk, a restored bucket, or both.
- **Retention** — keep N days, or daily/weekly/monthly/yearly (GFS), with a floor of N good backups.
- **Automated** — nightly backup + weekly full verify and restore drill, healthchecks/webhook
  alerts, Prometheus metrics, off-site copy to a second S3.

Operating procedure: [SOP.md](SOP.md). Something failing: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

> **Your real config never belongs in git.** Copy an example to `/etc/s3sync/s3sync.yml`, put keys
> in `/etc/s3sync/s3sync.env` (mode 0600). `.gitignore` blocks real configs, env files, keys and
> backup artifacts.

## Install

```bash
git clone https://github.com/deziss/s3sync.git && cd s3sync
sudo ./install.sh --with-rclone --systemd   # rclone is optional: docker is used if it is missing

# edit /etc/s3sync/s3sync.yml and /etc/s3sync/s3sync.env, then:
s3sync test --deep
```

`install.sh` puts the script in `/opt/s3sync`, links `/usr/local/bin/s3sync`, refreshes the
examples in `/etc/s3sync`, and never touches an existing `s3sync.yml` / `s3sync.env`.
`--with-rclone` downloads a pinned rclone and checks it against the official `SHA256SUMS`.
`--systemd` enables the nightly backup timer and the weekly verify/drill timer.
Re-running it is the whole update; without a checkout use `sudo s3sync self-update`.

Requirements: `bash` 4+, `python3` (stdlib only; PyYAML is used if present), GNU coreutils/tar,
`flock`, and either `rclone` ≥ 1.66 or `docker` (then the pinned `rclone/rclone` image is used).
Optional: `zstd` (tar.zst), `pigz`, `age` (encryption), `curl` (alerts, self-update).

## Config

```yaml
env_file: /etc/s3sync/s3sync.env

defaults:
  backup_dir: /backup/s3
  format: snapshot            # snapshot | tar.zst | tar.gz | zip
  retention_days: 30
  retention_min_keep: 3

endpoints:
  minio_prod:
    url: "https://${MINIO_ACCESS_KEY}:${MINIO_SECRET_KEY}@minio.example.com:9000?provider=Minio&path_style=true"
  aws_main:
    provider: AWS
    region: ap-south-1
    access_key_env: AWS_ACCESS_KEY_ID
    secret_key_env: AWS_SECRET_ACCESS_KEY

sources:
  - name: media
    endpoint: minio_prod
    bucket: media
    exclude: ["tmp/**"]
  - name: minio_all             # every bucket on the server, new ones included
    endpoint: minio_prod
    all_buckets: true
    exclude_buckets: ["scratch-*"]

targets:
  minio_dr: { endpoint: minio_prod, bucket: media-restore, create: true }
```

The full set of keys, with comments, is in [s3sync.example.yml](s3sync.example.yml)
([JSON twin](s3sync.example.json)). The config is found in this order: `-c FILE` →
`$S3SYNC_CONFIG` → `./s3sync.yml|.yaml|.json` → next to the script → `/etc/s3sync/`.

**Endpoints** take a URL (`s3://`, `https://`, `http://`; `?tls=false` for plain HTTP on `s3://`)
or fields: `provider`, `endpoint`, `region`, `access_key[_env|_file]`, `secret_key[_env|_file]`,
`session_token[_env|_file]`, `env_auth` (instance role / AWS profile), `path_style`, and
`options:` — any [rclone s3 option](https://rclone.org/s3/) passed through (e.g. `storage_class`,
`server_side_encryption`). Credentials reach rclone through environment variables only — never
the command line, never a config file on disk. Check how a URL is read with
`s3sync parse-url URL`.

**Sources** need `endpoint` and `bucket` (or `all_buckets: true` with optional `include_buckets` /
`exclude_buckets` globs; each bucket becomes the label `<name>_<bucket>`). Optional: `prefix`,
`include` / `exclude` ([rclone filter patterns](https://rclone.org/filtering/)), `max_size`,
`enabled`, and per-source overrides of `format`, `compression_level`, `zstd_long`, `cache`,
`verify`, retention keys, `transfers`, `checkers`, `bwlimit`, `encrypt`, `age_recipients`.

**Targets** are where `restore` and `drill` write: `endpoint`, `bucket`, optional `prefix`,
`create` (create the bucket), `verify` (default check after a restore), `scratch` (allowed as a
drill target).

## Everyday use

```bash
s3sync test --deep                         # rclone, disk, every source/target/off-site, unbackupable keys
s3sync discover                            # buckets on each server, and which nobody backs up
s3sync backup all                          # what the nightly timer runs
s3sync backup media,invoices -n            # dry run: what would be downloaded
s3sync list                                # backups, sizes, what hardlinks save
s3sync verify --latest all --full          # re-hash every object of every newest backup
s3sync restore --latest media -t minio_dr  # newest good backup into a bucket, then verify it
s3sync drill media -t scratch -y           # restore drill with RPO/RTO report
s3sync prune                               # apply retention now
```

Exit status: `0` ok, `1` failure, `2` usage, `3` finished with warnings (an object could not be
backed up, or changed during the run — see `skipped.jsonl`), `10` update available.

## How a backup works

```
list bucket once ─► diff with last manifest ─► link/unlink ─► download changes ─► gate ─► hash ─► commit ─► verify ─► off-site ─► prune
```

1. **One listing, no per-object requests.** `rclone lsjson --fast-list --use-server-modtime`
   returns key, size and LastModified for the whole bucket. Nothing is read per object.
2. **s3sync decides what changed**, by comparing (size, LastModified) with the previous good
   backup's manifest — not by trusting ETags, which are not checksums for multipart uploads.
3. **Snapshots** start as `cp -al` of the previous snapshot. Every changed or deleted object is
   *unlinked* from the new tree before anything is downloaded, so rclone only ever writes new
   files. Older snapshots cannot be modified, whatever rclone does.
4. **Exactly the missing objects are downloaded** (`rclone copy --files-from-raw`).
5. **Gate**: the files on disk must equal the expected (key, size) set exactly. An object that was
   deleted or rewritten on the source during the run is dropped with a warning (exit 3) instead of
   failing every night; a genuine download failure fails the run and the next run resumes it.
6. **Hash**: SHA-256 for new files; unchanged files inherit their hash only when they are provably
   the same inode as before.
7. **Commit**: `manifest.jsonl.gz`, `SHA256SUMS`, fsync, atomic rename, then `meta.json` last —
   a backup without `meta.json` never counts.

On disk:

```
/backup/s3/<label>/
  20261113T013000Z/            # UTC timestamp
    data/<keys...>             # snapshot format
    <label>.tar.zst[.age]      # or archive formats
    manifest.jsonl.gz          # {"k":key,"s":size,"m":last-modified,"h":sha256} per object
    SHA256SUMS                 # checksums of the manifest and archive
    skipped.jsonl              # objects that could not be backed up, and why (if any)
    meta.json                  # counts, bytes, duration, verify result, off-site status
  20261114T013000Z.part/       # an interrupted run — resumed by the next one
/backup/s3/.cache/<label>/     # archive formats: staging mirror (cache: keep)
/backup/s3/reports/            # verify and drill reports
```

## Formats and saving disk

| Option | What it saves |
|---|---|
| `format: snapshot` | Unchanged objects cost nothing per extra backup (hardlinks). `list` shows the saving. |
| `format: tar.zst` + `compression_level` (1-19) + `zstd_long` | One compressed file per run; text, logs and JSON shrink a lot. |
| `format: zip` | Opens anywhere; content only (no metadata). |
| `keep_daily/weekly/monthly/yearly` | GFS thinning: e.g. 7 daily + 4 weekly + 12 monthly = 23 backups covering a year. |
| `retention_min_keep` | Floor: the N newest *good* backups are never pruned, whatever their age. |
| `include` / `exclude` / `max_size` / `exclude_buckets` | Don't back up temp files, caches, giant exports. |
| `cache: drop` | Archive formats keep no staging mirror (each run downloads everything). |
| `min_free_space` | A run refuses to start rather than fill the disk (checks bytes and inodes). |

Snapshots are the right default: restore of a single object is a file copy, and incremental
cost is close to zero. Archives suit buckets that change completely between runs, or when the
backup must be one encrypted file.

**Encryption**: `encrypt: age` with `age_recipients` (public keys) on a `tar.zst` / `tar.gz`
source. The host that makes backups never needs the private key; restore and full verify need
`defaults.age_identity_file` (mode 0600). `s3sync test` checks the key pair matches.

## Verify

```bash
s3sync verify --latest media              # quick: every object present with the right size, SHA256SUMS, archive integrity
s3sync verify --latest media --full       # re-hash every object against the manifest
s3sync verify --latest media -t minio_dr  # also check a restored bucket against the backup
s3sync verify /backup/s3/media/20261113T013000Z
```

Every backup is verified right after it is written (`defaults.verify`, `quick` by default). When
`--full` finds a damaged file in a snapshot, the report also lists every older snapshot that shares
the damaged inode, and the object is downloaded fresh on the next run.

## Restore

```bash
s3sync restore --latest media -t minio_dr                           # merge into the target bucket
s3sync restore --latest media --at 2026-11-01 -t minio_dr           # newest good backup on or before a date (UTC)
s3sync restore --latest media --prefix invoices/2026 --to-dir /srv/restore
s3sync restore --latest media --include '*.pdf' -t minio_dr --verify full
s3sync restore -f /backup/s3/media/20261113T013000Z -t minio_dr --mode mirror -y
```

- `--mode merge` (default) uploads the backup over the target; `skip-existing` leaves existing
  objects alone; `mirror` also deletes target objects that are not in the backup (asks first).
- After every restore the target is listed and compared with the manifest; `--verify full`
  compares every object byte for byte; `--verify none` skips it.
- A restore into a bucket that a source reads from (compared by host:port and bucket, not by name)
  is refused unless `--force-source`.
- Folder marker objects (`photos/`) are recreated. Object metadata (Content-Type, user metadata,
  tags) is not kept: Content-Type is derived from the file extension on upload.

## Automation

`install.sh --systemd` installs two timers:

| Timer | Runs | When |
|---|---|---|
| `s3sync-backup.timer` | `backup all` → verify → off-site → prune → metrics → alerts | nightly 01:30 |
| `s3sync-verify.timer` | `verify --latest all --full`, then `drill` | Sundays 05:00 |

`SuccessExitStatus=3` keeps warnings from marking the unit failed. `ReadWritePaths` in the units
must match `backup_dir`. cron works too:

```cron
30 1 * * * S3SYNC_CONFIG=/etc/s3sync/s3sync.yml /opt/s3sync/s3sync.sh backup all -y -q >> /var/log/s3sync-cron.log 2>&1
```

- **Alerts**: `notify.healthcheck_url` gets `/start`, success and `/fail` pings
  ([healthchecks.io](https://healthchecks.io) or compatible); `notify.webhook` gets a JSON POST on
  failure or warning (and on success with `on_success: true`). A failed alert never fails a backup.
- **Metrics**: with `metrics.textfile_dir`, a `s3sync.prom` file for node_exporter's textfile
  collector: `s3sync_last_success_timestamp_seconds`, `s3sync_last_backup_ok`, `s3sync_backup_bytes`,
  `s3sync_backup_unique_bytes`, `s3sync_backup_objects`, `s3sync_backup_skipped_objects`,
  `s3sync_backup_duration_seconds`, `s3sync_backups` — all per label. Alert on
  `time() - s3sync_last_success_timestamp_seconds > 93600`.
- **Locks**: two runs never touch the same label at once; prune waits for running backups and
  verifies. A run waits up to `lock_wait` seconds, then fails rather than run unlocked.
- **Resume**: an interrupted snapshot run is picked up by the next run; what was already
  downloaded is not downloaded again.

## Off-site copy

```yaml
offsite: { enabled: true, endpoint: offsite_s3, bucket: s3-backups, prefix: host01, retention_days: 90 }
```

- Snapshots keep `<prefix>/<label>/current/` in step with the newest backup, uploading only the
  objects that changed and deleting the ones that went away. Each backup's manifest goes to
  `<label>/manifests/<timestamp>/`. **Turn on bucket versioning** (and a lifecycle rule for
  non-current versions) on the off-site bucket for point-in-time history; `test --deep` warns when it
  is off. Use credentials that cannot delete object versions, or Object Lock, so a compromised host
  cannot erase the off-site copy.
- Archives are copied as they are to `<label>/<timestamp>/` and pruned after `retention_days`.
- Off-site snapshots are plain files. For encrypted off-site copies use an archive format with
  `encrypt: age`.

## Security

- Credentials only through environment variables (`RCLONE_CONFIG_*`); rclone runs with an empty
  in-memory config, and every inherited `RCLONE_*` variable is cleared first.
- `umask 077`; `backup_dir` is made `0700`; the age identity file must be `0600`.
- A backup is as sensitive as the bucket. Keep `backup_dir` on an encrypted disk, or use
  `encrypt: age`.
- Restores never delete without `--mode mirror` and a confirmation; drills only use targets marked
  `scratch: true`, refuse a non-empty scratch bucket, and delete only the keys they wrote.

## Limits

- Object metadata (Content-Type, user metadata, tags, ACLs) and object versions are not backed up.
- Objects whose names cannot be files (`a` next to `a/b`, `//`, `..`, segments over 255 bytes, line
  breaks) and objects in GLACIER/DEEP_ARCHIVE storage are skipped and listed in `skipped.jsonl`
  (exit 3). `test --deep` reports them up front.
- Snapshot dedup is per file: a 10 GB object that changes by one byte is stored again.
- Memory: about 300 MB per million objects during a run.

## Contributing

```bash
bash -n s3sync.sh && shellcheck --severity=warning s3sync.sh install.sh tests/e2e.sh
python3 tests/test_py.py       # unit tests for the embedded helper
tests/e2e.sh                   # full round trip against a throwaway MinIO (needs docker)
```

## License

GNU Affero General Public License v3.0 or later — see [LICENSE](LICENSE).
Copyright (C) 2026 Anshu Kushwaha. s3sync comes with **no warranty**.
