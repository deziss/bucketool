# bucketool — Troubleshooting

Run with `-v` to see rclone's own output. Every rclone error is also summarised in the log line
that reports the failure.

## Connection and credentials

| Symptom | Cause / fix |
|---|---|
| `listing ... failed: ... InvalidAccessKeyId / SignatureDoesNotMatch` | Wrong keys, or the env file was not loaded (`env_file:` path, `${VAR}` names). `bucketool parse-url URL` shows how a URL is read. |
| `... no such host` / `connection refused` | `endpoint` / URL host and port. For plain HTTP use `http://` or `?tls=false`. |
| `InvalidBucketName` | Bucket names are 3-63 characters. |
| MinIO / Ceph: `PermanentRedirect` or bucket not found | Add `path_style=true` to the URL (or `path_style: true`). |
| AWS: `AuthorizationHeaderMalformed ... region` | Set `region:` to the bucket's region. |
| Run hangs, then fails after `timeout` | The server is down or a firewall drops packets. rclone retries 5 times (with 20 low-level retries) before giving up. |
| rclone finishes but objects are missing / listings differ between runs (seen with some MinIO setups) | The gate fails or warns instead of committing a short backup. Set `engine: aws` on that endpoint: it lists with ListObjectsV2 through aws-cli. |
| aws engine: `XAmzContentSHA256Mismatch` / checksum errors | bucketool already sets `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`; check for a proxy rewriting bodies. |
| aws engine: `Unknown options` | aws-cli v1 found on PATH. bucketool needs v2; remove v1 or let it use the container. |

## Disk

| Symptom | Fix |
|---|---|
| `... needs X and must leave Y free (min_free_space)` | Free space, lower retention, `exclude` large prefixes, or lower `min_free_space`. The run did not start, nothing was changed. |
| `needs about N inodes` | Every snapshot creates one inode per directory. Use a filesystem with more inodes (XFS/ext4 with `-i`), or an archive format. |
| `cp -al failed` | `backup_dir` must be one local filesystem that supports hardlinks (not FAT/exFAT, not a different mount per label). |
| `test` warns about NFS/CIFS | `flock` and hardlinks are unreliable there. Use a local disk and the off-site copy instead. |

## Objects that cannot be backed up (exit 3)

Listed with a reason in `skipped.jsonl` of the backup and by `test --deep`:

- **Name is also a folder** (`a` and `a/b` both exist) — a file cannot also be a directory.
  Rename one at the source. Note: MinIO in single-drive mode may hide `a/b` from listings
  entirely when `a` exists; bucketool cannot see it either.
- **`//`, leading `/`, `.` / `..` segments, a segment longer than 255 bytes, a line break** — not
  representable as a path on Linux.
- **Data stored under a key ending in `/`** — a folder-style key with content.
- **GLACIER / DEEP_ARCHIVE storage class** — the object must be restored on the server first
  (GLACIER_IR is read normally).
- **Changed or deleted on the source during the backup** — picked up on the next run.

## Archives and encryption

| Symptom | Fix |
|---|---|
| `zstd integrity test failed` / `gzip integrity test failed` | The archive file is damaged or truncated. The next backup writes a new one; restore from an older backup. |
| `encrypt: age needs format tar.zst or tar.gz` | Encryption is for tar archives only (zip cannot be read from a stream). |
| `this archive is encrypted: set defaults.age_identity_file` | Restores and `--full` verifies of `.age` archives need the private key. Quick verify only checks `SHA256SUMS`. |
| `age identity file ... is readable by others` | `chmod 600` the key file. |

## Locks

`lock 'label-media' is still held by another bucketool run` — a backup of that label is running (or
hung). `ps aux | grep bucketool`. Locks live in `backup_dir/.locks/` and are released by the kernel
when the process exits; never delete the files to "unlock" a running job.

## Restore

| Symptom | Fix |
|---|---|
| `target ... writes into bucket '...' that source '...' backs up` | Intended? add `--force-source`. Safer: restore into a new bucket. |
| `bucket ... does not exist` | `--create` or `create: true` on the target. |
| `... is not empty` (`--to-dir`) | Restore into an empty or new directory. |
| `drill target ... must be marked scratch: true` | Drills delete what they restore; only `scratch: true` targets are allowed. |
| Restored objects have a different Content-Type | Metadata is not backed up; rclone derives Content-Type from the extension. |

## How things work (design notes and verified behaviour)

- Listing uses `--use-server-modtime --no-mimetype`: one LIST request per 1000 objects, no HEAD
  per object. Change detection is (size, LastModified). ETags are not used: for multipart uploads
  they are not content hashes.
- Snapshot safety does not depend on rclone: changed and deleted paths are unlinked from the new
  tree before rclone runs, and rclone is never run with `sync`, `--inplace` or metadata flags into
  a snapshot. `tests/e2e.sh` checks that an older snapshot stays byte-identical after content,
  same-size and delete changes.
- Folder markers (zero-byte keys ending in `/`) are recorded in the manifest and recreated with
  `rclone mkdir --s3-directory-markers` on restore.
- rclone is run with `RCLONE_CONFIG=/dev/null` (in-memory config) and remotes defined through
  `RCLONE_CONFIG_<REMOTE>_*` variables; inherited `RCLONE_*` variables are cleared first.
- In docker mode every file rclone reads or writes is under `backup_dir` (bind-mounted at the same
  path), because systemd's `PrivateTmp` hides `/tmp` from dockerd.
