# Bunny Storage Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One-way DB + media backup of the sulu-skeleton-mc deployment to Bunny Storage (S3-compatible) via rclone — periodic in-container cron plus a full pre-deploy backup before every migration.

**Architecture:** A self-contained `docker/backup.sh` dumps the MariaDB database and `rclone sync`s the media directories to a generic `bunny:` rclone remote configured entirely through `RCLONE_CONFIG_BUNNY_*` env vars. The entrypoint runs this script once before `doctrine:migrations:migrate` (pre-deploy snapshot) and, when enabled, starts busybox `crond` as a fourth supervised child for the periodic run. Everything is opt-in and defaults to off.

**Tech Stack:** POSIX sh, Alpine busybox (`crond`, `crontab`, `flock`), `rclone` (Alpine pkg), `mariadb-client` (`mariadb-dump`), Docker, Bunny Magic Containers.

## Global Constraints

- Base image: `php:8.4-fpm-alpine`; all scripts are **POSIX sh** (busybox), not bash.
- Backup is **opt-in**: inactive unless `BACKUP_ENABLED=true` and S3 credentials are non-empty. New env vars ship with empty/safe defaults.
- Backup failures must **never** abort or degrade the container. `backup.sh` always exits 0.
- Do **not** touch the DB-volume layout (`/var/lib/mysql`) or the `APP_DATA_DIR` symlink logic (`var/storage`, `var/indexes`, `public/uploads`). Both entrypoint modes stay intact.
- rclone remote is generic (`bunny:`), fully env-configured — **no config file, no secrets on disk**. Default backend S3, swappable to SFTP by env only.
- Media dirs are symlinks into `/data` in APP_DATA_DIR mode → rclone must follow symlinks with `-L`.
- MariaDB dump uses `MYSQL_PWD` (not `-p` on argv) to keep the password out of the process list.
- The DB dump is written to `$APP_CACHE_DIR/backup/` (default `/var/cache/sulu/backup`), never onto the data volume.

---

## File Structure

- `docker/backup.sh` — **new.** The backup logic (DB dump + retention + media sync). Runnable from cron and the entrypoint.
- `test/backup/run-test.sh` — **new.** Offline stub-based test harness for `backup.sh` (runs in an Alpine container, stubs `rclone`/`mariadb-dump`).
- `Dockerfile` — **modify.** Install `rclone` + `mariadb-client`; symlink `backup.sh` to `/usr/local/bin/backup`.
- `docker/entrypoint.sh` — **modify.** Capture the fresh-DB flag, run the pre-deploy backup before migrations, start `crond` as a supervised child.
- `bunny.json` — **modify.** Add the new env vars to the `app` container.
- `README.md` — **modify.** Document enabling the backup, the schedule, and the restore procedure.
- `docs/superpowers/specs/2026-07-17-bunny-storage-backup-design.md` — **modify.** Flip status to Implemented at the end.

---

## Task 1: `docker/backup.sh` + offline stub test

**Files:**
- Create: `docker/backup.sh`
- Create: `test/backup/run-test.sh`

**Interfaces:**
- Consumes: env vars `BACKUP_ENABLED`, `BACKUP_BUCKET`, `BACKUP_RETENTION`, `BACKUP_KEEP_DELETED`, `APP_CACHE_DIR`, `DATABASE_URL`, `RCLONE_CONFIG_BUNNY_*` (the last read by `rclone` itself). Requires `rclone`, `mariadb-dump`, `gzip`, `flock` on PATH.
- Produces: an executable `docker/backup.sh` that, when run with `BACKUP_ENABLED=true`, calls `mariadb-dump` once, `rclone copy` of the gzipped dump to `bunny:$BACKUP_BUCKET/db/`, prunes old dumps to `BACKUP_RETENTION`, and `rclone sync -L` for `var/storage`→`storage` and `public/uploads`→`uploads` (adding `--backup-dir bunny:$BACKUP_BUCKET/_deleted/<ts>/<dst>` when `BACKUP_KEEP_DELETED=true`). Always exits 0.

- [ ] **Step 1: Write the failing test harness**

Create `test/backup/run-test.sh`. It stubs `rclone` and `mariadb-dump` (each logs its argv to `$CALLS`), then runs `backup.sh` under several env configurations and asserts on the recorded calls. Designed to run inside `alpine:3.20` (busybox sh + flock + gzip).

