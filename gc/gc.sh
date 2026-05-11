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

# Unique hosts in first-seen order (so we can check fail-fast per-host below).
host_order=()
declare -A host_seen=()
for st in "${ssh_targets[@]}"; do
  if [ -z "${host_seen[$st]:-}" ]; then
    host_seen["$st"]=1
    host_order+=("$st")
  fi
done

# Per-repo cache directory (memoized).
declare -A repo_cache_dir=()
# Accumulated paths per ssh_target.
declare -A paths_for_target=()

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

  mapping=$(nix run nixpkgs#jq -- -s -r \
    --arg attr "$attr" \
    --arg shas "$shas_csv" '
    ($shas | split(",")) as $shaset |
    add | to_entries[] |
    (.key | capture("rev=(?<rev>[0-9a-f]+)#(?<a>.+)$")) as $p |
    select($p.a == $attr) |
    select($shaset | index($p.rev)) |
    .value.outputs | to_entries[] | "\($p.rev[0:10]) \(.key) \(.value)"
  ' "$d"/eval-cache-*.json)

  if [ -z "$mapping" ]; then
    echo "WARN: no eval-cache entries matched $repo#$attr for last $retain commits — this target contributes 0 paths to $st" >&2
    continue
  fi

  echo "Cache entries matched (rev | output | path):"
  printf '%s\n' "$mapping" | sed 's/^/  /'

  paths=$(printf '%s\n' "$mapping" | awk '{print $3}' | sort -u)
  count=$(printf '%s\n' "$paths" | wc -l)
  echo "→ $count unique outPath(s) for $st"

  if [ -z "${paths_for_target[$st]:-}" ]; then
    paths_for_target["$st"]="$paths"
  else
    paths_for_target["$st"]=$(printf '%s\n%s' "${paths_for_target[$st]}" "$paths" | sort -u)
  fi
done

run_gc="${RUN_GC:-true}"
case "$run_gc" in
  true|false) ;;
  *) echo "ERROR: RUN_GC must be 'true' or 'false', got '$run_gc'" >&2; exit 1 ;;
esac
echo "RUN_GC=$run_gc (will$([ "$run_gc" = "true" ] || echo " NOT") run nix-collect-garbage)"

# Inline remote script. Nix store paths contain no shell metacharacters,
# so passing them space-separated on the command line is safe.
remote_script=$(cat <<'REMOTE'
set -eu
gcroot_dir="/nix/var/nix/gcroots/repo-gcroot"
hostname=$(hostname)
echo "--- Resetting $gcroot_dir on $hostname ---"
rm -rf "$gcroot_dir"
mkdir -p "$gcroot_dir"
created=0
skipped=0
for store_path in "$@"; do
  if [ -e "$store_path" ]; then
    ln -sfn "$store_path" "$gcroot_dir/$(basename "$store_path")"
    echo "  [+] gcroot  $store_path"
    created=$((created + 1))
  else
    echo "  [-] missing $store_path"
    skipped=$((skipped + 1))
  fi
done
echo "--- $hostname summary: $created added, $skipped skipped ---"
if [ "$created" -eq 0 ]; then
  if [ "${RUN_GC:-true}" = "true" ]; then
    echo "FAIL: 0 gcroots created on $hostname — refusing to run nix-collect-garbage (would wipe the store)" >&2
    exit 1
  else
    echo "WARN: 0 gcroots created on $hostname (RUN_GC=false, so no harm — but the GC would have refused in real mode)" >&2
    exit 0
  fi
fi
if [ "${RUN_GC:-true}" = "true" ]; then
  echo "=== Running nix-collect-garbage ${NIX_COLLECT_GARBAGE_ARGS} on $hostname ==="
  # shellcheck disable=SC2086  # intentional word-splitting on extra args
  nix-collect-garbage ${NIX_COLLECT_GARBAGE_ARGS}
else
  echo "=== Skipping nix-collect-garbage (RUN_GC=false). Inspect gcroots with: ls -la $gcroot_dir ==="
fi
REMOTE
)

for st in "${host_order[@]}"; do
  paths="${paths_for_target[$st]:-}"
  if [ -z "$paths" ]; then
    count=0
    paths_args=""
  else
    count=$(printf '%s\n' "$paths" | wc -l)
    paths_args=$(printf '%s\n' "$paths" | tr '\n' ' ')
  fi
  echo "=== GC on $st ($count path(s) to attempt) ==="
  ncg_args_quoted=$(printf '%q' "${NIX_COLLECT_GARBAGE_ARGS:-}")
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" "$st" "RUN_GC=$run_gc NIX_COLLECT_GARBAGE_ARGS=$ncg_args_quoted bash -s -- $paths_args" <<< "$remote_script"
done

echo "=== All done ==="
