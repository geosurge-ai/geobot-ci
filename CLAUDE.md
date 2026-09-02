## Project Overview

`geobot-ci` is a collection of small composite GitHub Actions (`check-if-ran`, `gc`, `run`, `setup`) shared by other Geosurge repos (mainly `grim-monolith`, `darksteel-forge`). Consumers pin by full commit SHA. There is no CI in this repo — actions are validated by running them in consumer workflows.

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

- `check-if-ran/`, `gc/`, `run/`, `setup/` are each a composite action with an `action.yml`. Keep changes minimal — these run on every CI job of every consumer and a regression here fans out everywhere.
- The build belongs to the caller, as a plain `run:` step, not to an action. GitHub omits a composite action's inner steps from the jobs API, so a build inside one has no duration in the UI and cannot carry its own `timeout-minutes`; `setup` puts SSH into `$GITHUB_ENV` for the whole job, so the caller's step is one `nix build` line.
- `nix eval` calls are wrapped in `timeout` (`eval_timeout`, default 600s) and retried. Every runner slot on vortex shares one `XDG_CACHE_HOME` (`/var/cache/github-runners-shared`), so concurrent evals contend on Lix's per-input fetcher lock (`$XDG_CACHE_HOME/nix/fetcher-lock-*`, keyed on repo+ref+rev and held across the whole fetch) and on its fetcher-cache SQLite. Lix waits on both without a timeout, so the `timeout` is what turns a stalled peer into a retryable failure rather than an unbounded silent hang. Serializing with `flock -w 120` was tried and reverted in 3ea0edc: 120s of queue depth across 64 slots made jobs hard-fail under load.
- The succeeded set lives in `/var/cache/github-runners-shared/geobot-ci-succeeded` on the runner host, one file per key. Only `run` writes it, and only after the binary exited 0 — presence of a path in a store says it was built, not that it ever ran. It is deliberately host-local: every runner of a given consumer mounts that volume, a lost entry only re-runs a job, and no state it can reach produces a wrong skip. A consumer whose runners are not all on one host needs something else.
- A gcroot is written by the job that builds or receives the path, while it still holds it. `out_link` is that root: the default `./result` sits in the runner workspace and is removed at cleanup, so pass a path under a persistent directory on any host that collects garbage on its own schedule. It is written on both paths a revision can take — by the caller's own `nix build` step when a rerun is required, by `check-if-ran` when it is not. `check-if-ran` gates `rerun-required` on the store still holding the output as well as on the marker, so the one case it cannot root is turned into a build rather than left unprotected. `gc/gc.sh` only bounds how many of those roots are kept — it resolves no store paths and can protect nothing the writing job did not already root. Getting this backwards is what the eval-cache was: roots installed after the fact, a day later, for paths a sweep in between had already taken.
- `gc/gc.sh` refuses to collect on a host where a declared gcroot directory is missing or empty, because that means the job that writes it never ran and the store's roots are ones this script cannot see. Keep that guard; it is the only thing between a misconfigured target line and an emptied store.