```sh
#!/bin/sh
# Offline test for docker/backup.sh. Run from repo root:
#   docker run --rm -v "$PWD":/repo -w /repo alpine:3.20 sh test/backup/run-test.sh
set -eu

work=$(mktemp -d)
bindir="$work/bin"
mkdir -p "$bindir"
CALLS="$work/calls.log"
: > "$CALLS"
export CALLS

# --- stubs -----------------------------------------------------------------
cat > "$bindir/rclone" <<'EOF'
#!/bin/sh
echo "rclone $*" >> "$CALLS"
# emulate `rclone lsf db/` returning 9 existing dumps for the retention test
case "$1 $2" in
  "lsf "*/db/*|"lsf "*db/) printf 'sulu-2026010%s-000000.sql.gz\n' 1 2 3 4 5 6 7 8 9 ;;
esac
exit 0
EOF
cat > "$bindir/mariadb-dump" <<'EOF'
#!/bin/sh
echo "mariadb-dump $* PWD=${MYSQL_PWD:-}" >> "$CALLS"
echo "-- fake dump"
exit 0
EOF
chmod +x "$bindir/rclone" "$bindir/mariadb-dump"
export PATH="$bindir:$PATH"

fail() { echo "FAIL: $1"; echo "--- calls ---"; cat "$CALLS"; exit 1; }
assert_grep() { grep -q -- "$1" "$CALLS" || fail "expected call matching: $1"; }
assert_absent() { ! grep -q -- "$1" "$CALLS" || fail "unexpected call matching: $1"; }

run() { : > "$CALLS"; ( cd "$work/app" && sh /repo/docker/backup.sh ) >"$work/out.log" 2>&1 || true; }

# --- fixture: a fake app tree with media dirs ------------------------------
mkdir -p "$work/app/var/storage" "$work/app/public/uploads" "$work/app/cache"
echo x > "$work/app/var/storage/orig.jpg"
export APP_CACHE_DIR="$work/app/cache"
export DATABASE_URL="mysql://sulu:s3cr3t@db-host:3307/suludb?serverVersion=10.11.14-MariaDB"
export BACKUP_BUCKET="mybucket"

# Case A: disabled -> no rclone/mariadb calls
unset BACKUP_ENABLED 2>/dev/null || true
run
assert_absent "rclone"
assert_absent "mariadb-dump"
echo "PASS: disabled -> no backup calls"

# Case B: enabled -> dump, upload, media sync, keep-deleted backup-dir
export BACKUP_ENABLED=true
export BACKUP_KEEP_DELETED=true
export BACKUP_RETENTION=7
run
assert_grep "mariadb-dump"
assert_grep "PWD=s3cr3t"                 # password via MYSQL_PWD, not argv
assert_grep "-h db-host"                 # host parsed from DATABASE_URL
assert_grep "-P 3307"                    # port parsed
assert_grep "suludb"                     # db name parsed
assert_grep "rclone copy"                # dump uploaded
assert_grep "bunny:mybucket/db/"         # to db/ prefix
assert_grep "sync -L"                    # media sync follows symlinks
assert_grep "bunny:mybucket/storage"
assert_grep "bunny:mybucket/uploads"
assert_grep "backup-dir bunny:mybucket/_deleted/"
echo "PASS: enabled -> full backup call sequence"

# Case C: retention -> 9 remote dumps, keep 7 -> prune 2 oldest
grep -q "rclone deletefile bunny:mybucket/db/sulu-20260101-000000.sql.gz" "$CALLS" \
  || fail "expected pruning of oldest dump"
grep -q "rclone deletefile bunny:mybucket/db/sulu-20260102-000000.sql.gz" "$CALLS" \
  || fail "expected pruning of 2nd-oldest dump"
assert_absent "deletefile bunny:mybucket/db/sulu-20260103-000000.sql.gz"
echo "PASS: retention prunes oldest beyond BACKUP_RETENTION"

# Case D: keep-deleted off -> no backup-dir flag
: > "$CALLS"
export BACKUP_KEEP_DELETED=false
run
assert_grep "sync -L"
assert_absent "backup-dir"
echo "PASS: keep-deleted off -> no --backup-dir"

echo "ALL BACKUP TESTS PASSED"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `docker run --rm -v "$PWD":/repo -w /repo alpine:3.20 sh test/backup/run-test.sh`
Expected: FAIL — `docker/backup.sh` does not exist yet (`sh: can't open '/repo/docker/backup.sh'`), the first `assert_absent` may pass but Case B assertions fail. Non-zero exit.

