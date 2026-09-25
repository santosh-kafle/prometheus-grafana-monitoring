#!/usr/bin/env bash
# stops and removes the monitoring stack.
# by default your metrics, grafana's database and .env are kept, so running
# install.sh again brings everything back exactly as it was.
# --remove-data deletes all of that for good.

set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd_project_root

usage() {
  cat <<EOF
usage: ./scripts/uninstall.sh [options]

stops and removes the monitoring containers. your data and settings are kept,
so ./scripts/install.sh brings everything back.

options:
  --remove-data  also delete all collected metrics, grafana's database and .env.
                 this cannot be undone
  -y, --yes      dont ask for confirmation (only matters with --remove-data)
  -h, --help     show this help
EOF
}

REMOVE_DATA=0
while [ $# -gt 0 ]; do
  case "$1" in
    --remove-data) REMOVE_DATA=1 ;;
    -y|--yes)      ASSUME_YES=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

require_cmd docker

project="$(compose_project_name)"
volumes=("${project}_prometheus_data" "${project}_grafana_data")

# compose reads docker-compose.yml even just to stop things, and that file says the
# password is required (:?). if .env is already gone that would fail before doing
# anything, so pass a dummy value. down never uses it
compose() {
  GF_SECURITY_ADMIN_PASSWORD="${GF_SECURITY_ADMIN_PASSWORD:-unused}" docker compose "$@"
}

if [ "$REMOVE_DATA" = 0 ]; then
  info "stopping and removing the containers"
  compose down
  echo
  info "uninstalled. your data and settings were kept:"
  for v in "${volumes[@]}"; do
    if docker volume inspect "$v" >/dev/null 2>&1; then
      echo "    docker volume  $v"
    fi
  done
  if [ -f .env ]; then
    echo "    settings file  $PROJECT_ROOT/.env"
  fi
  echo "    to bring it all back:  ./scripts/install.sh"
  echo "    to delete it for good: ./scripts/uninstall.sh --remove-data"
  exit 0
fi

# ---------------------------------------------------------------------------
# --remove-data
# the one thing in this project that cant be undone, so list exactly what goes
# and make the user type a word. a plain y is too easy to hit out of habit
# ---------------------------------------------------------------------------

# collect what exists first, so the warning only shows up if theres something to lose
to_delete=()
for v in "${volumes[@]}"; do
  if docker volume inspect "$v" >/dev/null 2>&1; then
    to_delete+=("docker volume  $v")
  fi
done
if [ -f .env ]; then
  to_delete+=("settings file  $PROJECT_ROOT/.env (your grafana password)")
fi

if [ "${#to_delete[@]}" -eq 0 ]; then
  info "there's no data to delete, just removing the containers"
  compose down
  exit 0
fi

warn "this permanently deletes:"
printf '    %s\n' "${to_delete[@]}" >&2
echo "    all collected metrics and anything you changed in grafana will be lost" >&2

if [ "$ASSUME_YES" != 1 ]; then
  answer=""
  # no terminal to ask (ci, piped) means read fails, the answer stays empty and
  # nothing gets deleted. deleting needs either a person or an explicit --yes
  read -r -p "type delete to confirm: " answer || true
  if [ "$answer" != delete ]; then
    die "cancelled, nothing was deleted"
  fi
fi

info "removing the containers and deleting the data"
# -v removes the named volumes declared in docker-compose.yml, and only those.
# volumes from other projects are never touched
compose down -v
rm -f .env

# check it actually worked instead of trusting it
for v in "${volumes[@]}"; do
  if docker volume inspect "$v" >/dev/null 2>&1; then
    die "volume $v is still there. remove it with: docker volume rm $v"
  fi
done

echo
info "everything was deleted"
echo "    the images are still downloaded, to free that space too:"
echo "      docker image rm $(compose config --images | paste -sd ' ')"
echo "    to remove the project itself, delete this folder:"
echo "      rm -rf $PROJECT_ROOT"
