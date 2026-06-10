#!/usr/bin/env bash
# engsight common functions — sourced by all hook scripts
# shellcheck disable=SC1090

ENGSIGHT_DIR="${ENGSIGHT_DIR:-$HOME/.engsight}"
ENGSIGHT_CONFIG="${ENGSIGHT_DIR}/config"

# --- Config ---

engsight_load_config() {
  if [[ -f "$ENGSIGHT_CONFIG" ]]; then
    source "$ENGSIGHT_CONFIG"
  else
    # Fallback defaults
    ENGSIGHT_DB="${ENGSIGHT_DIR}/engsight.db"
    ENGSIGHT_EXCLUDE_REPOS=()
    ENGSIGHT_PROCESS_SNIFF=false
    ENGSIGHT_CAPTURE_TERMINAL=true
    ENGSIGHT_CAPTURE_WORKDIR_STATE=true
    ENGSIGHT_TAG_TIME_CONTEXT=true
    ENGSIGHT_AI_ARTIFACTS=()
    ENGSIGHT_AI_COMMIT_PATTERNS=()
    ENGSIGHT_PROCESS_NAMES=()
  fi
}

# --- Repo Identification ---

engsight_repo_path() {
  git rev-parse --show-toplevel 2>/dev/null
}

engsight_repo_name() {
  basename "$(engsight_repo_path)" 2>/dev/null
}

engsight_current_branch() {
  git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null
}

engsight_current_author() {
  git config user.name 2>/dev/null
}

# --- Exclusion Check ---

engsight_check_excluded() {
  local repo_path
  repo_path="$(engsight_repo_path)"
  for excluded in "${ENGSIGHT_EXCLUDE_REPOS[@]}"; do
    if [[ "$repo_path" == "$excluded" ]]; then
      return 1
    fi
  done
  return 0
}

# --- SQLite Logging ---

engsight_log() {
  local event_type="$1"
  local payload="$2"
  local ts repo_path repo_name branch author

  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  repo_path="$(engsight_repo_path)"
  repo_name="$(engsight_repo_name)"
  branch="$(engsight_current_branch)"
  author="$(engsight_current_author)"

  sqlite3 "$ENGSIGHT_DB" "INSERT INTO events (timestamp, event_type, repo_path, repo_name, branch, author, payload) VALUES ('${ts}', '${event_type}', '${repo_path}', '${repo_name}', '${branch}', '${author}', json('${payload}'));" 2>/dev/null
}

# --- Time Since Last Event ---

engsight_time_since_last() {
  local event_type="$1"
  local scope="$2"  # "repo" or "global"
  local last_ts query

  if [[ "$scope" == "repo" ]]; then
    local repo_path
    repo_path="$(engsight_repo_path)"
    query="SELECT timestamp FROM events WHERE event_type='${event_type}' AND repo_path='${repo_path}' ORDER BY timestamp DESC LIMIT 1;"
  else
    query="SELECT timestamp FROM events WHERE event_type='${event_type}' ORDER BY timestamp DESC LIMIT 1;"
  fi

  last_ts="$(sqlite3 "$ENGSIGHT_DB" "$query" 2>/dev/null)"

  if [[ -z "$last_ts" ]]; then
    echo "-1"
    return
  fi

  local last_epoch now_epoch
  # macOS date
  if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" "+%s" &>/dev/null; then
    last_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" "+%s")"
  else
    # GNU date
    last_epoch="$(date -d "$last_ts" "+%s" 2>/dev/null)"
  fi
  now_epoch="$(date -u "+%s")"

  if [[ -n "$last_epoch" && -n "$now_epoch" ]]; then
    echo $(( now_epoch - last_epoch ))
  else
    echo "-1"
  fi
}

# --- Local Hook Chaining ---

engsight_chain_local() {
  local hook_name="$1"
  shift
  local git_dir
  git_dir="$(git rev-parse --git-dir 2>/dev/null)"
  local local_hook="${git_dir}/hooks/${hook_name}.local"

  if [[ -x "$local_hook" ]]; then
    exec "$local_hook" "$@"
  fi
}

# --- JSON Helpers ---

# Escape a string for safe embedding in JSON
engsight_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# --- Terminal Context ---

engsight_terminal_context() {
  if [[ "$ENGSIGHT_CAPTURE_TERMINAL" == "true" ]]; then
    printf '%s' "${TERM_PROGRAM:-unknown}"
  else
    printf '%s' ""
  fi
}

# --- Working Directory State ---