- [ ] **Step 3: Write `docker/backup.sh`**

```sh
#!/bin/sh
# Back up the MariaDB database and media directories to a Bunny Storage
# rclone remote ("bunny:"). Safe to run from cron or the entrypoint — it
# never aborts the container: every failure is logged and the script still
# exits 0. Opt-in via BACKUP_ENABLED=true.
set -u

log() { echo "[backup $(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { log "ERROR: $*"; }

# Serialize runs so a long media sync never overlaps the next cron tick or a
# concurrent pre-deploy run. Non-blocking: skip if another run holds the lock.
if command -v flock >/dev/null 2>&1; then
    exec 9>/var/lock/backup.lock
    if ! flock -n 9; then
        log "another backup run is in progress, skipping."
        exit 0
    fi
fi

: "${BACKUP_ENABLED:=}"
if [ "$BACKUP_ENABLED" != "true" ]; then
    log "BACKUP_ENABLED is not 'true', skipping."
    exit 0
fi

: "${BACKUP_BUCKET:=}"
: "${BACKUP_RETENTION:=7}"
: "${BACKUP_KEEP_DELETED:=true}"
: "${APP_CACHE_DIR:=/var/cache/sulu}"
: "${DATABASE_URL:=}"
REMOTE="bunny:${BACKUP_BUCKET}"

db_dump() {
    # Parse DATABASE_URL: mysql://user:pass@host:port/dbname?params
    rest=${DATABASE_URL#*://}
    creds=${rest%%@*}
    hostpart=${rest#*@}
    user=${creds%%:*}
    pass=${creds#*:}
    [ "$pass" = "$creds" ] && pass=""
    hostportdb=${hostpart%%\?*}
    hostport=${hostportdb%%/*}
    db=${hostportdb#*/}
    host=${hostport%%:*}
    port=${hostport#*:}
    [ "$port" = "$hostport" ] && port=3306

    ts=$(date '+%Y%m%d-%H%M%S')
    tmpdir="$APP_CACHE_DIR/backup"
    mkdir -p "$tmpdir"
    dump="$tmpdir/sulu-$ts.sql.gz"

    log "dumping database '$db' from $host:$port ..."
    if MYSQL_PWD="$pass" mariadb-dump --single-transaction --quick --no-tablespaces \
        -h "$host" -P "$port" -u "$user" "$db" | gzip -c > "$dump"; then
        if rclone copy "$dump" "$REMOTE/db/"; then
            log "database dump uploaded: db/$(basename "$dump")"
        else
            fail "rclone copy of database dump failed."
        fi
    else
        fail "mariadb-dump failed."
    fi
    rm -f "$dump"
}

db_retention() {
    files=$(rclone lsf "$REMOTE/db/" 2>/dev/null | grep '^sulu-.*\.sql\.gz$' | sort)
    total=$(printf '%s\n' "$files" | grep -c . || true)
    if [ "$total" -gt "$BACKUP_RETENTION" ]; then
        remove=$((total - BACKUP_RETENTION))
        printf '%s\n' "$files" | head -n "$remove" | while IFS= read -r f; do
            [ -n "$f" ] || continue
            log "pruning old dump: db/$f"
            rclone deletefile "$REMOTE/db/$f" || fail "could not prune db/$f"
        done
    fi
}

media_sync() {
    ts=$(date '+%Y%m%d-%H%M%S')
    for pair in "var/storage:storage" "public/uploads:uploads"; do
        src=${pair%%:*}
        dst=${pair#*:}
        [ -e "$src" ] || { log "skip $src (missing)"; continue; }
        set -- sync -L "$src" "$REMOTE/$dst"
        if [ "$BACKUP_KEEP_DELETED" = "true" ]; then
            set -- "$@" --backup-dir "$REMOTE/_deleted/$ts/$dst"
        fi
        log "syncing $src -> $dst ..."
        if rclone "$@"; then
            log "synced $dst."
        else
            fail "rclone sync of $src failed."
        fi
    done
}

db_dump
db_retention
media_sync
log "backup run complete."
exit 0
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `docker run --rm -v "$PWD":/repo -w /repo alpine:3.20 sh test/backup/run-test.sh`
Expected: PASS — ends with `ALL BACKUP TESTS PASSED`, exit 0.

- [ ] **Step 5: Lint the script**

Run: `docker run --rm -v "$PWD":/repo -w /repo koalaman/shellcheck:stable docker/backup.sh`
Expected: no warnings (exit 0). If SC2039/SC3043-type "in POSIX sh" notes appear for constructs actually used, fix them; the script above is POSIX-clean.

- [ ] **Step 6: Commit**

```bash
git add docker/backup.sh test/backup/run-test.sh
git commit -m "feat(backup): add DB + media backup script for Bunny Storage"
```

---

## Task 2: Dockerfile — install tools + link `backup`

**Files:**
- Modify: `Dockerfile:8-19` (the `apk add` block) and add a `COPY`/`chmod` for `backup.sh`

**Interfaces:**
- Consumes: `docker/backup.sh` from Task 1.
- Produces: image with `rclone`, `mariadb-dump` on PATH and `/usr/local/bin/backup` → the backup script (executable).

- [ ] **Step 1: Add the packages**

In `Dockerfile`, extend the first runtime `apk add --no-cache` line (currently installing `apache2 apache2-proxy git unzip su-exec imagemagick ...`) to also install `rclone` and `mariadb-client`:

```dockerfile
RUN apk add --no-cache apache2 apache2-proxy git unzip su-exec rclone mariadb-client \
        imagemagick imagemagick-jpeg imagemagick-webp imagemagick-heic imagemagick-svg \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
