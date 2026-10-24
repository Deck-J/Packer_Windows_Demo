#!/usr/bin/env bash
# Phase banners for the GitHub Actions log and the run summary.
#
# The pipeline is long, and a wall of Cloud Build output hides the only question anyone asks: which phase are
# we in, and did it pass? Every phase prints a banner when it starts and a one-line verdict when it ends, and
# the verdict row is appended to the job summary so the run page shows the whole sequence at the end.
#
#   scripts/phase.sh start 2 "Build builder — building application"
#   scripts/phase.sh ok    2 "Build builder" 47m12s
#   scripts/phase.sh fail  2 "Build builder" 12m03s "Cloud Build ended FAILURE"
#   scripts/phase.sh milestone 3 "Build succeeded"
#
# Deliberately a shell script, not an action: it has to work identically in the bootstrap workflow, the
# pipeline, and a laptop.
set -uo pipefail

summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
line() { printf '════ PHASE %s — %s ════\n' "$1" "$2"; }

ensure_table() {
  if ! grep -q '^| phase | result | time |' "$summary" 2>/dev/null; then
    {
      echo ""
      echo "| phase | result | time | note |"
      echo "|---|---|---|---|"
    } >> "$summary"
  fi
}

cmd="${1:?usage: phase.sh <start|ok|fail|milestone|end> ...}"; shift
case "$cmd" in
  start)
    n="${1:?}"; title="${2:?}"
    echo "::group::$(line "$n" "$title")"
    echo "$(line "$n" "$title")"
    echo "[$(date -u +%H:%M:%SZ)] starting phase $n: $title"
    ;;
  end)
    echo "::endgroup::"
    ;;
  ok)
    n="${1:?}"; title="${2:?}"; dur="${3:-}"
    echo "::notice title=phase $n complete::✅ $title ${dur}"
    echo "✅ phase $n complete: $title ${dur}"
    ensure_table; echo "| $n — $title | ✅ passed | ${dur:--} | |" >> "$summary"
    ;;
  fail)
    n="${1:?}"; title="${2:?}"; dur="${3:-}"; why="${4:-}"
    echo "::error title=phase $n failed::❌ $title ${dur} ${why}"
    echo "❌ phase $n failed: $title ${dur} ${why}"
    ensure_table; echo "| $n — $title | ❌ failed | ${dur:--} | ${why} |" >> "$summary"
    ;;
  milestone)
    n="${1:?}"; title="${2:?}"
    echo "::notice title=phase $n::🔹 $title"
    echo "🔹 $title"
    ensure_table; echo "| $n — $title | ✅ done | - | |" >> "$summary"
    ;;
  *)
    echo "phase.sh: unknown command '$cmd'" >&2; exit 2 ;;
esac
