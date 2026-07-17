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