```

(Only the first line changes — the rest of the `RUN` block is unchanged.)

- [ ] **Step 2: Install the backup script alongside the existing helper**

Find the existing entrypoint/helper copy block near the end of the Dockerfile:

```dockerfile
COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/clear-caches.sh /usr/local/bin/clear-caches
RUN chmod +x /entrypoint.sh /usr/local/bin/clear-caches
```

Replace it with:

```dockerfile
COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/clear-caches.sh /usr/local/bin/clear-caches
COPY docker/backup.sh /usr/local/bin/backup
RUN chmod +x /entrypoint.sh /usr/local/bin/clear-caches /usr/local/bin/backup
```

- [ ] **Step 3: Build the image**

Run: `docker build -t sulu-mc-test .`
Expected: build succeeds.

- [ ] **Step 4: Verify the tools and script are present**

Run:
```bash
docker run --rm --entrypoint sh sulu-mc-test -c \
  'command -v rclone && command -v mariadb-dump && command -v backup && head -1 /usr/local/bin/backup'
```
Expected: prints `/usr/bin/rclone`, `/usr/bin/mariadb-dump`, `/usr/local/bin/backup`, and `#!/bin/sh` — exit 0.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile
git commit -m "build(backup): install rclone + mariadb-client, ship backup helper"
```

---

## Task 3: entrypoint — pre-deploy backup + supervised crond

**Files:**
- Modify: `docker/entrypoint.sh` (empty-DB detection ~L88-91; before migrations ~L110-112; supervise/trap block ~L114-135)

**Interfaces:**
- Consumes: `/usr/local/bin/backup` (Task 2), env vars `BACKUP_ENABLED`, `BACKUP_BEFORE_MIGRATE`, `BACKUP_SCHEDULE`, `RCLONE_CONFIG_BUNNY_ACCESS_KEY_ID`.
- Produces: pre-deploy backup runs before `doctrine:migrations:migrate` (skipped on a freshly built DB); `crond` runs as a fourth supervised child when backup is active.

- [ ] **Step 1: Capture the fresh-DB flag at the empty-DB branch**

Replace the empty-DB block:

```sh
if ! console bin/adminconsole doctrine:query:sql "SELECT 1 FROM se_users LIMIT 1" > /dev/null 2>&1; then
    echo "Empty database detected, running sulu:build prod..."
    console bin/adminconsole sulu:build prod --no-interaction
