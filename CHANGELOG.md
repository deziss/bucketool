# Changelog

## 1.0.0

First release.

- Back up any S3-compatible bucket (AWS S3, MinIO, Ceph, R2, Wasabi, Garage, ...) through rclone,
  native (>= 1.66) or the pinned `rclone/rclone:1.75.2` container.
- Formats: hardlinked incremental snapshots, `tar.zst`, `tar.gz`, `zip`; optional `age` encryption
  for tar formats.
- One listing per run, no per-object HEAD requests; s3sync decides what changed from the previous
  manifest and unlinks changed paths before downloading, so older snapshots are never modified.
- Completeness gate, resumable interrupted runs, objects changing mid-run reported instead of failing.
- Manifest with SHA-256 per object; `verify` quick/full, against a restored bucket, with bit-rot
  reporting across shared inodes.
- Restore to a bucket or directory: `--at`, `--prefix`, `--include`, merge/mirror/skip-existing,
  folder markers recreated, post-restore verification; refuses to write into a source bucket.
- Restore drills into scratch targets with RPO/RTO reports.
- Retention by days or GFS (daily/weekly/monthly/yearly) with a floor of N good backups.
- Off-site copy to a second S3 (delta-driven for snapshots), off-site retention.
- `all_buckets` sources, `discover`, `test --deep`, `list` with hardlink savings.
- Two S3 engines, per endpoint or default: rclone and aws-cli v2 (native or pinned
  `amazon/aws-cli:2.40.2` container); the end-to-end suite runs against both.
- healthchecks/webhook alerts, Prometheus textfile metrics, systemd timers, `install.sh`, `self-update`.
