#!/usr/bin/env bash
# geobot-ci GC orchestrator.
#
# Reads $TARGETS (4-field lines), looks up store paths in the consumer repo's
# geobot-ci-eval-cache release, then SSHes to each target host to install
# gcroots and run `nix-collect-garbage --delete-older-than 7d`.
#
# No `nix eval` is performed; the cache is the source of truth.

set -euo pipefail

[ -n "${TARGETS:-}" ] || { echo "ERROR: TARGETS env var is required" >&2; exit 1; }

# Parse $TARGETS into parallel arrays. Format per line:
#   <ssh_target> <owner/repo#attr> <retain_count> <host_pubkey...>
# Pubkey contains a space (type + key), so it's the remainder of the line.
ssh_targets=()
repos=()
attrs=()
retains=()
pubkeys=()

while IFS= read -r raw; do
  line=$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  [ -z "$line" ] && continue
  case "$line" in '#'*) continue ;; esac

  read -r ssh_target flake_ref retain pubkey <<< "$line"
  if [ -z "$ssh_target" ] || [ -z "$flake_ref" ] || [ -z "$retain" ] || [ -z "$pubkey" ]; then
    echo "ERROR: malformed target line: $line" >&2
    echo "Expected: <ssh_target> <owner/repo#attr> <retain_count> <host_pubkey>" >&2
    exit 1
  fi

  case "$flake_ref" in
    *"#"*) owner_repo="${flake_ref%%#*}"; attr="${flake_ref#*#}" ;;
    *)
      echo "ERROR: target '$flake_ref' must contain '#<attr>'" >&2
      exit 1
      ;;
  esac

  # Normalize common URL forms to bare owner/repo.
  case "$owner_repo" in
    git+ssh://git@github.com/*) owner_repo="${owner_repo#git+ssh://git@github.com/}" ;;
    git@github.com:*)           owner_repo="${owner_repo#git@github.com:}" ;;
    git@github.com/*)           owner_repo="${owner_repo#git@github.com/}" ;;
    https://github.com/*)       owner_repo="${owner_repo#https://github.com/}" ;;
  esac
  owner_repo="${owner_repo%.git}"

  ssh_targets+=("$ssh_target")
  repos+=("$owner_repo")
  attrs+=("$attr")
  retains+=("$retain")
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

# Per-repo cache directory (memoized).
declare -A repo_cache_dir=()
# Accumulated paths per ssh_target.
declare -A paths_for_target=()
target_order=()

for i in "${!ssh_targets[@]}"; do
  st="${ssh_targets[$i]}"
  repo="${repos[$i]}"
  attr="${attrs[$i]}"
  retain="${retains[$i]}"

  echo "=== Resolving $st :: $repo#$attr (retain=$retain) ==="

  if [ -z "${repo_cache_dir[$repo]:-}" ]; then
    d="$workdir/cache/${repo//\//__}"
    mkdir -p "$d"
    echo "Downloading eval-cache for $repo..."
    nix run nixpkgs#gh -- release download geobot-ci-eval-cache \
      --repo "$repo" --pattern "eval-cache-*.json" --dir "$d" --clobber
    repo_cache_dir["$repo"]="$d"
  fi
  d="${repo_cache_dir[$repo]}"

  echo "Fetching last $retain commits of $repo default branch..."
  shas_csv=$(nix run nixpkgs#gh -- api "repos/$repo/commits?per_page=$retain" --jq '.[].sha' | tr '\n' ',' | sed 's/,$//')

  paths=$(nix run nixpkgs#jq -- -s -r \
    --arg attr "$attr" \
    --arg shas "$shas_csv" '
    ($shas | split(",")) as $shaset |
    add | to_entries[] |
    (.key | capture("rev=(?<rev>[0-9a-f]+)#(?<a>.+)$")) as $p |
    select($p.a == $attr) |
    select($shaset | index($p.rev)) |
    .value.outputs[]
  ' "$d"/eval-cache-*.json | sort -u)

  if [ -z "$paths" ]; then
    echo "FAIL: no eval-cache entries matched $repo#$attr for last $retain commits on default branch" >&2
    echo "Add a `check-if-changed` step for that attr (so the cache has entries), then retry." >&2
    exit 1
  fi

  count=$(printf '%s\n' "$paths" | wc -l)
  echo "Matched $count path(s)"

  if [ -z "${paths_for_target[$st]:-}" ]; then
    paths_for_target["$st"]="$paths"
    target_order+=("$st")
  else
    paths_for_target["$st"]=$(printf '%s\n%s' "${paths_for_target[$st]}" "$paths" | sort -u)
  fi
done

# Inline remote script. Nix store paths contain no shell metacharacters,
# so passing them space-separated on the command line is safe.
remote_script=$(cat <<'REMOTE'
set -eu
gcroot_dir="/nix/var/nix/gcroots/repo-gcroot"
rm -rf "$gcroot_dir"
mkdir -p "$gcroot_dir"
for store_path in "$@"; do
  if [ -e "$store_path" ]; then
    ln -sfn "$store_path" "$gcroot_dir/$(basename "$store_path")"
  fi
done
echo "=== Running nix-collect-garbage on $(hostname) ==="
nix-collect-garbage --delete-older-than 7d
REMOTE
)

for st in "${target_order[@]}"; do
  paths="${paths_for_target[$st]}"
  count=$(printf '%s\n' "$paths" | wc -l)
  echo "=== GC on $st ($count path(s)) ==="
  paths_args=$(printf '%s\n' "$paths" | tr '\n' ' ')
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" "$st" "bash -s -- $paths_args" <<< "$remote_script"
done

echo "=== All done ==="