fi
```

with a version that records whether the DB was freshly initialized:

```sh
fresh_db=0
if ! console bin/adminconsole doctrine:query:sql "SELECT 1 FROM se_users LIMIT 1" > /dev/null 2>&1; then
    echo "Empty database detected, running sulu:build prod..."
    console bin/adminconsole sulu:build prod --no-interaction
    fresh_db=1
fi
```

- [ ] **Step 2: Add the pre-deploy backup immediately before migrations**

Find the migration block:

```sh
#* Datenbank-Migrationen (optional, falls DB-Zugriff nötig für Backup-Config)
echo "Running database migrations..."
php bin/adminconsole doctrine:migrations:migrate --no-interaction --allow-no-migration
```

Insert directly **above** the `echo "Running database migrations..."` line:

```sh
# Pre-deploy backup: capture a full restore point (DB + media) before any
# migration runs. Skipped when the DB was just built (nothing to protect).
# backup.sh itself is a no-op unless BACKUP_ENABLED=true, so this is safe to
# call unconditionally when the DB already existed.
if [ "${BACKUP_BEFORE_MIGRATE:-true}" = "true" ] && [ "$fresh_db" = "0" ]; then
    echo "Running pre-deploy backup before migrations..."
    /usr/local/bin/backup || true
fi

```

- [ ] **Step 3: Start crond as a supervised child**

Replace the process-launch/supervise/trap block (from `mkdir -p /run/apache2` through the final `exit 1`):

```sh
mkdir -p /run/apache2
php-fpm -F &
fpm_pid=$!
httpd -DFOREGROUND &
httpd_pid=$!

# Periodic backup: only when explicitly enabled and credentials are present.
# busybox crond reads /var/spool/cron/crontabs; job output is redirected to
# the container's stdout (PID 1) so it shows up in the container logs.
crond_pid=""
if [ "${BACKUP_ENABLED:-}" = "true" ] && [ -n "${RCLONE_CONFIG_BUNNY_ACCESS_KEY_ID:-}" ]; then
    : "${BACKUP_SCHEDULE:=0 3 * * *}"
    echo "${BACKUP_SCHEDULE} /usr/local/bin/backup >/proc/1/fd/1 2>&1" | crontab -
    echo "Backup enabled: cron schedule '${BACKUP_SCHEDULE}'."
    crond -f -l 8 -L /dev/stderr &
    crond_pid=$!
fi

stopping=0
trap 'stopping=1; kill -TERM "$fpm_pid" "$httpd_pid" ${crond_pid:+$crond_pid} 2>/dev/null || true' TERM INT QUIT

while kill -0 "$fpm_pid" 2>/dev/null && kill -0 "$httpd_pid" 2>/dev/null \
      && { [ -z "$crond_pid" ] || kill -0 "$crond_pid" 2>/dev/null; }; do
    # Interruptible sleep: wait on a background sleep so TERM/INT are handled
    # immediately instead of after the full interval.
    sleep 5 &
    wait $! || true
done

kill -TERM "$fpm_pid" "$httpd_pid" ${crond_pid:+$crond_pid} 2>/dev/null || true
wait || true

if [ "$stopping" = 1 ]; then
    exit 0
fi
echo "ERROR: php-fpm, httpd or crond exited unexpectedly, stopping container." >&2
exit 1
```

- [ ] **Step 4: Lint the entrypoint**

Run: `docker run --rm -v "$PWD":/repo -w /repo koalaman/shellcheck:stable docker/entrypoint.sh`
Expected: no new warnings versus the pre-change baseline (exit 0).

- [ ] **Step 5: Build and smoke-test the disabled path**

Rebuild and confirm the container still boots exactly as before when backup is off. Bring up the full stack with docker-compose (already in the repo) and assert **no** `crond` process:

Run:
```bash
docker build -t sulu-mc-test . \
  && docker compose up -d \
  && sleep 25 \
  && docker compose exec -T app sh -c 'ps -o comm | grep -c crond || true'
