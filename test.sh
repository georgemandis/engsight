#!/usr/bin/env bash
# engsight end-to-end smoke test
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(mktemp -d)"
ENGSIGHT_BACKUP=""

echo "=== engsight smoke test ==="
echo "Test dir: ${TEST_DIR}"

# Backup existing engsight config if present
if [[ -d "${HOME}/.engsight" ]]; then
  ENGSIGHT_BACKUP="$(mktemp -d)"
  cp -r "${HOME}/.engsight" "${ENGSIGHT_BACKUP}/engsight-backup"
  echo "Backed up existing ~/.engsight to ${ENGSIGHT_BACKUP}"
fi

ORIGINAL_HOOKS_PATH="$(git config --global core.hooksPath 2>/dev/null || echo "")"
ORIGINAL_TEMPLATE_DIR="$(git config --global init.templateDir 2>/dev/null || echo "")"

cleanup() {
  # Restore backup if we made one
  if [[ -n "$ENGSIGHT_BACKUP" && -d "${ENGSIGHT_BACKUP}/engsight-backup" ]]; then
    rm -rf "${HOME}/.engsight"
    mv "${ENGSIGHT_BACKUP}/engsight-backup" "${HOME}/.engsight"
    echo "Restored ~/.engsight from backup"
    rmdir "$ENGSIGHT_BACKUP" 2>/dev/null || true
  else
    rm -rf "${HOME}/.engsight"
  fi
  # Restore original git global config
  if [[ -n "$ORIGINAL_HOOKS_PATH" ]]; then
    git config --global core.hooksPath "$ORIGINAL_HOOKS_PATH"
  else
    git config --global --unset core.hooksPath 2>/dev/null || true
  fi
  if [[ -n "$ORIGINAL_TEMPLATE_DIR" ]]; then
    git config --global init.templateDir "$ORIGINAL_TEMPLATE_DIR"
  else
    git config --global --unset init.templateDir 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
  echo "Cleaned up."
}
trap cleanup EXIT

# Clear core.hooksPath for a clean test environment
# (engsight's installer handles this in real installs, but for testing
# we want a controlled environment)
git config --global --unset core.hooksPath 2>/dev/null || true

# --- Install (clean) ---
echo ""
echo "--- Installing engsight ---"
rm -rf "${HOME}/.engsight"
echo "y" | bash "${SCRIPT_DIR}/install.sh"

# Process sniffing stays disabled (default) — lsof is too slow for tests

# --- Create test repo ---
echo ""
echo "--- Creating test repo ---"
cd "$TEST_DIR"
git init test-repo
cd test-repo
git config user.name "Test User"
git config user.email "test@example.com"

# Install hooks via engsight init
"${HOME}/.engsight/engsight" init

# --- Create some AI artifacts ---
mkdir -p .claude
echo '{"test": true}' > .claude/settings.json
echo "# Test CLAUDE.md" > CLAUDE.md

# --- Make a commit ---
echo ""
echo "--- Making first commit ---"
echo "hello world" > test.txt
git add test.txt
git commit -m "feat: initial commit

Co-authored-by: Claude <noreply@anthropic.com>"

# --- Check database ---
echo ""
echo "--- Checking database ---"
DB="${HOME}/.engsight/engsight.db"

pre_commit_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE event_type='pre_commit';")"
commit_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE event_type='commit';")"

echo "pre_commit events: ${pre_commit_count}"
echo "commit events: ${commit_count}"

# Verify payload content
echo ""
echo "--- Commit payload ---"
sqlite3 "$DB" "SELECT json_extract(payload, '$.sha') as sha, json_extract(payload, '$.files_changed') as files, json_extract(payload, '$.terminal') as terminal, json_extract(payload, '$.ai_commit_signals') as ai FROM events WHERE event_type='commit' LIMIT 1;"

echo ""
echo "--- AI artifacts in pre_commit ---"
sqlite3 "$DB" "SELECT json_extract(payload, '$.ai_artifacts') FROM events WHERE event_type='pre_commit' LIMIT 1;"

# --- Branch switch ---
echo ""
echo "--- Testing branch switch ---"
git checkout -b test-branch
checkout_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE event_type='checkout';")"
echo "checkout events: ${checkout_count}"

# --- Second commit ---
echo ""
echo "--- Second commit ---"
echo "more content" >> test.txt
git add test.txt
git commit -m "fix: update test file"

echo ""
echo "--- Time since last commit ---"
sqlite3 "$DB" "SELECT json_extract(payload, '$.time_since_last_commit_repo_seconds') as repo_delta, json_extract(payload, '$.time_since_last_commit_global_seconds') as global_delta FROM events WHERE event_type='commit' ORDER BY timestamp DESC LIMIT 1;"

# --- Amend ---
echo ""
echo "--- Testing amend ---"
git commit --amend --no-edit
rewrite_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE event_type='rewrite';")"
echo "rewrite events: ${rewrite_count}"

# --- Status ---
echo ""
echo "--- engsight status ---"
"${HOME}/.engsight/engsight" status

# --- Test init-all ---
echo ""
echo "--- Testing init-all ---"
cd "$TEST_DIR"
mkdir second-repo && cd second-repo && git init && git config user.name "Test" && git config user.email "t@t.com" && cd ..
mkdir third-repo && cd third-repo && git init && git config user.name "Test" && git config user.email "t@t.com" && cd ..
"${HOME}/.engsight/engsight" init-all "$TEST_DIR"

# --- Summary ---
echo ""
echo "--- All events ---"
sqlite3 "$DB" "SELECT id, timestamp, event_type, repo_name, branch FROM events ORDER BY id;"

# --- Assertions ---
echo ""
echo "--- Assertions ---"
FAILURES=0

assert_gt() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" -gt "$expected" ]]; then
    echo "  OK: ${label} (${actual})"
  else
    echo "  FAIL: ${label} — expected > ${expected}, got ${actual}"
    FAILURES=$(( FAILURES + 1 ))
  fi
}

total="$(sqlite3 "$DB" "SELECT COUNT(*) FROM events;")"
assert_gt "$total" 0 "total events recorded"
assert_gt "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE event_type='pre_commit';")" 0 "pre_commit events"
assert_gt "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE event_type='commit';")" 0 "commit events"
assert_gt "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE event_type='checkout';")" 0 "checkout events"
assert_gt "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE event_type='rewrite';")" 0 "rewrite events"

# Check AI signals were captured
ai_signal="$(sqlite3 "$DB" "SELECT json_extract(payload, '$.ai_commit_signals.co_authored_by') FROM events WHERE event_type='commit' LIMIT 1;")"
if [[ "$ai_signal" == *"Claude"* ]]; then
  echo "  OK: AI co-author detected"
else
  echo "  FAIL: AI co-author not detected (got: ${ai_signal})"
  FAILURES=$(( FAILURES + 1 ))
fi

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "=== PASS: ${total} events recorded, all assertions passed ==="
else
  echo "=== FAIL: ${FAILURES} assertion(s) failed ==="
  exit 1
fi
