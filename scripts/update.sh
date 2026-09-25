#!/usr/bin/env bash
# updates the stack to the newest release (or to a release you pick with --to).
# never touches .env or your data, only the files that came from git.

set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd_project_root

usage() {
  cat <<EOF
usage: ./scripts/update.sh [options]

updates to the newest release. your .env and your data are kept.

options:
  --to <version>  go to a specific release instead of the newest, eg --to v0.1.0.
                  this is also how you roll back
  -y, --yes       dont ask for confirmation
  -h, --help      show this help
EOF
}

# everything lives inside main, which only gets called on the very last line.
# git checkout below replaces the files of this repo, including this script, while
# it's running. bash reads a script bit by bit as it goes, so if the file changes
# under it, it can end up running half old and half new lines. wrapping it all in a
# function makes bash read the whole thing before running any of it
main() {
  local target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --to)      [ $# -ge 2 ] || die "--to needs a version, eg --to v0.1.0"
                 target="$2"; shift ;;
      -y|--yes)  ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *)         usage >&2; die "unknown option: $1" ;;
    esac
    shift
  done

  require_cmd git
  require_cmd docker
  require_cmd curl

  # downloaded as a zip from github instead of git clone -> no history to update from
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "this folder isnt a git clone, so it cant update itself. clone it with git instead:
         https://github.com/santosh-kafle/prometheus-grafana-monitoring"

  # the checkout would overwrite any changes made to files that came from git.
  # .env isnt one of them (its gitignored), so its always safe
  local changed
  changed="$(git status --porcelain --untracked-files=no)"
  if [ -n "$changed" ]; then
    die "you changed some of the project's files, and updating would overwrite them:
$changed
         to see your changes: git diff
         to put them aside and update anyway: git stash, then run this again"
  fi

  info "checking for new releases"
  git fetch --tags --quiet origin || die "couldnt reach github. check your internet connection"

  # only proper release tags like v1.2.3, sorted by version (so v0.10.0 comes after
  # v0.9.0, which a plain text sort would get wrong)
  local latest
  latest="$(git tag --list 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
  [ -n "$latest" ] || die "no releases found"

  if [ -z "$target" ]; then
    target="$latest"
  else
    # any tag or branch works here, so rolling back to "master" is possible too
    git rev-parse --verify --quiet "$target^{commit}" >/dev/null ||
      die "theres no release called $target. available releases:
$(git tag --list 'v*' --sort=-v:refname | sed 's/^/           /')"
  fi

  # where we are now: a release tag, or a branch (a fresh git clone is on master)
  local current previous
  current="$(git describe --tags --exact-match 2>/dev/null || true)"
  if [ -n "$current" ]; then
    previous="$current"
  else
    previous="$(git symbolic-ref --short -q HEAD || git rev-parse --short HEAD)"
    current="$previous ($(git rev-parse --short HEAD))"
  fi

  if [ "$(git rev-parse HEAD)" = "$(git rev-parse "$target^{commit}")" ]; then
    info "already on $target, nothing to do"
    exit 0
  fi

  # someone on master with commits newer than the latest release (eg the person
  # working on this project) would otherwise get "updated" backwards
  if [ "$target" = "$latest" ] && git merge-base --is-ancestor "$target" HEAD; then
    info "you're already ahead of the newest release ($latest), nothing to do"
    exit 0
  fi

  echo
  info "update from $current to $target"
  # show what changed, straight from the changelog of the version we're going to
  git show "$target:CHANGELOG.md" 2>/dev/null |
    awk -v v="${target#v}" '
      index($0, "## [" v "]") == 1 { show = 1; print; next }
      show && /^## \[/ { exit }
      show { print }
    ' | sed 's/^/    /' || true
  echo

  if ! confirm "go ahead?"; then
    die "cancelled, nothing was changed"
  fi

  # -c advice.detachedHead=false hides git's long "detached HEAD" lecture. being on
  # a tag instead of a branch is normal for installing a release
  git -c advice.detachedHead=false checkout --quiet "$target"
  info "now on $target"

  # a new release might need a setting that isnt in your .env yet. only the lines that
  # arent commented out in .env.example are required, the commented ones have defaults
  local key missing=""
  while IFS= read -r key; do
    if ! grep -q "^$key=" .env 2>/dev/null; then
      missing="$missing $key"
    fi
  done < <(sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' .env.example)
  if [ -n "$missing" ]; then
    warn "this release needs settings that arent in your .env yet:$missing
         see .env.example for what they do, add them to .env, then run: docker compose up -d
         to go back instead: ./scripts/update.sh --to $previous"
    exit 1
  fi

  info "downloading the new images"
  docker compose pull
  info "restarting with the new version"
  # --remove-orphans cleans up containers for services a release no longer has
  docker compose up -d --remove-orphans

  if ! check_health; then
    die "the update didnt come up properly. to go back to where you were:
           ./scripts/update.sh --to $previous"
  fi

  echo
  info "updated to $target"
  echo "    if anything looks wrong, go back with: ./scripts/update.sh --to $previous"
}

main "$@"
