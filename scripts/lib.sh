# shellcheck shell=bash
# shared helpers for the scripts in this folder.
# this file gets sourced, not run:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# so no shebang and no set -euo pipefail here, the script that sources it decides that.
# a set here would silently change the settings of whatever script sourced it

# the project root is one level up from this file. BASH_SOURCE[0] is this file even
# when it's sourced, so this works no matter where the script was started from
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# scripts set this to 1 when they get --yes, so ci can run them without prompts
ASSUME_YES="${ASSUME_YES:-0}"

# colours only when printing to a real terminal. piped into a file or shown in ci
# they turn into junk like ^[[31m. NO_COLOR is a convention for turning them off.
# decided once here, not inside the functions, because inside $(...) stdout is
# always a pipe so the terminal check would always say no
_BLUE="" _YELLOW="" _RED="" _RESET_OUT="" _RESET_ERR=""
if [ -z "${NO_COLOR:-}" ]; then
  if [ -t 1 ]; then _BLUE=$'\033[1;34m' _RESET_OUT=$'\033[0m'; fi
  if [ -t 2 ]; then _YELLOW=$'\033[1;33m' _RED=$'\033[1;31m' _RESET_ERR=$'\033[0m'; fi
fi

# the name: line in docker-compose.yml. read from the file so its only written in one place
compose_project_name() {
  sed -n 's/^name: *//p' "$PROJECT_ROOT/docker-compose.yml"
}

# true if any container of this stack is running. uses the label compose puts on
# every container instead of `docker compose ps`, because that one needs .env to
# exist and fails before install has created it
stack_is_running() {
  [ -n "$(docker ps -q --filter "label=com.docker.compose.project=$(compose_project_name)")" ]
}

# env_value <name> <default> -> the setting from .env, or the default if its not set
# (or if theres no .env yet)
env_value() {
  local value=""
  if [ -f "$PROJECT_ROOT/.env" ]; then
    value="$(sed -n "s/^$1=//p" "$PROJECT_ROOT/.env" | tail -n 1)"
  fi
  echo "${value:-$2}"
}

cd_project_root() {
  cd "$PROJECT_ROOT" || die "couldn't cd to $PROJECT_ROOT"
}

info() {
  printf '%s==>%s %s\n' "$_BLUE" "$_RESET_OUT" "$*"
}

# warnings and errors go to stderr so they still show up when stdout is redirected
warn() {
  printf '%swarning:%s %s\n' "$_YELLOW" "$_RESET_ERR" "$*" >&2
}

# exit and not return, so the whole script stops, not just this function
die() {
  printf '%serror:%s %s\n' "$_RED" "$_RESET_ERR" "$*" >&2
  exit 1
}

# require_cmd <command> [how to install it]
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not installed. ${2:-}"
}

# confirm "question?" -> returns 0 for yes, 1 for anything else.
# default is no, so just pressing enter never does something destructive.
# if theres no terminal to ask (ci, piped input) read fails and that counts as no
confirm() {
  local answer=""
  if [ "$ASSUME_YES" = 1 ]; then
    return 0
  fi
  read -r -p "$1 [y/N] " answer || true
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------------------------------------------------------------------------
# health check, used by install.sh and update.sh
# "the containers started" isnt the same as "it works", so wait until each piece
# actually answers. bottom up, same order as the troubleshooting in the readme
# ---------------------------------------------------------------------------

# wait_for <message when ready> <timeout in seconds> <command...>
wait_for() {
  local what="$1" timeout="$2" waited=0
  shift 2
  until "$@" >/dev/null 2>&1; do
    if [ "$waited" -ge "$timeout" ]; then
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  info "$what"
}

# both prometheus targets have to say up. prometheus only scrapes every 15s, so
# right after starting this can take a little while
targets_up() {
  local targets
  targets="$(curl -sf 'http://127.0.0.1:9090/api/v1/targets?state=active')" || return 1
  [ "$(grep -o '"health":"up"' <<<"$targets" | wc -l)" -ge 2 ]
}

# returns 1 (with a warning saying which piece and how to look into it) instead of
# dying, so the caller decides what happens next. update.sh prints how to roll back
check_health() {
  local port
  port="$(env_value GRAFANA_PORT 3000)"
  wait_for "node exporter is collecting metrics" 60 curl -sf http://127.0.0.1:9100/metrics || {
    warn "node exporter isnt answering. see what went wrong with: docker compose logs node-exporter"
    return 1
  }
  wait_for "prometheus is up" 60 curl -sf http://127.0.0.1:9090/-/ready || {
    warn "prometheus isnt answering. see what went wrong with: docker compose logs prometheus"
    return 1
  }
  wait_for "prometheus is collecting from node exporter" 60 targets_up || {
    warn "prometheus is up but isnt collecting. check http://127.0.0.1:9090/targets"
    return 1
  }
  wait_for "grafana is up" 90 curl -sf "http://127.0.0.1:$port/api/health" || {
    warn "grafana isnt answering. see what went wrong with: docker compose logs grafana"
    return 1
  }
}
