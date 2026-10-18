#!/usr/bin/env bash
# Usage: run.sh <log-name> <cwd> <cmd...>  — raw receipt log, never overwritten.
set -u
ws=/home/siliconfamiliar_ismattkelleraliv/.rusa/workers/0e21b069-8234-4534-ba54-f201fff22d55
name=$1; cwd=$2; shift 2
log="$ws/evidence-223/$name.log"
[ -e "$log" ] && { echo "refusing to overwrite $log" >&2; exit 65; }
export PATH="$ws/toolchains/flutter-3.38.4/bin:$PATH"
{
  echo "# cmd: $*"
  echo "# cwd: $cwd"
  echo "# started_utc: $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  echo "# git_head: $(git -C "$cwd" rev-parse HEAD 2>/dev/null) dirty_lines=$(git -C "$cwd" status --porcelain=v1 2>/dev/null | wc -l)"
  echo "# dart: $(dart --version 2>&1)"
  echo "# ---"
} > "$log"
( cd "$cwd" && "$@" ) >> "$log" 2>&1
rc=$?
{ echo "# ---"; echo "# ended_utc: $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"; echo "# exit: $rc"; } >> "$log"
echo "$name exit=$rc sha256=$(sha256sum "$log" | cut -d' ' -f1)"
exit $rc
