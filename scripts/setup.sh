#!/usr/bin/env bash
# creates .env from .env.example and fills in generated passwords.
# refuses to run if .env already exists so a real password never gets overwritten.

# stop at the first failed command, unset variable, or failed pipe
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd_project_root

if [ -e .env ]; then
  die ".env already exists, leaving it alone"
fi

require_cmd openssl "install it with your package manager, eg sudo apt install openssl"

# hex output is only 0-9a-f, so it can't break the sed command below
grafana_password="$(openssl rand -hex 24)"

# every file created after this line is readable by me only (600)
umask 077

cp .env.example .env

# match on the variable name, not the placeholder text, so changing the
# placeholder in .env.example doesn't break this
sed -i "s/^GF_SECURITY_ADMIN_PASSWORD=.*/GF_SECURITY_ADMIN_PASSWORD=${grafana_password}/" .env

# sed does nothing (and doesn't fail) if the line isn't there, so check it worked.
# if it didn't, delete the half-made .env, otherwise the next run would refuse
if ! grep -q "^GF_SECURITY_ADMIN_PASSWORD=${grafana_password}$" .env; then
  rm -f .env
  die "couldn't set GF_SECURITY_ADMIN_PASSWORD, is it in .env.example?"
fi

info "created .env with a generated grafana password (see .env to read it)"
