#!/usr/bin/env bash
# geobot-ci GC orchestrator.
#
# Reads $TARGETS (4-field lines), prunes each declared gcroot directory to its
# newest $keep entries, and runs `nix-collect-garbage $NIX_COLLECT_GARBAGE_ARGS`
# on the hosts named in $COLLECT_HOSTS.
#
# The roots are written by the job that builds or receives the paths, while it
# still holds them. Nothing here resolves a store path, so a path this script
# has never heard of is still protected the moment it exists.

set -euo pipefail

[ -n "${TARGETS:-}" ] || { echo "ERROR: TARGETS env var is required" >&2; exit 1; }

# Parse $TARGETS into parallel arrays. Format per line:
#   <ssh_target> <gcroot_dir> <keep> <host_pubkey...>
# Pubkey contains a space (type + key), so it's the remainder of the line.
ssh_targets=()
dirs=()
keeps=()
pubkeys=()

while IFS= read -r raw; do
  line=$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  [ -z "$line" ] && continue
  case "$line" in '#'*) continue ;; esac

  read -r ssh_target dir keep pubkey <<< "$line"
  if [ -z "$ssh_target" ] || [ -z "$dir" ] || [ -z "$keep" ] || [ -z "$pubkey" ]; then
    echo "ERROR: malformed target line: $line" >&2
    echo "Expected: <ssh_target> <gcroot_dir> <keep> <host_pubkey>" >&2
    exit 1
  fi

  case "$dir" in
    /*) ;;
    *) echo "ERROR: gcroot_dir must be an absolute path: $line" >&2; exit 1 ;;
  esac

  case "$keep" in
    all) ;;
    ''|*[!0-9]*|0) 
      echo "ERROR: keep must be a positive integer or 'all': $line" >&2
      exit 1
      ;;
  esac

  ssh_targets+=("$ssh_target")
  dirs+=("$dir")
  keeps+=("$keep")
  pubkeys+=("$pubkey")
done <<< "$TARGETS"

if [ "${#ssh_targets[@]}" -eq 0 ]; then
  echo "No targets to process"
  exit 0
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Build a known_hosts file from per-target pubkeys.
known_hosts="$workdir/known_hosts"
: > "$known_hosts"
for i in "${!ssh_targets[@]}"; do
  host="${ssh_targets[$i]##*@}"
  printf '%s %s\n' "$host" "${pubkeys[$i]}" >> "$known_hosts"
done
sort -u "$known_hosts" -o "$known_hosts"

ssh_opts=(
  -i "$HOME/.ssh/id_ed25519"
  -o IdentitiesOnly=yes
  -o "UserKnownHostsFile=$known_hosts"
  -o StrictHostKeyChecking=yes
)

# Unique hosts in first-seen order; targets on one host go in a single session.
host_order=()
declare -A host_seen=()
declare -A dirs_for_host=()
for i in "${!ssh_targets[@]}"; do
  st="${ssh_targets[$i]}"
  if [ -z "${host_seen[$st]:-}" ]; then
    host_seen["$st"]=1
    host_order+=("$st")
  fi
  dirs_for_host["$st"]="${dirs_for_host[$st]:-}${dirs[$i]} ${keeps[$i]} "
done

# COLLECT_HOSTS: space/newline-separated ssh_targets on which to actually run
# nix-collect-garbage. Hosts not listed only have their gcroot dirs pruned.
# Empty (default) collects nowhere.
declare -A collect_set=()
collect_list=()
for h in ${COLLECT_HOSTS:-}; do
  collect_set["$h"]=1
  collect_list+=("$h")
done

# Typo guard: a collect host that matches no target ssh_target would silently
# collect on the wrong host (or nowhere), so fail loudly instead.
for h in "${collect_list[@]+"${collect_list[@]}"}"; do
  if [ -z "${host_seen[$h]:-}" ]; then
    echo "ERROR: collect_hosts entry '$h' is not among the target ssh_targets" >&2
    echo "Known ssh_targets: ${host_order[*]}" >&2
    exit 1
  fi
done

if [ "${#collect_list[@]}" -eq 0 ]; then
  echo "COLLECT_HOSTS empty: pruning gcroots only, no nix-collect-garbage on any host"
else
  echo "COLLECT_HOSTS: will run nix-collect-garbage on: ${collect_list[*]}"
fi

# Inline remote script. Args are <dir> <keep> pairs; gcroot dirs are absolute
# paths under our control and contain no shell metacharacters.
remote_script=$(cat <<'REMOTE'
set -eu
hostname=$(hostname)
unprotected=0

while [ "$#" -gt 0 ]; do
  dir="$1"; keep="$2"; shift 2

  if [ ! -d "$dir" ]; then
    echo "  [!] $dir does not exist"
    unprotected=$((unprotected + 1))
    continue
  fi

  total=$(ls -1 "$dir" | wc -l)
  if [ "$total" -eq 0 ]; then
    echo "  [!] $dir is empty"
    unprotected=$((unprotected + 1))
    continue
  fi

  if [ "$keep" = all ]; then
    echo "  [=] $dir: $total root(s), kept whole"
    continue
  fi

  removed=0
  # Newest first by mtime, so the tail is everything past the keep window. The
  # entries are named by the job that wrote them and carry no whitespace.
  for stale in $(ls -1t "$dir" | tail -n +"$((keep + 1))"); do
    rm -rf -- "${dir:?}/$stale"
    removed=$((removed + 1))
  done
  echo "  [-] $dir: $total root(s), kept newest $keep, removed $removed"
done

if [ "${RUN_GC:-false}" != "true" ]; then
  if [ "$unprotected" -gt 0 ]; then
    echo "::warning title=gcroot dir missing on $hostname::$unprotected declared gcroot dir(s) are missing or empty; whatever they should hold is unprotected against this host's own collection"
  fi
  echo "=== Skipping nix-collect-garbage on $hostname (host not in collect_hosts) ==="
  exit 0
fi

# A declared directory that is missing or empty means the job that writes it
# never ran, or wrote somewhere else. Collecting now would sweep a store whose
# roots we cannot see, so refuse.
if [ "$unprotected" -gt 0 ]; then
  echo "FAIL: $unprotected declared gcroot dir(s) missing or empty on $hostname — refusing nix-collect-garbage" >&2
  exit 1
fi

echo "=== Running nix-collect-garbage ${NIX_COLLECT_GARBAGE_ARGS} on $hostname ==="
_ncg_start=$(date +%s)
# shellcheck disable=SC2086  # intentional word-splitting on extra args
nix-collect-garbage ${NIX_COLLECT_GARBAGE_ARGS}
_ncg_end=$(date +%s)
echo "=== nix-collect-garbage on $hostname took $((_ncg_end - _ncg_start))s ==="
REMOTE
)

for st in "${host_order[@]}"; do
  read -r -a args <<< "${dirs_for_host[$st]}"
  if [ -n "${collect_set[$st]:-}" ]; then host_run_gc=true; else host_run_gc=false; fi
  echo "=== $st: $(( ${#args[@]} / 2 )) gcroot dir(s) (collect=$host_run_gc) ==="
  ncg_args_quoted=$(printf '%q' "${NIX_COLLECT_GARBAGE_ARGS:-}")
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" "$st" "RUN_GC=$host_run_gc NIX_COLLECT_GARBAGE_ARGS=$ncg_args_quoted bash -s -- ${args[*]}" <<< "$remote_script"
done

echo "=== All done ==="
