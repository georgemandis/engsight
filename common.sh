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

engsight_process_snapshot() {
  if [[ "$ENGSIGHT_PROCESS_SNIFF" != "true" ]]; then
    printf '%s' '{"active_ai_tools":[]}'
    return
  fi

  local repo_root
  repo_root="$(engsight_repo_path)"
  local tools=""
  local first=true

  for proc_name in "${ENGSIGHT_PROCESS_NAMES[@]}"; do
    local pids
    pids="$(pgrep -x "$proc_name" 2>/dev/null)"
    if [[ -z "$pids" ]]; then
      # Try case-insensitive and partial match
      pids="$(pgrep -if "$proc_name" 2>/dev/null | head -5)"
    fi
    if [[ -z "$pids" ]]; then continue; fi

    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue

      local uptime_seconds="" cpu_percent="" memory_mb=""
      local open_files_json="[]" open_ports_json="[]"

      # ps info: elapsed time, CPU, RSS
      local ps_out
      ps_out="$(ps -p "$pid" -o etime=,pcpu=,rss= 2>/dev/null | head -1 | xargs)"
      if [[ -n "$ps_out" ]]; then
        local etime pcpu rss
        etime="$(echo "$ps_out" | awk '{print $1}')"
        pcpu="$(echo "$ps_out" | awk '{print $2}')"
        rss="$(echo "$ps_out" | awk '{print $3}')"

        # Convert etime to seconds (formats: MM:SS, HH:MM:SS, D-HH:MM:SS)
        # Use 10# prefix everywhere to avoid octal interpretation of zero-padded numbers
        uptime_seconds=0
        if [[ "$etime" == *-* ]]; then
          local days rest
          days="${etime%%-*}"
          rest="${etime##*-}"
          IFS=: read -r h m s <<< "$rest"
          uptime_seconds=$(( 10#${days:-0}*86400 + 10#${h:-0}*3600 + 10#${m:-0}*60 + 10#${s:-0} )) 2>/dev/null || uptime_seconds=0
        elif [[ "$(echo "$etime" | tr -cd ':' | wc -c | tr -d ' ')" -eq 2 ]]; then
          IFS=: read -r h m s <<< "$etime"
          uptime_seconds=$(( 10#${h:-0}*3600 + 10#${m:-0}*60 + 10#${s:-0} )) 2>/dev/null || uptime_seconds=0
        else
          IFS=: read -r m s <<< "$etime"
          uptime_seconds=$(( 10#${m:-0}*60 + 10#${s:-0} )) 2>/dev/null || uptime_seconds=0
        fi

        cpu_percent="$pcpu"
        if [[ -n "$rss" ]]; then
          memory_mb="$(( rss / 1024 ))"
        fi
      fi

      # lsof: open files in repo + network connections
      if [[ -n "$repo_root" ]]; then
        local repo_files
        repo_files="$(lsof -p "$pid" 2>/dev/null | grep "$repo_root" | awk '{print $NF}' | sort -u | head -20)"
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

      local net_conns
      net_conns="$(lsof -p "$pid" -i 2>/dev/null | grep -v "^COMMAND" | awk '{print $9}' | sort -u | head -10)"
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

      if [[ "$first" != "true" ]]; then tools+=","; fi
      tools+="{\"name\":\"${proc_name}\",\"pid\":${pid},\"uptime_seconds\":${uptime_seconds:-0},\"cpu_percent\":\"${cpu_percent:-0}\",\"memory_mb\":${memory_mb:-0},\"open_files_in_repo\":${open_files_json},\"open_ports\":${open_ports_json}}"
      first=false
    done <<< "$pids"
  done

  printf '{"active_ai_tools":[%s]}' "$tools"
}
