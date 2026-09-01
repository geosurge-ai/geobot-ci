#!/usr/bin/env bash
# geobot-ci GC orchestrator.
#
# Reads $TARGETS (4-field lines), looks up store paths in the consumer repo's
# geobot-ci-eval-cache release, then SSHes to each target host to install
# gcroots and run `nix-collect-garbage $NIX_COLLECT_GARBAGE_ARGS`.
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
# Paths per (host|target_id). target_id is a short hash of "<repo>#<attr>",
# so each target gets its own gcroot subdir on the remote — a cache-miss
# for one target on a host doesn't wipe other targets' subdirs.
declare -A paths_for_target_id=()
# Per-host, the list of target_ids in original order (space-separated).
declare -A target_ids_in_order=()

for i in "${!ssh_targets[@]}"; do
  st="${ssh_targets[$i]}"
  repo="${repos[$i]}"
  attr="${attrs[$i]}"
  retain="${retains[$i]}"

  tid=$(printf '%s' "$repo#$attr" | sha256sum | cut -c1-16)
  echo "=== Resolving $st :: $repo#$attr (retain=$retain, subdir=$tid) ==="

  # Track target_ids per host (in input order)
  if [ -z "${target_ids_in_order[$st]:-}" ]; then
    target_ids_in_order["$st"]="$tid"
  else
    target_ids_in_order["$st"]="${target_ids_in_order[$st]} $tid"
  fi

  if [ -z "${repo_cache_dir[$repo]:-}" ]; then
    d="$workdir/cache/${repo//\//__}"
    mkdir -p "$d"
    echo "Downloading eval-cache for $repo..."
    gh release download geobot-ci-eval-cache \
      --repo "$repo" --pattern "eval-cache-*.json" --dir "$d" --clobber
    repo_cache_dir["$repo"]="$d"
  fi
  d="${repo_cache_dir[$repo]}"

  echo "Fetching last $retain commits of $repo default branch..."
  shas_csv=$(gh api "repos/$repo/commits?per_page=$retain" --jq '.[].sha' | tr '\n' ',' | sed 's/,$//')

  mapping=$(jq -s -r \
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
    echo "WARN: no eval-cache entries matched $repo#$attr for last $retain commits — this target contributes 0 paths to $st (its existing subdir $tid will be preserved)" >&2
    paths_for_target_id["$st|$tid"]=""
    continue
  fi

  echo "Cache entries matched (rev | output | path):"
  printf '%s\n' "$mapping" | sed 's/^/  /'

  paths=$(printf '%s\n' "$mapping" | cut -d' ' -f3 | sort -u)
  count=$(printf '%s\n' "$paths" | wc -l)
  echo "→ $count unique outPath(s) for target $tid on $st"

  paths_for_target_id["$st|$tid"]="$paths"
done

# COLLECT_HOSTS: space/newline-separated ssh_targets on which to actually run
# nix-collect-garbage. Hosts not listed only have their gcroots refreshed.
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
  echo "COLLECT_HOSTS empty: refreshing gcroots only, no nix-collect-garbage on any host"
else
  echo "COLLECT_HOSTS: will run nix-collect-garbage on: ${collect_list[*]}"
fi

# Inline remote script. Nix store paths contain no shell metacharacters,
# so passing them space-separated on the command line is safe.
remote_script=$(cat <<'REMOTE'
set -eu
gcroot_root="/nix/var/nix/gcroots/repo-gcroot"
hostname=$(hostname)
mkdir -p "$gcroot_root"

# Args are a sequence of blocks:
#   TARGET <target_id> <path1> <path2> ... [TARGET ...] END
# Nix store paths can't conflict with the TARGET/END keywords (paths start
# with /), so no count or escaping is needed.
host_input=0
host_added=0
host_skipped=0
targets_total=0
targets_empty=0

while [ "$#" -gt 0 ]; do
  marker="$1"; shift
  case "$marker" in
    END) break ;;
    TARGET)
      tid="$1"; shift
      targets_total=$((targets_total + 1))
      target_paths=()
      while [ "$#" -gt 0 ] && [ "$1" != "TARGET" ] && [ "$1" != "END" ]; do
        target_paths+=("$1"); shift
      done

      host_input=$((host_input + ${#target_paths[@]}))
      target_subdir="$gcroot_root/$tid"

      # Classify
      to_install=()
      to_skip=()
      for p in "${target_paths[@]+"${target_paths[@]}"}"; do
        if [ -e "$p" ]; then to_install+=("$p"); else to_skip+=("$p"); fi
      done

      echo "--- Target $tid on $hostname: ${#target_paths[@]} input path(s) ---"

      if [ "${#to_install[@]}" -eq 0 ]; then
        for p in "${to_skip[@]+"${to_skip[@]}"}"; do echo "  [-] missing $p"; done
        echo "  ... 0 installable; existing $target_subdir preserved"
        targets_empty=$((targets_empty + 1))
        continue
      fi

      # Refresh this target's subdir only.
      rm -rf "$target_subdir"
      mkdir -p "$target_subdir"
      for p in "${to_install[@]}"; do
        ln -sfn "$p" "$target_subdir/$(basename "$p")"
        echo "  [+] gcroot  $p"
      done
      for p in "${to_skip[@]+"${to_skip[@]}"}"; do
        echo "  [-] missing $p"
      done

      host_added=$((host_added + ${#to_install[@]}))
      host_skipped=$((host_skipped + ${#to_skip[@]}))
      ;;
    *)
      echo "ERROR: unexpected payload marker '$marker' on $hostname" >&2
      exit 1
      ;;
  esac
done

echo "--- $hostname summary: $host_added added, $host_skipped skipped across $targets_total target(s); $targets_empty had 0 installable (subdirs preserved) ---"

# Per-host fail-fast, on the count of paths the cache *resolved* rather than the
# count actually rooted. Zero resolved paths means the eval-cache lookup told us
# nothing, so collecting would sweep a store we have no roots for — refuse.
# Resolved paths that merely aren't present here are a different case: this host
# never built them, so there is nothing of theirs to protect and collection is
# safe. Every target's existing subdir is preserved either way, so roots from
# earlier runs still guard whatever they point at.
if [ "$host_input" -eq 0 ]; then
  if [ "${RUN_GC:-false}" = "true" ]; then
    echo "FAIL: cache resolved 0 paths for $hostname — refusing nix-collect-garbage" >&2
    exit 1
  else
    echo "WARN: cache resolved 0 paths for $hostname (collection not enabled for this host; existing subdirs preserved)" >&2
    exit 0
  fi
fi

if [ "$host_added" -eq 0 ]; then
  # Not fatal: a host that never built these has nothing of theirs to protect.
  # It is still worth an annotation, because the other way to reach this state
  # is a sweep between the build and this run — and from there the roots can
  # never advance, since nothing rebuilds an old revision's output. Silent
  # success here reads identically to a healthy no-op.
  echo "::warning title=gcroots did not advance on $hostname::none of the $host_input resolved path(s) are present; roots still point at whatever was last installed. If this repeats, the retained set is frozen — check the subdir mtimes under $gcroot_root."
  echo "NOTE: none of the $host_input resolved path(s) are present on $hostname — nothing new to root"
fi

if [ "${RUN_GC:-false}" = "true" ]; then
  echo "=== Running nix-collect-garbage ${NIX_COLLECT_GARBAGE_ARGS} on $hostname ==="
  _ncg_start=$(date +%s)
  # shellcheck disable=SC2086  # intentional word-splitting on extra args
  nix-collect-garbage ${NIX_COLLECT_GARBAGE_ARGS}
  _ncg_end=$(date +%s)
  echo "=== nix-collect-garbage on $hostname took $((_ncg_end - _ncg_start))s ==="
else
  echo "=== Skipping nix-collect-garbage (host not in collect_hosts). Inspect gcroots with: ls -la $gcroot_root ==="
fi
REMOTE
)

for st in "${host_order[@]}"; do
  args=()
  host_total_paths=0
  host_target_count=0
  for tid in ${target_ids_in_order[$st]:-}; do
    host_target_count=$((host_target_count + 1))
    paths="${paths_for_target_id[$st|$tid]:-}"
    if [ -z "$paths" ]; then
      args+=(TARGET "$tid")
    else
      mapfile -t paths_arr <<< "$paths"
      args+=(TARGET "$tid" "${paths_arr[@]}")
      host_total_paths=$((host_total_paths + ${#paths_arr[@]}))
    fi
  done
  args+=(END)

  if [ -n "${collect_set[$st]:-}" ]; then host_run_gc=true; else host_run_gc=false; fi
  echo "=== Sending to $st: $host_total_paths path(s) across $host_target_count target(s) (collect=$host_run_gc) ==="
  ncg_args_quoted=$(printf '%q' "${NIX_COLLECT_GARBAGE_ARGS:-}")
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" "$st" "RUN_GC=$host_run_gc NIX_COLLECT_GARBAGE_ARGS=$ncg_args_quoted bash -s -- ${args[*]}" <<< "$remote_script"
done

echo "=== All done ==="
