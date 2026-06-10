## Project Overview

`geobot-ci` is a collection of small composite GitHub Actions (`check-if-changed`, `eval`, `gc`, `run`, `setup`) shared by other Geosurge repos (mainly `grim-monolith`, `darksteel-forge`). Consumers pin by full commit SHA. There is no CI in this repo — actions are validated by running them in consumer workflows.

## Pushing changes

Push directly to `main`. Do NOT open a pull request.

Why:
- Consumers pin by SHA, so the relevant test is "does the new SHA work in the consumer's CI", which is what bumping the pin in `grim-monolith` (or wherever) actually exercises.
- `gh pr merge --rebase` rewrites the commit SHA, forcing a second consumer-side bump to chase the new SHA. Pushing directly to `main` makes the commit SHA stable from the start — one main → one pin bump in the consumer, no second hop.
- This repo has no PR CI to gate on anyway.

After pushing to main:
1. Note the new HEAD SHA: `git rev-parse main`.
2. In the consumer repo, update every `geosurge-ai/geobot-ci/<action>@<old-sha>` reference to the new SHA (typically a global `sed`).
3. Open the consumer-side PR with the bump.

## Editing actions

- `check-if-changed/`, `eval/`, `gc/`, `run/`, `setup/` are each a composite action with an `action.yml`. Keep changes minimal — these run on every CI job of every consumer and a regression here fans out everywhere.
- `nix eval` calls are serialized with `flock` on `$XDG_CACHE_HOME/nix/geobot-ci-eval.lock` to avoid eval-cache SQLite contention when many runner slots share `XDG_CACHE_HOME` (e.g. vortex's `/var/cache/github-runners-shared`). This requires `flock` (from `util-linux`) on the runner's PATH — see `darksteel-forge/machines/vortex/github-runners.nix`.
- The release-asset cache (`geobot-ci-eval-cache`, `geobot-ci-succeed-list`) is per-consumer-repo and managed by the actions themselves; do not write to it from outside.
