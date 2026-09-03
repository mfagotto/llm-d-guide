# Upgrading This Guide to a New RHOAI Version

This guide tracks a specific RHOAI GA release. When a new version is announced, follow this workflow:

## 1. Prepare — stage the release docs

Before touching any code, gather the new version's release notes, supported configurations, and API changes into `docs.bkp/<version>/` (e.g. `docs.bkp/rhoai-3.6/`). This directory is not committed — it's a local scratchpad the assistant reads during the upgrade session.

## 2. Branch — create the upgrade branch

```bash
git checkout main
git checkout -b <version>-upgrade    # e.g. 3.6-upgrade
```

All upgrade work happens on this branch. `main` stays untouched until validation passes.

## 3. Upgrade — work through the changes

With the release docs in `docs.bkp/`, systematically update:
- **Operator manifests** (`gitops/operators/`) — subscriptions, CSV versions, channel changes
- **Instance charts** (`gitops/instance/`) — API group changes, new fields, new CRDs
- **Phase docs** (`docs/phases/`) — install commands, wait conditions, gotchas
- **Phase summaries** (`docs/phases/summaries/`) — one-page overviews
- **AGENTS.md** — version refs, phase summaries, new constraints
- **README.md** — version refs, prerequisite tables

Tell the assistant: *"Upgrade to RHOAI \<version\>. Release docs are in `docs.bkp/<version>/`. Read them and work through the changes."*

## 4. Test — validate on a live cluster

Deploy the upgrade branch against a cluster running the target OCP + RHOAI version. Walk through all phases (0–6) and confirm each human gate passes. Fix issues on the upgrade branch.

## 5. Snapshot — preserve the previous GA

If not already done, create a branch to preserve the current GA state:

```bash
git branch <old-version>-ga main    # e.g. 3.5-ga
git push origin <old-version>-ga
```

## 6. Merge — promote to main

```bash
git checkout main
git merge <version>-upgrade
git push origin main
```

`main` is now the current GA. The upgrade branch can be deleted.

## 7. Clean up

Remove `docs.bkp/<version>/` locally (it was never committed). Update any version-specific references that were missed during the upgrade.

## Branch convention

| Branch | Purpose |
|---|---|
| `main` | Current GA — always deployable |
| `<version>-ga` | Snapshot of a past GA release (e.g. `3.4-ga`, `3.5-ga`) |
| `<version>-upgrade` | Working branch for an in-progress upgrade (temporary) |