engsight_workdir_state() {
  if [[ "$ENGSIGHT_CAPTURE_WORKDIR_STATE" != "true" ]]; then
    printf '%s' '{"untracked_count":0,"stash_depth":0}'
    return
  fi
  local untracked stash_depth
  untracked="$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')"
  stash_depth="$(git stash list 2>/dev/null | wc -l | tr -d ' ')"
  printf '{"untracked_count":%d,"stash_depth":%d}' "$untracked" "$stash_depth"
}

# --- Time Context ---

engsight_time_context() {
  if [[ "$ENGSIGHT_TAG_TIME_CONTEXT" != "true" ]]; then
    printf '%s' '{}'
    return
  fi
  local hour day_of_week day_num is_weekend
  hour="$(date +"%H")"
  day_of_week="$(date +"%A")"
  day_num="$(date +"%u")"  # 1=Monday, 7=Sunday
  if [[ "$day_num" -ge 6 ]]; then
    is_weekend="true"
  else
    is_weekend="false"
  fi
  printf '{"hour":%d,"day_of_week":"%s","is_weekend":%s}' "$((10#$hour))" "$day_of_week" "$is_weekend"
}

# --- AI Artifact Scanning ---

engsight_scan_ai_artifacts() {
  local repo_root
  repo_root="$(engsight_repo_path)"
  if [[ -z "$repo_root" ]]; then
    printf '%s' '{}'
    return
  fi

  local result="{"
  local first=true

  for artifact in "${ENGSIGHT_AI_ARTIFACTS[@]}"; do
    local path="${repo_root}/${artifact}"
    local key
    key="$(engsight_json_escape "$artifact")"

    if [[ -e "$path" ]]; then
      local file_count=0 total_size=0
      if [[ -d "$path" ]]; then
        file_count="$(find "$path" -type f 2>/dev/null | wc -l | tr -d ' ')"
        total_size="$(find "$path" -type f -exec stat -f%z {} + 2>/dev/null | awk '{s+=$1}END{print s+0}' || find "$path" -type f -exec stat --printf="%s\n" {} + 2>/dev/null | awk '{s+=$1}END{print s+0}')"
      else
        file_count=1
        # macOS stat
        total_size="$(stat -f%z "$path" 2>/dev/null || stat --printf="%s" "$path" 2>/dev/null)"
      fi
      if [[ "$first" != "true" ]]; then result+=","; fi
      result+="\"${key}\":{\"exists\":true,\"file_count\":${file_count:-0},\"total_size_bytes\":${total_size:-0}}"
      first=false
    fi
  done

  result+="}"
  printf '%s' "$result"
}

# --- AI Commit Signal Detection ---

engsight_scan_ai_commit_signals() {
  local message="$1"
  local co_authors=""
  local pattern_matches=""
  local ca_first=true
  local pm_first=true

  # Extract Co-authored-by lines
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      local name
      name="$(echo "$line" | sed 's/Co-authored-by: *//;s/ <.*//')"
      if [[ "$ca_first" != "true" ]]; then co_authors+=","; fi
      co_authors+="\"$(engsight_json_escape "$name")\""
      ca_first=false
    fi
  done <<< "$(echo "$message" | grep -i "Co-authored-by:" 2>/dev/null)"

  # Check patterns
  for pattern in "${ENGSIGHT_AI_COMMIT_PATTERNS[@]}"; do
    if echo "$message" | grep -qiE "$pattern" 2>/dev/null; then
      if [[ "$pm_first" != "true" ]]; then pattern_matches+=","; fi
      pattern_matches+="\"$(engsight_json_escape "$pattern")\""
      pm_first=false
    fi
  done

  printf '{"co_authored_by":[%s],"pattern_matches":[%s]}' "$co_authors" "$pattern_matches"
}

# --- Process Sniffing ---
#
# Three tiers:
#   ENGSIGHT_PROCESS_SNIFF=false  — disabled (default)
#   ENGSIGHT_PROCESS_SNIFF=true   — Tier 1+2: detect presence + ps stats (~50ms)
#   ENGSIGHT_PROCESS_SNIFF=deep   — Tier 3: adds lsof for open files + network (~200ms)

