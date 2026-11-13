# s3sync — Standard Operating Procedure

Who this is for: whoever runs object-storage backups on a host with s3sync installed.

## 1. Setting up a new host

1. `sudo ./install.sh --with-rclone --systemd`
2. Fill `/etc/s3sync/s3sync.env` (mode 0600) with access keys. Prefer a **read-only** key for
   sources (`s3:ListBucket`, `s3:GetObject`) and a separate key for targets.
3. Edit `/etc/s3sync/s3sync.yml`: endpoints, sources, targets, a `scratch` target for drills.
4. Match `ReadWritePaths` in `/etc/systemd/system/s3sync-*.service` to `backup_dir`.
5. `s3sync test --deep` — every line must be OK. Fix anything it reports as unbackupable, or accept
   it knowingly.
6. `s3sync discover` — confirm no bucket is marked `NOT BACKED UP` unless that is intended.
7. Run the first backup by hand: `sudo systemctl start s3sync-backup.service`, then
   `journalctl -u s3sync-backup -f`. First runs download everything; later runs only changes.
8. `s3sync drill <source> -t scratch -y` — the first drill proves the restore path.

## 2. Schedule

| What | When | Check |
|---|---|---|
| Backup + quick verify + off-site + prune | nightly (`s3sync-backup.timer`) | healthcheck / `s3sync_last_success_timestamp_seconds` |
| Full re-hash of the newest backups + restore drill | weekly (`s3sync-verify.timer`) | drill report in `backup_dir/reports/drill_*` |
| Review `s3sync list` and disk headroom | monthly | free space > `min_free_space` + one full backup |
| Off-site bucket restore test (`restore` from the off-site endpoint as a target) | quarterly | |

## 3. Recovery objectives

- **RPO** (data you can lose) = time since the last good backup — at most ~24 h with the nightly
  timer. Each drill report states the actual backup age.
- **RTO** (time to recover) is measured by every drill (restore + full verification) and written to
  the drill report. Use it, not a guess, when you promise a recovery time.

## 4. Restore runbook

1. **Decide the point in time.** `s3sync list <label>`. Pick the newest backup before the incident:
   `--at 2026-11-12T09:00` (UTC).
2. **Restore to a new bucket first**, never straight over production:
   ```bash
   s3sync restore --latest media --at 2026-11-12T09:00 -t minio_dr --create --verify full
   ```
3. Point the application at the restored bucket, or copy back selectively:
   ```bash
   s3sync restore --latest media --at 2026-11-12T09:00 --prefix invoices/ -t prod_media --force-source
   ```
   `--force-source` is required because the target is a bucket s3sync backs up; confirm with the
   bucket owner first.
4. For a full rollback of a bucket (deletes objects created after the backup):
   `--mode mirror` — it asks for confirmation; check the dry run (`-n`) first.
5. Record what was restored, from which backup, and the verify result in the incident notes.

Single files: `s3sync restore --latest media --include 'path/to/file.pdf' --to-dir /tmp/r`. For
snapshot backups the file is also simply at `/backup/s3/media/<timestamp>/data/path/to/file.pdf`.

## 5. Responding to alerts

| Alert | Do |
|---|---|
| Backup failed (exit 1) | `journalctl -u s3sync-backup -n 100`; then [TROUBLESHOOTING.md](TROUBLESHOOTING.md). Re-run with `sudo systemctl start s3sync-backup` — it resumes. |
| Warning (exit 3) | Read `skipped.jsonl` in the newest backup. Objects changed mid-run are picked up next night; unbackupable names need renaming at the source. |
| Verify failed | Report in `backup_dir/reports/`. Disk damage: check `dmesg`/SMART. The next backup re-downloads damaged objects; older snapshots listed as `SHARED` share the damage. |
| Drill failed | Treat as a failed backup: the backup cannot be trusted until a drill passes. |
| No success ping for >26 h | Timer not running (`systemctl list-timers 's3sync-*'`), host down, or a lock held by a hung run (`ls -l /backup/s3/.locks`, `ps aux | grep s3sync`). |

## 6. Changes

- Adding a source: add it, `s3sync test --deep`, `s3sync backup <name>`.
- Removing a source: remove it from the config; its backups stay and are pruned with the default
  retention. Delete `/backup/s3/<label>` by hand when they are no longer needed.
- Changing a source's `format`: the next run starts a new chain; older backups stay restorable.
- Upgrading: `git pull && sudo ./install.sh` or `sudo s3sync self-update`; run `s3sync test`.
