#!/usr/bin/env bash
# installs the monitoring stack on this machine.
# checks the machine is ready, creates .env, starts the stack and waits until it
# actually works. safe to run again, it keeps your .env and your data.

set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd_project_root

usage() {
  cat <<EOF
usage: ./scripts/install.sh [options]

checks this machine is ready, then installs the monitoring stack.

options:
  --local      only this machine can open grafana (the default)
  --lan        any device on your home network can open grafana
  -y, --yes    dont ask any questions, use the defaults (for ci and scripts)
  -h, --help   show this help
EOF
}

# empty means "ask". only used when .env doesnt exist yet, an existing .env wins
ACCESS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --local)   ACCESS=local ;;
    --lan)     ACCESS=lan ;;
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# preflight checks
# every check runs even if an earlier one failed, then all the problems get listed
# together. a beginner with three problems sees all three at once instead of fixing
# one, rerunning, and hitting the next. so no die in here, only problem()
# ---------------------------------------------------------------------------

problems=0
problem() {
  warn "$*"
  # not ((problems++)), that returns 1 when problems is 0 and set -e would exit
  problems=$((problems + 1))
}

check_linux() {
  if [ "$(uname -s)" != "Linux" ]; then
    problem "this only works on linux. it uses docker's host networking, and on mac
         and windows docker runs inside a vm, so it would monitor the vm, not your machine"
  fi
}

# returns 1 if docker isnt usable, so the checks that need docker can be skipped
# instead of each one failing with the same confusing error
check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    problem "docker is not installed. install guide: https://docs.docker.com/engine/install/"
    return 1
  fi

  # podman ships a `docker` command that pretends to be docker. it cant do the host
  # mounts this stack needs, so catch it here with a clear message
  if docker --version 2>&1 | grep -qi podman; then
    problem "the docker command on this machine is podman, which isnt supported. install docker engine"
    return 1
  fi

  local out
  if ! out="$(docker info 2>&1)"; then
    # docker info fails for two different reasons with two different fixes
    if grep -qi "permission denied" <<<"$out"; then
      problem "you dont have permission to use docker. add yourself to the docker group:
           sudo usermod -aG docker \$USER
         then log out and back in (it doesnt apply until you do).
         note: being in the docker group is effectively the same as having root"
    elif grep -qiE "cannot connect|is the docker daemon running" <<<"$out"; then
      problem "docker is installed but not running. start it with:
           sudo systemctl enable --now docker"
    else
      problem "docker info failed:
$out"
    fi
    return 1
  fi

  # rootless docker cant mount / or join the host network properly
  if grep -q "rootless" <<<"$(docker info --format '{{.SecurityOptions}}')"; then
    problem "rootless docker isnt supported, this stack needs full access to the host
         network and filesystem to read its metrics"
    return 1
  fi

  info "docker is installed and running"
}

check_compose() {
  if docker compose version >/dev/null 2>&1; then
    info "docker compose v2 is installed"
  elif command -v docker-compose >/dev/null 2>&1; then
    problem "only the old docker-compose (v1) is installed. install the compose plugin:
         https://docs.docker.com/compose/install/linux/"
  else
    problem "docker compose is not installed: https://docs.docker.com/compose/install/linux/"
  fi
}

check_openssl() {
  if command -v openssl >/dev/null 2>&1; then
    info "openssl is installed"
  else
    problem "openssl is not installed (its used to generate your grafana password).
         install it with your package manager, eg: sudo apt install openssl"
  fi
}

# env_value <name> <default> -> the setting from .env, or the default if its not set
# (or if theres no .env yet)
env_value() {
  local value=""
  if [ -f .env ]; then
    value="$(sed -n "s/^$1=//p" .env | tail -n 1)"
  fi
  echo "${value:-$2}"
}

check_curl() {
  if command -v curl >/dev/null 2>&1; then
    info "curl is installed"
  else
    problem "curl is not installed (its used to check the stack started properly).
         install it with your package manager, eg: sudo apt install curl"
  fi
}

check_ports() {
  # if this stack is already running, the ports are "taken" by itself. thats fine,
  # it just means install is being run a second time
  if stack_is_running; then
    info "the stack is already running, skipping the port check"
    return 0
  fi

  if ! command -v ss >/dev/null 2>&1; then
    warn "ss is not installed (package iproute2), cant check if the ports are free. skipping"
    return 0
  fi

  # the grafana port can be changed in .env, so check that one and not always 3000
  local gport entry name port busy=0
  gport="$(env_value GRAFANA_PORT 3000)"
  for entry in "prometheus:9090" "node-exporter:9100" "grafana:$gport"; do
    name="${entry%%:*}"
    port="${entry##*:}"
    if [ -n "$(ss -Hltn "sport = :$port")" ]; then
      busy=1
      if [ "$name" = grafana ]; then
        problem "port $port is already in use by another program, grafana needs it.
         either stop that program, or pick another port by adding GRAFANA_PORT=3001 to .env
         (to see what's using it: sudo ss -ltnp 'sport = :$port')"
      else
        problem "port $port is already in use by another program, $name needs it.
         stop that program first (to see what it is: sudo ss -ltnp 'sport = :$port')"
      fi
    fi
  done
  if [ "$busy" -eq 0 ]; then
    info "ports 9090, 9100 and $gport are free"
  fi
}

info "checking this machine is ready"
check_linux
# compose and the port check both need a working docker, so only run them if it is.
# otherwise they'd each fail with the same docker error again
if check_docker; then
  check_compose
  check_ports
fi
check_openssl
check_curl

if [ "$problems" -gt 0 ]; then
  die "found $problems problem(s), see above. nothing was changed, fix them and run this again"
fi
info "all checks passed"

# not a problem, just a heads up. the containers restart on their own after a reboot
# (restart: unless-stopped), but only if docker itself starts at boot
if command -v systemctl >/dev/null 2>&1 && ! systemctl is-enabled --quiet docker 2>/dev/null; then
  warn "docker doesnt start at boot, so monitoring will stop after a reboot. to fix:
           sudo systemctl enable docker"
fi

# ---------------------------------------------------------------------------
# .env and network access
# ---------------------------------------------------------------------------

ask_access() {
  # --yes, or no terminal to ask (ci, piped), means the safe default
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then
    echo local
    return
  fi
  # not confirm() here. with --yes confirm says yes, and "yes" to this question
  # would open grafana to the network, the opposite of a safe default.
  # the menu goes to stderr because stdout is captured as the answer
  local answer=""
  {
    echo
    echo "who should be able to open grafana?"
    echo "  1) only this machine (safest, pick this on a laptop)"
    echo "  2) any device on your home network (pick this on a server with no screen)"
  } >&2
  read -r -p "choose 1 or 2 [1]: " answer || true
  case "$answer" in
    2) echo lan ;;
    *) echo local ;;
  esac
}