# Convert elapsed time string to seconds
# Formats: MM:SS, HH:MM:SS, D-HH:MM:SS
_engsight_etime_to_seconds() {
  local etime="$1"
  local seconds=0
  if [[ "$etime" == *-* ]]; then
    local days="${etime%%-*}" rest="${etime##*-}"
    IFS=: read -r h m s <<< "$rest"
    seconds=$(( 10#${days:-0}*86400 + 10#${h:-0}*3600 + 10#${m:-0}*60 + 10#${s:-0} )) 2>/dev/null || seconds=0
  elif [[ "$(echo "$etime" | tr -cd ':' | wc -c | tr -d ' ')" -eq 2 ]]; then
    IFS=: read -r h m s <<< "$etime"
    seconds=$(( 10#${h:-0}*3600 + 10#${m:-0}*60 + 10#${s:-0} )) 2>/dev/null || seconds=0
  else
    IFS=: read -r m s <<< "$etime"
    seconds=$(( 10#${m:-0}*60 + 10#${s:-0} )) 2>/dev/null || seconds=0
  fi
  echo "$seconds"
}

engsight_process_snapshot() {
  if [[ "$ENGSIGHT_PROCESS_SNIFF" != "true" && "$ENGSIGHT_PROCESS_SNIFF" != "deep" ]]; then
    printf '%s' '{"active_ai_tools":[]}'
    return
  fi

  local repo_root
  repo_root="$(engsight_repo_path)"
  local tools=""
  local first=true

  for proc_name in "${ENGSIGHT_PROCESS_NAMES[@]}"; do
    # Tier 1: exact match only — no fuzzy fallback
    local pids
    pids="$(pgrep -x "$proc_name" 2>/dev/null)"
    if [[ -z "$pids" ]]; then continue; fi

    local instance_count
    instance_count="$(echo "$pids" | wc -l | tr -d ' ')"
    local pid_list
    pid_list="$(echo "$pids" | paste -sd',' -)"

    # Tier 2: ps stats for all PIDs at once
    local total_cpu=0 total_mem_kb=0 max_uptime=0
    while IFS= read -r ps_line; do
      [[ -z "$ps_line" ]] && continue
      local pid etime pcpu rss
      pid="$(echo "$ps_line" | awk '{print $1}')"
      etime="$(echo "$ps_line" | awk '{print $2}')"
      pcpu="$(echo "$ps_line" | awk '{print $3}')"
      rss="$(echo "$ps_line" | awk '{print $4}')"

      local up
      up="$(_engsight_etime_to_seconds "$etime")"
      if [[ "$up" -gt "$max_uptime" ]]; then max_uptime="$up"; fi

      # Accumulate CPU (awk for float addition)
      total_cpu="$(awk "BEGIN { printf \"%.1f\", ${total_cpu} + ${pcpu:-0} }")"
      total_mem_kb=$(( total_mem_kb + ${rss:-0} ))
    done < <(ps -p "$pid_list" -o pid=,etime=,pcpu=,rss= 2>/dev/null)

    local total_mem_mb=$(( total_mem_kb / 1024 ))

    # Build the tool JSON
    local tool_json="{\"name\":\"${proc_name}\",\"instances\":${instance_count},\"max_uptime_seconds\":${max_uptime},\"total_cpu_percent\":\"${total_cpu}\",\"total_memory_mb\":${total_mem_mb}"

    # Tier 3: lsof for open files in repo + network (only in deep mode)
    if [[ "$ENGSIGHT_PROCESS_SNIFF" == "deep" ]]; then
      local lsof_output
      lsof_output="$(lsof -p "$pid_list" 2>/dev/null)"

      # Files open in this repo
      local open_files_json="[]"
      if [[ -n "$repo_root" && -n "$lsof_output" ]]; then
        local repo_files
        repo_files="$(echo "$lsof_output" | grep "$repo_root" | awk '{print $NF}' | sort -u | head -20)"
        if [[ -n "$repo_files" ]]; then
          open_files_json="["
          local ff=true
          while IFS= read -r f; do
            local rel="${f#${repo_root}/}"
            if [[ "$ff" != "true" ]]; then open_files_json+=","; fi
            open_files_json+="\"$(engsight_json_escape "$rel")\""
            ff=false
          done <<< "$repo_files"
          open_files_json+="]"
        fi
      fi

      # Network connections
      local open_ports_json="[]"
      if [[ -n "$lsof_output" ]]; then
        local net_conns
        net_conns="$(echo "$lsof_output" | awk '$5 ~ /IPv[46]/ {print $9}' | sort -u | head -10)"
        if [[ -n "$net_conns" ]]; then
          open_ports_json="["
          local pf=true
          while IFS= read -r conn; do
            if [[ "$pf" != "true" ]]; then open_ports_json+=","; fi
            open_ports_json+="\"$(engsight_json_escape "$conn")\""
            pf=false
          done <<< "$net_conns"
          open_ports_json+="]"
        fi
      fi

      tool_json+=",\"open_files_in_repo\":${open_files_json},\"open_ports\":${open_ports_json}"
    fi

    tool_json+="}"

    if [[ "$first" != "true" ]]; then tools+=","; fi
    tools+="$tool_json"
    first=false
  done

  printf '{"active_ai_tools":[%s]}' "$tools"
}
