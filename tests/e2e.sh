#!/usr/bin/env bash
#
# tests/e2e.sh — end-to-end round trip against a throwaway MinIO.
#
#   tests/e2e.sh                  # needs docker; rclone native or via docker
#   KEEP=1 tests/e2e.sh           # leave the MinIO container and work dir for inspection
#
# Images (override with env): MINIO_IMAGE, MC_IMAGE. Encryption cases run when
# `age` and `age-keygen` are on PATH.
#
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S3SYNC="$HERE/../s3sync.sh"
MINIO_IMAGE="${MINIO_IMAGE:-ghcr.io/coollabsio/minio:latest}"
MC_IMAGE="${MC_IMAGE:-pgsty/mc:latest}"
PORT="${PORT:-$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')}"
AK=e2eadmin
SK=e2esecret-$RANDOM$RANDOM
NAME="s3sync-e2e-$$"
W="$(mktemp -d "${TMPDIR:-/tmp}/s3sync-e2e.XXXXXX")"
mkdir -p "$W/seed" "$W/metrics"   # must exist before docker bind-mounts it, or dockerd creates it as root
PASS=0
FAIL=0

cleanup() {
    if [[ -z ${KEEP:-} ]]; then
        docker rm -f "$NAME" >/dev/null 2>&1 || true
        chmod -R u+w "$W" 2>/dev/null || true
        rm -rf "$W"
    else
        echo "kept: container $NAME on :$PORT, work dir $W"
    fi
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf '\e[32mPASS\e[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '\e[31mFAIL\e[0m %s\n' "$*"; }
step() { printf '\n\e[36m== %s\e[0m\n' "$*"; }
expect() {  # expect <status> <description> -- command...
    local want="$1" what="$2"; shift 3
    local got=0
    "$@" >"$W/last.out" 2>&1 || got=$?
    if [[ $got == "$want" ]]; then ok "$what (exit $got)"
    else bad "$what: exit $got, wanted $want"; tail -20 "$W/last.out" | sed 's/^/    /'; fi
}
s3()  { "$S3SYNC" -c "$W/s3sync.yml" "$@"; }
mc()  { docker run --rm -i --network host --user "$(id -u):$(id -g)" -e HOME=/tmp \
           -e "MC_HOST_e2e=http://$AK:$SK@127.0.0.1:$PORT" \
           -v "$W/seed:$W/seed" "$MC_IMAGE" "$@"; }
put_raw() {  # put_raw <bucket> <key-urlencoded> <data>  (keys mc would normalise)
    curl -fsS -o /dev/null --path-as-is --aws-sigv4 "aws:amz:us-east-1:s3" --user "$AK:$SK" \
         -X PUT --data-binary "$3" "http://127.0.0.1:$PORT/$1/$2"
}

# ---------------------------------------------------------------------------
step "start MinIO ($MINIO_IMAGE) on :$PORT"
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:9000" -e "MINIO_ROOT_USER=$AK" -e "MINIO_ROOT_PASSWORD=$SK" \
    "$MINIO_IMAGE" server /data >/dev/null
for _ in $(seq 1 40); do curl -fs "http://127.0.0.1:$PORT/minio/health/ready" >/dev/null && break; sleep 0.5; done
mc mb -q e2e/media e2e/other e2e/restore-a >/dev/null

step "seed"
mkdir -p "$W/seed/tree/dir/nested" "$W/seed/tree/sp ace" "$W/seed/tree/photos"
echo hello >"$W/seed/tree/plain.txt"
echo nested >"$W/seed/tree/dir/nested/file.bin"
echo unicode >"$W/seed/tree/sp ace/unié.txt"
: >"$W/seed/tree/empty"
head -c 300000 /dev/urandom >"$W/seed/tree/photos/a.jpg"
python3 -c 'print("compressible line of text\n" * 80000, end="")' >"$W/seed/tree/log.txt"
head -c $((20 * 1024 * 1024)) /dev/urandom >"$W/seed/tree/big.bin"     # multipart upload
mc cp -q -r "$W/seed/tree/" e2e/media/ >/dev/null
put_raw media 'marker/' ''                                                 # folder marker
put_raw media 'datadir/' 'data-under-folder-key'                           # cannot be a file
echo other >"$W/seed/o.txt"; mc cp -q "$W/seed/o.txt" e2e/other/o.txt >/dev/null
ok "seeded media ($(mc ls -r e2e/media | wc -l) objects incl. edge cases)"

AGE_OK=false
if command -v age >/dev/null && command -v age-keygen >/dev/null; then
    age-keygen -o "$W/age.key" 2>/dev/null; chmod 600 "$W/age.key"
    AGE_PUB="$(age-keygen -y "$W/age.key")"; AGE_OK=true
fi

cat >"$W/s3sync.env" <<EOF
E2E_AK=$AK
E2E_SK=$SK
EOF
cat >"$W/s3sync.yml" <<EOF
env_file: $W/s3sync.env
defaults:
  backup_dir: $W/backup
  log_file: $W/s3sync.log
  retention_days: 0
  verify: quick
  hash_workers: 2
  min_free_space: 1G
  lock_wait: 5
  ${AGE_OK:+age_identity_file: $W/age.key}
metrics:
  textfile_dir: $W/metrics
offsite:
  enabled: true
  endpoint: local
  bucket: offsite
  prefix: host01
  retention_days: 30
endpoints:
  local:
    url: "http://\${E2E_AK}:\${E2E_SK}@127.0.0.1:$PORT?provider=Minio&path_style=true"
sources:
  - name: media
    endpoint: local
    bucket: media
  - name: media_tar
    endpoint: local
    bucket: media
    format: tar.zst
    compression_level: 3
  - name: media_zip
    endpoint: local
    bucket: media
    format: zip
    cache: drop
  - name: media_gz
    endpoint: local
    bucket: media
    format: tar.gz
    exclude: ["*.bin"]
  - name: srv
    endpoint: local
    all_buckets: true
    include_buckets: ["other"]
EOF
if $AGE_OK; then cat >>"$W/s3sync.yml" <<EOF
  - name: media_age
    endpoint: local
    bucket: media
    format: tar.zst
    encrypt: age
    age_recipients: ["$AGE_PUB"]
EOF
fi
cat >>"$W/s3sync.yml" <<EOF
targets:
  restore_a: { endpoint: local, bucket: restore-a }
  restore_b: { endpoint: local, bucket: restore-b, create: true }
  scratch:   { endpoint: local, bucket: scratch, create: true, scratch: true }
  notscratch: { endpoint: local, bucket: restore-a }
  intosource: { endpoint: local, bucket: media }
EOF
chmod 600 "$W/s3sync.env"

# ---------------------------------------------------------------------------
step "preflight"
expect 0 "test --deep" -- s3 test --deep
grep -q 'cannot be backed up' "$W/last.out" && ok "test --deep reports unbackupable keys" || bad "test --deep did not report the datadir/ key"
expect 0 "discover" -- s3 discover
grep -q 'restore-a.*NOT BACKED UP' "$W/last.out" && ok "discover flags uncovered bucket" || bad "discover output"

step "dry run writes nothing"
expect 0 "backup -n" -- s3 -n backup media
[[ -z $(find "$W/backup/media" -mindepth 1 -maxdepth 1 2>/dev/null) ]] && ok "dry run left no backup" || bad "dry run created files"

step "snapshot backup #1"
expect 3 "backup media (warns about skipped key)" -- s3 backup media
B1="$(ls -d "$W"/backup/media/2*Z | tail -1)"
[[ -f $B1/data/big.bin && -f $B1/data/sp\ ace/unié.txt && -f $B1/data/empty ]] && ok "objects on disk" || bad "objects missing in $B1"
grep -q 'datadir/' "$B1/skipped.jsonl" && ok "skipped.jsonl lists datadir/" || bad "skipped.jsonl"
python3 - "$B1" <<'PY' && ok "manifest records the folder marker" || bad "marker missing in manifest"
import gzip,json,sys
rows=[json.loads(l) for l in gzip.open(sys.argv[1]+'/manifest.jsonl.gz','rt')]
sys.exit(0 if any(r.get('d') and r['k']=='marker/' for r in rows) else 1)
PY

step "mutate source, snapshot backup #2"
sleep 1.2
cp "$B1/data/plain.txt" "$W/seed/plain.before"
echo changed-content >"$W/seed/plain.txt"; mc cp -q "$W/seed/plain.txt" e2e/media/plain.txt >/dev/null
head -c 300000 /dev/urandom >"$W/seed/a2.jpg"; mc cp -q "$W/seed/a2.jpg" e2e/media/photos/a.jpg >/dev/null   # same size
mc rm -q e2e/media/dir/nested/file.bin >/dev/null
echo brand-new >"$W/seed/new.txt"; mc cp -q "$W/seed/new.txt" e2e/media/new/new.txt >/dev/null
sleep 1.2
expect 3 "backup media again" -- s3 backup media
B2="$(ls -d "$W"/backup/media/2*Z | tail -1)"
[[ $B1 != "$B2" ]] && ok "second snapshot $(basename "$B2")" || bad "no second snapshot"
[[ $(stat -c %i "$B1/data/big.bin") == $(stat -c %i "$B2/data/big.bin") ]] && ok "unchanged object hardlinked" || bad "big.bin not hardlinked"
[[ $(stat -c %i "$B1/data/plain.txt") != $(stat -c %i "$B2/data/plain.txt") ]] && ok "changed object got a new inode" || bad "plain.txt shares inode"
cmp -s "$B1/data/plain.txt" "$W/seed/plain.before" && ok "old snapshot content intact" || bad "old snapshot was modified"
cmp -s "$B2/data/photos/a.jpg" "$W/seed/a2.jpg" && ok "same-size change detected" || bad "same-size change missed"
[[ ! -e $B2/data/dir/nested/file.bin && -e $B1/data/dir/nested/file.bin ]] && ok "deletion only in new snapshot" || bad "deletion handling"
[[ -f $B2/data/new/new.txt ]] && ok "new object present" || bad "new object missing"
python3 -c 'import json,sys;m=json.load(open(sys.argv[1]));sys.exit(0 if m["changed"]==2 and m["deleted"]==1 and m["new"]==1 else 1)' "$B2/meta.json" \
    && ok "meta counts new/changed/deleted" || bad "meta counts: $(cat "$B2/meta.json")"

step "off-site + metrics"
mc ls -r e2e/offsite/host01/media/current/ >"$W/off.txt"
grep -q 'new/new.txt' "$W/off.txt" && ! grep -q 'dir/nested/file.bin' "$W/off.txt" \
    && ok "off-site current/ follows the delta (added + deleted)" || bad "off-site current: $(cat "$W/off.txt")"
mc ls e2e/offsite/host01/media/manifests/ | grep -q "$(basename "$B2")" && ok "manifest copied off-site" || bad "off-site manifest"
grep -q '"offsite": "20' "$B2/meta.json" && ok "meta records off-site copy" || bad "meta offsite field"
grep -q 's3sync_backup_bytes{label="media"}' "$W/metrics/s3sync.prom" && ok "metrics textfile written" || bad "metrics file"

step "verify"
expect 0 "verify --latest media" -- s3 verify --latest media
expect 0 "verify --latest media --full" -- s3 verify --latest media --full
cp "$B2/data/new/new.txt" "$W/new.bak"
printf 'X' | dd of="$B2/data/new/new.txt" bs=1 seek=0 conv=notrunc status=none
expect 1 "verify --full detects a flipped byte" -- s3 verify --latest media --full
grep -q 'HASH' "$W/last.out" && ok "report names the damaged object" || bad "no HASH line"
[[ -f $W/backup/media/.redownload ]] && ok "damaged key flagged for re-download" || bad ".redownload missing"
cp "$W/new.bak" "$B2/data/new/new.txt"
expect 0 "verify passes after repair" -- s3 verify --latest media --full

step "restore snapshot"
expect 1 "restore into a source bucket is refused" -- s3 restore --latest media -t intosource
expect 0 "restore --latest media -t restore_a --verify full" -- s3 restore --latest media -t restore_a --verify full
mc cat e2e/restore-a/big.bin | cmp -s - "$W/seed/tree/big.bin" && ok "big.bin restored byte-identical" || bad "big.bin differs"
mc ls e2e/restore-a/ | grep -q 'marker/' && ok "folder marker recreated" || bad "folder marker missing"
expect 0 "restore --prefix photos --to-dir" -- s3 restore --latest media --prefix photos --to-dir "$W/out-photos"
[[ -f $W/out-photos/photos/a.jpg && ! -e $W/out-photos/big.bin ]] && ok "selective restore to directory" || bad "selective restore"
expect 0 "restore --at the first backup" -- s3 restore --latest media --at "$(basename "$B1")" --to-dir "$W/out-at"
cmp -s "$W/out-at/plain.txt" "$W/seed/plain.before" && ok "--at picks the older backup" || bad "--at content"

step "archives"
expect 3 "backup media_tar (tar.zst)" -- s3 backup media_tar
expect 0 "verify media_tar --full" -- s3 verify --latest media_tar --full
mc ls -r e2e/offsite/host01/media_tar/ | grep -q 'media_tar.tar.zst' && ok "archive copied off-site" || bad "off-site archive"
expect 3 "backup media_zip (cache: drop)" -- s3 backup media_zip
[[ ! -d $W/backup/.cache/media_zip ]] && ok "cache dropped" || bad "cache kept"
expect 0 "verify media_zip --full" -- s3 verify --latest media_zip --full
expect 3 "backup media_gz (exclude *.bin)" -- s3 backup media_gz
G="$(ls -d "$W"/backup/media_gz/2*Z | tail -1)"
tar -tzf "$G"/media_gz.tar.gz | grep -q 'big.bin' && bad "exclude ignored" || ok "exclude filter honoured"
expect 0 "restore tar.zst -> restore_b (--create)" -- s3 restore --latest media_tar -t restore_b --verify full
expect 0 "restore zip --include '*.txt' --to-dir" -- s3 restore --latest media_zip --include '*.txt' --to-dir "$W/out-zip"
[[ -f $W/out-zip/plain.txt && ! -e $W/out-zip/big.bin ]] && ok "zip selective restore" || bad "zip selective restore"
T="$(ls "$W"/backup/media_tar/2*Z/*.tar.zst | tail -1)"
truncate -s -100 "$T"
expect 1 "truncated archive fails quick verify" -- s3 verify --latest media_tar
if $AGE_OK; then
    expect 3 "backup media_age (encrypted)" -- s3 backup media_age
    expect 0 "verify media_age --full" -- s3 verify --latest media_age --full
    expect 0 "restore encrypted --to-dir" -- s3 restore --latest media_age --to-dir "$W/out-age"
    cmp -s "$W/out-age/big.bin" "$W/seed/tree/big.bin" && ok "encrypted round trip" || bad "encrypted round trip"
else
    echo "(age not installed: encryption cases skipped)"
fi

step "all_buckets"
expect 0 "backup srv (all_buckets, include other)" -- s3 backup srv
srv=("$W"/backup/srv_other/2*Z)
[[ -f ${srv[-1]}/data/o.txt ]] && ok "label srv_other" || bad "srv_other"

step "drill"
expect 1 "drill refuses a non-scratch target" -- s3 drill media -t notscratch
expect 0 "drill media -t scratch" -- s3 drill media -t scratch
grep -q 'result:  PASS' "$W/last.out" && ok "drill report PASS" || bad "drill report"
[[ -z $(mc ls -r e2e/scratch 2>/dev/null) ]] && ok "scratch emptied" || bad "scratch still has objects"

step "resume after an interrupted run"
cp -al "$B2" "$W/backup/media/20990101T000000Z.part"      # looks like a killed run (no meta.json)
rm -f "$W/backup/media/20990101T000000Z.part/meta.json"
expect 3 "backup resumes the .part" -- s3 backup media
grep -q 'resuming interrupted run' "$W/last.out" && ok "resume used" || bad "resume not used"
[[ -z $(ls -d "$W"/backup/media/*.part 2>/dev/null) ]] && ok "no .part left" || bad ".part left behind"

step "locking"
exec 7>>"$W/backup/.locks/label-media.lock"; flock -x 7
expect 1 "second backup of a busy label fails after lock_wait" -- s3 backup media
flock -u 7; exec 7>&-

step "retention"
L="$W/backup/ret"; mkdir -p "$L"
for d in 20260101T020000Z 20260102T020000Z 20260108T020000Z 20260115T020000Z 20260201T020000Z 20260301T020000Z; do
    mkdir -p "$L/$d"; echo '{"verify":"quick-ok","format":"snapshot"}' >"$L/$d/meta.json"
done
mkdir -p "$L/20260302T020000Z"; echo '{"verify":"failed","format":"snapshot"}' >"$L/20260302T020000Z/meta.json"
cat >>"$W/s3sync.yml" <<EOF
  # (appended by e2e for the retention test)
EOF
python3 - "$W/s3sync.yml" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("sources:\n","sources:\n  - name: ret\n    endpoint: local\n    bucket: media\n    enabled: false\n    retention_min_keep: 1\n    keep_monthly: 2\n",1)
open(p,'w').write(s)
PY
expect 0 "prune (GFS keep_monthly: 2)" -- env S3SYNC_NOW="$(date -d 2026-03-10 +%s)" "$S3SYNC" -c "$W/s3sync.yml" prune
left="$(ls "$L" | tr '\n' ' ')"
# the failed 0302 run is newer than every good backup: kept for inspection until a good one follows
[[ $left == "20260201T020000Z 20260301T020000Z 20260302T020000Z " ]] && ok "GFS kept newest of last 2 months, dropped older" || bad "retention left: $left"
mkdir -p "$L/20260303T020000Z"; echo '{"verify":"quick-ok","format":"snapshot"}' >"$L/20260303T020000Z/meta.json"
expect 0 "prune again after a newer good backup" -- env S3SYNC_NOW="$(date -d 2026-03-10 +%s)" "$S3SYNC" -c "$W/s3sync.yml" prune
[[ ! -e $L/20260302T020000Z ]] && ok "failed backup dropped once a newer good one exists" || bad "failed backup kept"

step "list + metrics"
expect 0 "list" -- s3 list
grep -q 'hardlinks save' "$W/last.out" && ok "list shows hardlink savings" || bad "list output"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