# remember if grafanas database already existed before we touch anything. grafana
# only reads the password from .env when it creates its database, so a new .env on
# top of an old volume means the new password wont work
grafana_volume="$(compose_project_name)_grafana_data"
volume_existed=0
if docker volume inspect "$grafana_volume" >/dev/null 2>&1; then
  volume_existed=1
fi

if [ -f .env ]; then
  info "keeping your existing .env"
  if [ -n "$ACCESS" ]; then
    warn "--$ACCESS was ignored because .env already exists. change GRAFANA_BIND_ADDR in .env instead"
  fi
else
  if [ -z "$ACCESS" ]; then
    ACCESS="$(ask_access)"
  fi
  "$PROJECT_ROOT/scripts/setup.sh"

  if [ "$ACCESS" = lan ]; then
    # the line is commented out in .env.example, so this uncomments it and sets it
    sed -i 's/^#\{0,1\}GRAFANA_BIND_ADDR=.*/GRAFANA_BIND_ADDR=0.0.0.0/' .env
    grep -q '^GRAFANA_BIND_ADDR=0.0.0.0$' .env || die "couldnt set GRAFANA_BIND_ADDR in .env"
    info "grafana will be open to your home network"
  else
    info "grafana will only be reachable from this machine"
  fi

  if [ "$volume_existed" = 1 ]; then
    warn "grafana already has a database from an earlier install, so it keeps the password
         from back then and the new one in .env wont work. to set a new one after install:
           docker exec -it grafana grafana cli admin reset-admin-password <new-password>"
  fi
fi

bind_addr="$(env_value GRAFANA_BIND_ADDR 127.0.0.1)"
port="$(env_value GRAFANA_PORT 3000)"

# with network_mode: host there are no docker nat rules, so the host firewall really
# does filter grafanas port. (published ports: would have skipped the firewall, a well
# known docker surprise.) we dont change the firewall ourselves, just say what to run
if [ "$bind_addr" != 127.0.0.1 ]; then
  if systemctl is-active --quiet ufw 2>/dev/null; then
    warn "ufw is on and will block other devices from reaching grafana. to allow it:
           sudo ufw allow $port/tcp"
  elif systemctl is-active --quiet firewalld 2>/dev/null; then
    warn "firewalld is on and will block other devices from reaching grafana. to allow it:
           sudo firewall-cmd --permanent --add-port=$port/tcp && sudo firewall-cmd --reload"
  fi
fi

# ---------------------------------------------------------------------------
# start the stack
# ---------------------------------------------------------------------------

info "downloading the images (this takes a while the first time)"
docker compose pull

info "starting the stack"
docker compose up -d

# ---------------------------------------------------------------------------
# health check
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

wait_for "node exporter is collecting metrics" 60 curl -sf http://127.0.0.1:9100/metrics ||
  die "node exporter didnt start. see what went wrong with: docker compose logs node-exporter"
wait_for "prometheus is up" 60 curl -sf http://127.0.0.1:9090/-/ready ||
  die "prometheus didnt start. see what went wrong with: docker compose logs prometheus"
wait_for "prometheus is collecting from node exporter" 60 targets_up ||
  die "prometheus started but isnt collecting. check http://127.0.0.1:9090/targets"
wait_for "grafana is up" 90 curl -sf "http://127.0.0.1:$port/api/health" ||
  die "grafana didnt start. see what went wrong with: docker compose logs grafana"

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------

if [ "$bind_addr" = 127.0.0.1 ]; then
  url="http://127.0.0.1:$port"
else
  # the address other devices would use. ip route get asks the kernel which address
  # it would send from, more reliable than guessing which interface is the real one
  lan_ip="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
  url="http://${lan_ip:-<this-machines-ip>}:$port"
fi

echo
info "installed! open $url"
echo "    username: $(env_value GF_SECURITY_ADMIN_USER admin)"
echo "    password: run  grep GF_SECURITY_ADMIN_PASSWORD .env"
echo "    dashboard: Dashboards -> Laptop -> Laptop Overview"
