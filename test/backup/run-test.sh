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
case " $* " in
  *" lsf "*db/*) printf 'sulu-2026010%s-000000.sql.gz\n' 1 2 3 4 5 6 7 8 9 ;;
esac
exit 0
EOF
cat > "$bindir/mariadb-dump" <<'EOF'
#!/bin/sh
echo "mariadb-dump $* PWD=${MYSQL_PWD:-}" >> "$CALLS"
[ "${STUB_MARIADB_FAIL:-}" = "1" ] && exit 1
echo "-- fake dump"
exit 0
EOF
chmod +x "$bindir/rclone" "$bindir/mariadb-dump"
export PATH="$bindir:$PATH"

fail() { echo "FAIL: $1"; echo "--- calls ---"; cat "$CALLS"; echo "--- out ---"; cat "$work/out.log" 2>/dev/null; exit 1; }
assert_grep() { grep -q -- "$1" "$CALLS" || fail "expected call matching: $1"; }
assert_absent() { ! grep -q -- "$1" "$CALLS" || fail "unexpected call matching: $1"; }
assert_out() { grep -q -- "$1" "$work/out.log" || fail "expected log matching: $1"; }

# --- fixture: a fake app tree with media dirs ------------------------------
mkdir -p "$work/app/var/storage" "$work/app/public/uploads" "$work/app/cache"
echo x > "$work/app/var/storage/orig.jpg"
export APP_ROOT="$work/app"
export APP_CACHE_DIR="$work/app/cache"
export DATABASE_URL="mysql://sulu:s3cr3t@db-host:3307/suludb?serverVersion=10.11.14-MariaDB"
export BACKUP_BUCKET="mybucket"

run() {
    : > "$CALLS"
    if ( sh /repo/docker/backup.sh ) >"$work/out.log" 2>&1; then RC=0; else RC=$?; fi
}

# Case A: disabled -> no rclone/mariadb calls, clean exit
unset BACKUP_ENABLED 2>/dev/null || true
run
[ "$RC" -eq 0 ] || fail "disabled path must exit 0 (got $RC)"
assert_absent "rclone"
assert_absent "mariadb-dump"
echo "PASS: disabled -> no backup calls, exit 0"

# Case B: enabled -> dump, upload, media sync, keep-deleted backup-dir
export BACKUP_ENABLED=true
export BACKUP_KEEP_DELETED=true
export BACKUP_RETENTION=7
run
[ "$RC" -eq 0 ] || fail "enabled happy path must exit 0 (got $RC)"
assert_grep "mariadb-dump"
assert_grep "PWD=s3cr3t"
assert_grep "-h db-host"
assert_grep "-P 3307"
assert_grep "suludb"
assert_grep "copy.*bunny:mybucket/db/"
assert_grep "contimeout 30s"
assert_grep "bunny:mybucket/db/"
assert_grep "sync -L"
assert_grep "bunny:mybucket/storage"
assert_grep "bunny:mybucket/uploads"
assert_grep "backup-dir bunny:mybucket/_deleted/"
echo "PASS: enabled -> full backup call sequence, exit 0"

# Case C: retention -> 9 remote dumps, keep 7 -> prune 2 oldest
grep -q "deletefile bunny:mybucket/db/sulu-20260101-000000.sql.gz" "$CALLS" \
  || fail "expected pruning of oldest dump"
grep -q "deletefile bunny:mybucket/db/sulu-20260102-000000.sql.gz" "$CALLS" \
  || fail "expected pruning of 2nd-oldest dump"
assert_absent "deletefile bunny:mybucket/db/sulu-20260103-000000.sql.gz"
echo "PASS: retention prunes oldest beyond BACKUP_RETENTION"

# Case D: keep-deleted off -> no backup-dir flag
export BACKUP_KEEP_DELETED=false
run
assert_grep "sync -L"
assert_absent "backup-dir"
echo "PASS: keep-deleted off -> no --backup-dir"
export BACKUP_KEEP_DELETED=true

# Case E: dump failure -> never aborts, logs failure, uploads nothing
export STUB_MARIADB_FAIL=1
run
[ "$RC" -eq 0 ] || fail "dump-failure path must still exit 0 (got $RC)"
assert_grep "mariadb-dump"
assert_absent "copy bunny:mybucket/db/"
assert_out "mariadb-dump failed"
unset STUB_MARIADB_FAIL
echo "PASS: dump failure -> exit 0, logged, no upload"

echo "ALL BACKUP TESTS PASSED"
