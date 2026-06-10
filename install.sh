#!/usr/bin/env bash
# engsight installer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGSIGHT_DIR="${HOME}/.engsight"

echo "Installing engsight..."

# Create directory structure
mkdir -p "${ENGSIGHT_DIR}/templates/hooks"

# Copy config (don't overwrite existing)
if [[ ! -f "${ENGSIGHT_DIR}/config" ]]; then
  cp "${SCRIPT_DIR}/config.default" "${ENGSIGHT_DIR}/config"
  echo "  Created ${ENGSIGHT_DIR}/config"
else
  echo "  Config already exists at ${ENGSIGHT_DIR}/config (skipped)"
fi

# Copy common.sh
cp "${SCRIPT_DIR}/common.sh" "${ENGSIGHT_DIR}/common.sh"
echo "  Installed common.sh"

# Initialize database
if [[ ! -f "${ENGSIGHT_DIR}/engsight.db" ]]; then
  sqlite3 "${ENGSIGHT_DIR}/engsight.db" < "${SCRIPT_DIR}/schema.sql"
  echo "  Created database at ${ENGSIGHT_DIR}/engsight.db"
else
  echo "  Database already exists (skipped)"
fi

# Copy hooks to templates
for hook in "${SCRIPT_DIR}"/hooks/*; do
  hook_name="$(basename "$hook")"
  cp "$hook" "${ENGSIGHT_DIR}/templates/hooks/${hook_name}"
  chmod +x "${ENGSIGHT_DIR}/templates/hooks/${hook_name}"
done
echo "  Installed hooks to ${ENGSIGHT_DIR}/templates/hooks/"

# Copy engsight CLI
cp "${SCRIPT_DIR}/engsight" "${ENGSIGHT_DIR}/engsight"
chmod +x "${ENGSIGHT_DIR}/engsight"

# --- Handle core.hooksPath (the footgun) ---
# If core.hooksPath is set, Git ignores .git/hooks/ entirely.
# We need to install engsight hooks there too, chaining to any existing hooks.
hooks_path="$(git config --global core.hooksPath 2>/dev/null || echo "")"
if [[ -n "$hooks_path" ]]; then
  # Expand ~ if present
  hooks_path="${hooks_path/#\~/$HOME}"
  echo ""
  echo "  NOTICE: core.hooksPath is set to: ${hooks_path}"
  echo "  Git ignores .git/hooks/ when this is set (the global hooks footgun)."
  echo "  Installing engsight hooks there too, chaining to any existing hooks."
  echo ""

  mkdir -p "$hooks_path"
  for hook in "${SCRIPT_DIR}"/hooks/*; do
    hook_name="$(basename "$hook")"
    hook_dest="${hooks_path}/${hook_name}"

    # If an existing hook is there and isn't engsight, rename it
    if [[ -f "$hook_dest" ]]; then
      if ! grep -q "engsight" "$hook_dest" 2>/dev/null; then
        mv "$hook_dest" "${hook_dest}.local"
        echo "  Renamed existing ${hook_name} -> ${hook_name}.local in hooksPath"
      else
        echo "  ${hook_name} already installed in hooksPath (skipped)"
        continue
      fi
    fi

    cp "$hook" "$hook_dest"
    chmod +x "$hook_dest"
    echo "  Installed ${hook_name} to hooksPath"
  done
fi

# Set init.templateDir for new repos
current_template="$(git config --global init.templateDir 2>/dev/null || echo "")"
if [[ -n "$current_template" && "$current_template" != "${ENGSIGHT_DIR}/templates" ]]; then
  echo ""
  echo "  WARNING: init.templateDir is already set to: ${current_template}"
  echo "  engsight wants to set it to: ${ENGSIGHT_DIR}/templates"
  echo ""
  read -rp "  Overwrite? (y/N) " answer
  if [[ "$answer" != [yY] ]]; then
    echo "  Skipped setting init.templateDir. You can set it manually:"
    echo "    git config --global init.templateDir ${ENGSIGHT_DIR}/templates"
    echo ""
    echo "Done! Run 'engsight init' inside existing repos to add hooks."
    exit 0
  fi
fi

git config --global init.templateDir "${ENGSIGHT_DIR}/templates"
echo "  Set init.templateDir to ${ENGSIGHT_DIR}/templates"

echo ""
echo "Done! New repos will get engsight hooks automatically."
echo "For existing repos, run: ~/.engsight/engsight init"
