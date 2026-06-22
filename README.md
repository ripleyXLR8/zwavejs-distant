# zwavejs-distant

A **minimal, auto-maintained fork** of the official Jeedom plugin
[`jeedom/plugin-zwavejs`](https://github.com/jeedom/plugin-zwavejs) that enables
its built-in (but UI-disabled) **"Distant" mode**, so the Z-Wave antenna
(`zwave-js-ui`) can run on a **remote machine / Docker container** instead of on
the Jeedom host.

## Why this exists

The official plugin already contains all the backend logic for a remote antenna:
every daemon-lifecycle method (`deamon_start`, `deamon_stop`, `deamon_info`,
`isRunning`, `configureSettings`, `cronHourly`) already branches on
`zwavejs::mode == 'distant'` and no-ops local antenna management, and all
messaging already goes through the **MQTT Manager (`mqtt2`)** plugin. The *only*
thing missing in the official release is the UI switch to turn it on — the mode
selector in `plugin_info/configuration.php` ships commented out, and the docs
mark remote mode as "roadmap, not yet released".

This fork is therefore tiny: **one patch** that un-comments that selector (plus a
small load-time toggle init). No embedded MQTT daemon, no Docker config export,
none of the heavy machinery of the older `lxrootard/zwavejs` fork — your existing
`mqtt2` does the transport.

> When Jeedom officially ships Distant mode, this patch becomes a no-op and the
> fork can be retired.

## How it works

```
patches/0001-enable-distant-mode-ui.patch   the entire modification (single source of truth)
scripts/reapply.sh                           apply + verify logic (shared by CI and local dry-run)
.github/workflows/reapply.yml                daily: re-apply onto upstream, publish or open a PR
.last-applied-<track>.sha                    last upstream commit published per track
```

Branches/tags produced by CI:

- **`main`** — this automation only (patch, workflow, state). Not a usable plugin.
- **`dist/stable`**, **`dist/beta`** — the *materialized plugin*: upstream tree at
  its latest commit with the patch applied. **This is what you install.**
- Tags `dist-<track>-<shortsha>` mark each published build.

Each daily run, per track:

1. Resolve upstream's branch HEAD; skip if it equals `.last-applied-<track>.sha`.
2. Clone upstream at that commit, `git apply --3way` the patch, then verify
   (`php -l` on changed PHP, conflict-marker scan).
3. **Clean** → force-update `dist/<track>`, tag it, record the SHA on `main`.
   **Conflict** → push a branch and open a PR labelled `merge-conflict` /
   `track:<track>` for manual resolution. Nothing is published until you merge it.

## Installing into Jeedom

Install the `dist/stable` branch as the `zwavejs` plugin (plugin id stays
`zwavejs`), e.g. on the Jeedom host:

```bash
cd /var/www/html/plugins
sudo git clone -b dist/stable https://github.com/<your-user>/zwavejs-distant.git zwavejs
sudo chown -R www-data:www-data zwavejs
```

Then in the plugin configuration: set **Mode = Distant**, set the **MQTT prefix**
to match your remote `zwave-js-ui`, ensure **MQTT Manager (`mqtt2`)** is connected
to the same broker your remote `zwave-js-ui` publishes to, and start the plugin.
Configure the antenna itself (serial port, security keys, MQTT broker, prefix)
directly in your remote `zwave-js-ui` Docker container — the plugin does **not**
manage it in Distant mode.

## First-time setup checklist

1. **Verify the feature on your Jeedom** before relying on the automation —
   Distant mode is officially unreleased upstream. Enable it, point it at your
   Docker antenna via `mqtt2`, and confirm nodes sync and a command round-trips.
2. **Confirm the upstream `stable` branch name.** Only `beta` was confirmed to
   exist. If upstream's stable branch is named differently (e.g. `master`),
   update `upstream_branch` for the `stable` track in
   `.github/workflows/reapply.yml`. If there is no stable branch, drop that
   matrix entry and track `beta` only.
3. Push this repo, then run the workflow manually (Actions → *Re-apply
   distant-mode patch* → *Run workflow*) to produce the initial `dist/*` builds.

## Local dry-run

```bash
REPO_DIR="$PWD" TRACK=stable UPSTREAM_DIR=/path/to/upstream/checkout \
  bash scripts/reapply.sh          # offline: uses a local upstream snapshot
# or, online (clones upstream):
REPO_DIR="$PWD" TRACK=beta UPSTREAM_BRANCH=beta bash scripts/reapply.sh
```

Result lands in `.work/<track>/` and a summary in `.reapply-<track>.env`
(`RESULT=clean|conflict`). Exit code 0 = clean, 1 = conflict.