```
Expected: prints `0` (no crond), and the app responds. Tear down: `docker compose down`.

> Note: this uses the repo's `docker-compose.yml`. If it doesn't set `BACKUP_ENABLED`, the disabled path is exercised. The enabled path (crond present + pre-deploy backup firing before migrations against a real `bunny:` remote) is verified manually in Task 6.

- [ ] **Step 6: Commit**

```bash
git add docker/entrypoint.sh
git commit -m "feat(backup): run pre-deploy backup and supervise crond in entrypoint"
```

---

## Task 4: bunny.json — new env vars

**Files:**
- Modify: `bunny.json` (the `app` container `environment` block, ~L19-31)

**Interfaces:**
- Consumes: nothing.
- Produces: the `app` container declares all backup env vars with safe (off) defaults.

- [ ] **Step 1: Add the env vars**

In `bunny.json`, inside the `app` container's `environment` object, add these keys (keep existing keys; JSON has no comments, so the descriptions here are for the plan only):

```json
"BACKUP_ENABLED": "",
"BACKUP_BEFORE_MIGRATE": "true",
"BACKUP_SCHEDULE": "0 3 * * *",
"BACKUP_RETENTION": "7",
"BACKUP_KEEP_DELETED": "true",
"BACKUP_BUCKET": "",
"RCLONE_CONFIG_BUNNY_TYPE": "s3",
"RCLONE_CONFIG_BUNNY_PROVIDER": "Other",
"RCLONE_CONFIG_BUNNY_ENDPOINT": "",
"RCLONE_CONFIG_BUNNY_ACCESS_KEY_ID": "",
"RCLONE_CONFIG_BUNNY_SECRET_ACCESS_KEY": ""
```

- [ ] **Step 2: Validate JSON**

Run: `python3 -m json.tool bunny.json > /dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 3: Verify all keys are present**

Run:
```bash
python3 -c "import json;e=json.load(open('bunny.json'))['containers'][0]['environment'];print(all(k in e for k in ['BACKUP_ENABLED','BACKUP_BEFORE_MIGRATE','BACKUP_SCHEDULE','BACKUP_RETENTION','BACKUP_KEEP_DELETED','BACKUP_BUCKET','RCLONE_CONFIG_BUNNY_TYPE','RCLONE_CONFIG_BUNNY_PROVIDER','RCLONE_CONFIG_BUNNY_ENDPOINT','RCLONE_CONFIG_BUNNY_ACCESS_KEY_ID','RCLONE_CONFIG_BUNNY_SECRET_ACCESS_KEY']))"
```
Expected: `True` (and confirm `containers[0]` is the `app` container; if not, target the correct index).

- [ ] **Step 4: Commit**

```bash
git add bunny.json
git commit -m "chore(backup): declare backup env vars on the app container"
```

---

## Task 5: README — enable + restore docs

**Files:**
- Modify: `README.md` (add a "Backup" section)

**Interfaces:**
- Consumes: nothing.
- Produces: operator docs for enabling the backup and restoring.

- [ ] **Step 1: Add a Backup section**

Append this section to `README.md` (adjust heading level to match the file):

```markdown
## Backup (Bunny Storage)

Optional one-way backup of the database and media to a Bunny Storage zone via
rclone. Disabled by default; enable it by setting env vars on the `app`
container (Magic Containers dashboard or `bunny.json`):

| Variable | Purpose |
|---|---|
| `BACKUP_ENABLED` | `true` turns the backup on |
| `BACKUP_BEFORE_MIGRATE` | full backup before every migration (default `true`) |
| `BACKUP_SCHEDULE` | cron expression for the periodic run (default `0 3 * * *`, container time / UTC) |
| `BACKUP_RETENTION` | number of DB dumps to keep (default `7`) |
| `BACKUP_KEEP_DELETED` | keep deleted/overwritten media under `_deleted/` (default `true`) |
| `BACKUP_BUCKET` | Bunny Storage zone / bucket name |
| `RCLONE_CONFIG_BUNNY_TYPE` | `s3` (default) or `sftp` |
| `RCLONE_CONFIG_BUNNY_PROVIDER` | `Other` for Bunny S3 |
| `RCLONE_CONFIG_BUNNY_ENDPOINT` | `https://<region>-s3.storage.bunnycdn.com` |
| `RCLONE_CONFIG_BUNNY_ACCESS_KEY_ID` | storage zone name |
| `RCLONE_CONFIG_BUNNY_SECRET_ACCESS_KEY` | storage password |

What is backed up: the MariaDB database (`db/sulu-<ts>.sql.gz`), media originals
(`var/storage` → `storage/`) and generated image formats (`public/uploads` →
`uploads/`). The Loupe search index (`var/indexes`) is not backed up — it is
rebuilt from the database and media.

