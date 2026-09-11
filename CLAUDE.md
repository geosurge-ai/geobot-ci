## Project Overview

`geobot-ci` holds the CI building blocks shared by other Geosurge repos (mainly `grim-monolith`, `darksteel-forge`). Consumers pin by full commit SHA. There is no CI in this repo — everything is validated by running it from a consumer's PR.

- `.github/workflows/run.yml` — reusable workflow: evaluates a package, skips it if that exact binary already ran green on this host, otherwise builds it, runs it, and records the success. Writes no gcroot.
- `.github/workflows/build-and-root.yml` — reusable workflow: builds the consumer's flake-inputs linkFarm and its aggregate attribute, each with an out-link in one per-revision directory. The only thing here that writes gcroots.
- `setup` — composite action that installs the geobot SSH key. The two workflows and `gc` use it too, pinned to a SHA on this repo's main like any consumer, because a called workflow has no way to locate its own commit (`github.job_workflow_sha` is empty on the self-hosted runners). Used on its own by workflows that then `nix run` something.
- `gc` — composite action that prunes gcroot directories on remote hosts to their newest N entries and sweeps the hosts it is told to.

The two are reusable workflows rather than composite actions because the jobs API reports a composite action as a single step; a called workflow's steps are ordinary steps of the caller's run, so every one of them has its own duration in `gh run view --json jobs`. Keep each step doing one thing, so a duration means one thing.

## Changing anything here

Open a PR here, then open the consumer PR pinned to this PR's head SHA, and iterate on both. Once the consumer side is approved, merge this PR (`gh pr merge --merge`, so the branch's SHA stays reachable from main), re-pin the consumer PR to the new main HEAD, and merge the consumer. Never push to main directly: a broken iteration then has to be undone on main, whereas a PR head is just as testable from the consumer side.

In the consumer, bump only the pin of the workflow or action that changed. The pins are independent, and rewriting all of them re-triggers every workflow for nothing. A change to `setup` needs one more round: merge it, then bump the `setup@` pin inside `run.yml`, `build-and-root.yml` and `gc/action.yml` to that main SHA.

## Editing actions

- Keep changes minimal — these run on every CI job of every consumer and a regression here fans out everywhere.
- `run.yml`'s `nix eval` is wrapped in `timeout` and retried. Every runner slot on vortex shares one `XDG_CACHE_HOME` (`/var/cache/github-runners-shared`), so concurrent evals contend on Lix's per-input fetcher lock (`$XDG_CACHE_HOME/nix/fetcher-lock-*`, keyed on repo+ref+rev and held across the whole fetch) and on its fetcher-cache SQLite. Lix waits on both without a timeout, so the `timeout` is what turns a stalled peer into a retryable failure rather than an unbounded silent hang. Serializing with `flock -w 120` was tried and reverted in 3ea0edc: 120s of queue depth across 64 slots made jobs hard-fail under load.
- The succeeded set lives in `/var/cache/github-runners-shared/geobot-ci-succeeded` on the runner host, one file per key. Only `run.yml` writes it, and only after the binary exited 0 — presence of a path in a store says it was built, not that it ever ran. It is deliberately host-local: every runner of a given consumer mounts that volume, a lost entry only re-runs a job, and no state it can reach produces a wrong skip. A consumer whose runners are not all on one host needs something else.
- A gcroot is written by the job that builds or receives the path, while it still holds it. `build-and-root.yml`'s `root_dir` is that root: one directory per revision, holding `inputs` and `result`. Point it under a persistent directory on any host that collects garbage on its own schedule. `gc/gc.sh` only bounds how many of those directories are kept — it resolves no store paths and can protect nothing the writing job did not already root. Getting this backwards is what the eval-cache was: roots installed after the fact, a day later, for paths a sweep in between had already taken.
- `gc/gc.sh` refuses to collect on a host where a declared gcroot directory is missing or empty, because that means the job that writes it never ran and the store's roots are ones this script cannot see. Keep that guard; it is the only thing between a misconfigured target line and an emptied store.