Bunny's S3-compatible API is currently in closed preview and must be enabled on
the storage zone. Without S3 access, set `RCLONE_CONFIG_BUNNY_TYPE=sftp` and the
matching SFTP host/user/key vars instead — the backup logic is unchanged.

### Restore

1. Media: `rclone sync bunny:<bucket>/storage "$APP_DATA_DIR/storage"` and the
   same for `uploads`.
2. Database: `rclone copy bunny:<bucket>/db/sulu-<ts>.sql.gz .` then
   `gunzip -c sulu-<ts>.sql.gz | mariadb -h 127.0.0.1 -u sulu -psulu sulu`.
3. Rebuild the search index: `bin/adminconsole cmsig:seal:reindex`.
```

- [ ] **Step 2: Verify the section renders**

Run: `grep -n "## Backup (Bunny Storage)" README.md`
Expected: one match.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(backup): document Bunny Storage backup and restore"
```

---

## Task 6: Manual end-to-end verification (enabled path)

**Files:** none (verification only). Requires a real Bunny Storage zone with S3 enabled and a local DB.

**Interfaces:**
- Consumes: the built image + a `bunny:` remote reachable with real credentials.
- Produces: confirmation that dumps and media land in the zone and that the pre-deploy backup fires before migrations.

- [ ] **Step 1: Run a one-off backup against the real zone**

With a MariaDB reachable at `127.0.0.1:3306` and the app tree present, run inside the container:
```bash
docker run --rm --network host \
  -e BACKUP_ENABLED=true -e BACKUP_BUCKET=<zone> \
  -e DATABASE_URL='mysql://sulu:sulu@127.0.0.1:3306/sulu' \
  -e RCLONE_CONFIG_BUNNY_TYPE=s3 -e RCLONE_CONFIG_BUNNY_PROVIDER=Other \
  -e RCLONE_CONFIG_BUNNY_ENDPOINT='https://<region>-s3.storage.bunnycdn.com' \
  -e RCLONE_CONFIG_BUNNY_ACCESS_KEY_ID='<zone>' \
  -e RCLONE_CONFIG_BUNNY_SECRET_ACCESS_KEY='<password>' \
  --entrypoint backup sulu-mc-test
```
Expected: log lines for dump upload and media sync; no errors.

- [ ] **Step 2: Confirm objects exist in the zone**

Run (with the same rclone env, or a local rclone remote):
```bash
rclone lsf bunny:<zone>/db/ && rclone lsf bunny:<zone>/storage/
```
Expected: a `sulu-<ts>.sql.gz` under `db/` and the media objects under `storage/`.

- [ ] **Step 3: Confirm crond is running when enabled**

Bring the stack up with `BACKUP_ENABLED=true` and the credentials set, then:
```bash
docker compose exec -T app sh -c 'crontab -l; ps -o pid,comm | grep crond'
```
Expected: the crontab shows the schedule line and a `crond` process is present.

- [ ] **Step 4: Confirm the pre-deploy backup fired before migrations**

Inspect the startup logs of an enabled container that already had a populated DB:
```bash
docker compose logs app | grep -n -e "pre-deploy backup" -e "Running database migrations"
```
Expected: `Running pre-deploy backup before migrations...` appears **before** `Running database migrations...`.

- [ ] **Step 5: Flip the spec status**

Edit `docs/superpowers/specs/2026-07-17-bunny-storage-backup-design.md`: change `**Status:** Approved (pending spec review)` to `**Status:** Implemented`.

```bash
git add docs/superpowers/specs/2026-07-17-bunny-storage-backup-design.md
git commit -m "docs(backup): mark design as implemented"
```

---

## Notes for the implementer

- **POSIX sh only** — no bashisms (no `[[ ]]`, no arrays). Build variadic rclone args with `set --` as shown.
- **Never** make backup failures fatal. `backup.sh` exits 0 always; the entrypoint calls it with `|| true`.
- The pre-deploy backup runs **synchronously** and blocks the deploy until it finishes — that is intended (the snapshot must exist before migrations).
- If the DB-container index in `bunny.json` is not `containers[0]`, adjust Task 4's verification index accordingly (app is `containers[0]` in the current file).
- Bunny S3 is preview; if a run fails auth, re-check that S3 compatibility is enabled on the zone and the endpoint region is correct.
