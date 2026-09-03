# Spec: `install` and `record-release` actions

Status: **proposed, revision 2** — no implementation in this PR.

Revision 2 incorporates the first review round:

- `record-release` writes a flat `.release.*` object of plain strings, modelled on
  the `lunar collect` step in `earthly/lunar`'s own release workflow. The
  `.deployment.attempts` map from revision 1 is gone (see finding 5 for why).
- No `jq`: string values need no JSON encoding, so the action is a single
  `lunar collect` with `key value` pairs.
- Customer-specific vocabulary removed. The dashboards are referred to by what
  they show.
- Open questions cut from six to three; the rest are decided below.

Two new actions for `earthly/lunar-actions`:

1. **`install`** — put the Lunar CLI on a runner and wire up Hub credentials.
2. **`record-release`** — record that a commit was released, so the release
   dashboards show it as a release rather than as one more commit.

Today a workflow that wants either has to paste `curl`/`chmod` steps and a raw
`lunar collect` invocation into its own YAML.

---

## Findings that shape the design

### 1. `earthly/lunar` already does this by hand

`.github/workflows/release.yml` (job `record-release`) installs the CLI from
`lunar-dist`, then records the release out-of-band:

```bash
lunar collect \
  --component github.com/earthly/lunar \
  --sha "$SHA" \
  ".release.${ARTIFACT}.tag" "$TAG" \
  ".release.${ARTIFACT}.version" "$VERSION" \
  ".release.${ARTIFACT}.sha" "$SHA" \
  ".release.${ARTIFACT}.timestamp" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  ".release.${ARTIFACT}.workflow_run" "$RUN_URL" \
  ".release.${ARTIFACT}.${loc_key}" "$loc_val"   # image or dist_url
```

Plain strings, no `--json`, one call. The keys nest under the artifact name
because one `lunar` commit ships three artifacts (`lunar`, `lunar-hub`,
`lunar-scripts`), each with its own version. `record-release` is that step,
generalised: the same keys, with the nesting optional.

### 2. `.release.tag` is the documented key

The `lunar collect` help text (`cmd/lunar/collect.go`) and
`docs/bash-sdk/collector.md` § "Out-of-band collection" both use
`.release.tag` (and `.release.image`) as *the* example of associating a
release with a commit. This spec keeps that spelling and builds the rest of the
object around it.

### 3. `lunar collect` needs no `lunar-config.yml`

`cmd/lunar/main.go` returns early when the file is absent — it is read only to
*default* Hub host/ports when they are not already set. Host and token from the
environment are sufficient. The ticket's constraint checks out, and the README
should say so plainly.

### 4. Hub-side constraints on the write

From `hub/collect_external.go`:

- The SHA must be **40 lowercase hex characters** — a short SHA or uppercase is
  rejected with `InvalidArgument`.
- The component must **already be in the catalog**; the RPC never auto-creates
  one (`NotFound: component not found`).
- The write does **not** require the commit to be VCS-ingested. It lands
  immediately and enqueues a policy re-evaluation for that SHA.
- The write is a merge into the `(component, sha)` blob: re-running a release
  overwrites the same keys, so a re-run is idempotent.

Worth stating in the README so "I ran the action and nothing shows up" is
self-diagnosable: the release *renders* once the commit has scored checks.

### 5. Why not `.deployment.attempts`

The component **Deployment history** tab's `Deployed` column and the release
notes' baseline picker currently read `.deployment.attempts` — a map keyed by CI
workflow-run id whose values are `{status, author, created_at}`. Revision 1
wrote that shape so the column would light up. It is dropped in revision 2:

- **Nothing produces it.** Zero rows on both installations queried (staging:
  483,152 default-branch records; internal: 3,552). The reader was added ahead
  of a deployment-gate collector that was never built, so there is no
  compatibility to preserve.
- **It models the wrong thing.** A map of approve/reject attempts describes a
  *deployment gate*, which the ticket explicitly leaves out of scope. A release
  association is a fact about one commit, not a series of outcomes.
- **It is a worse consumer contract.** `jsonb_each` over a dynamic-key map to
  answer "was this released?" versus `->'release'->>'tag'`.
- **`.deployment` is not the CD namespace.** `lunar-lib` settled `.cd` over
  `.deployment` for CD data (`.agents/plans/argocd-collector.md`), and neither
  is documented in `component-json/structure.md`.

Consequence: until the dashboards are re-pointed at `.release.tag` (a small
change to three SQL files in `earthly/lunar`, listed under Follow-ups) the
`Deployed` column stays empty regardless of this action. That is the right
order — standardise the producer first, then read it.

### 6. Plain strings, no encoding

Without `--json`, `lunar collect` stores each value as a string, so nothing has
to be escaped and `jq` is not needed — which matters on self-hosted runners
where it is not guaranteed. `util/maps.Add` also drops a value of `""`, but the
action omits empty optional pairs rather than relying on that.

---

## The `.release` shape

This is the standard the spec proposes for "this commit was released":

```json
{
  "release": {
    "tag": "v1.2.3",
    "version": "1.2.3",
    "sha": "0123456789abcdef0123456789abcdef01234567",
    "timestamp": "2026-09-03T12:00:00Z",
    "author": "octocat",
    "workflow_run": "https://github.com/my-org/my-service/actions/runs/18234567890",
    "image": "registry.example.com/my-service:v1.2.3"
  }
}
```

| Key | Written | Meaning |
| --- | --- | --- |
| `tag` | always | The release identity. **Consumers need only this key: a commit is released iff `.release.tag` is set.** |
| `sha` | always | The released commit. Redundant with the record's own SHA, kept so the JSON is self-describing (as `release.yml` does). |
| `timestamp` | always | When it was recorded, RFC 3339 UTC. |
| `author` | always | Who released it (`github.actor` by default). |
| `workflow_run` | always | URL of the run that recorded it — the audit link. |
| `version` | when given | Version without tag decoration, e.g. `1.2.3` for tag `v1.2.3`. |
| `image` | when given | The released image reference. |

**Multi-artifact commits.** When the `artifact` input is set, the same object is
written under `.release.<artifact>` instead of `.release` — exactly the shape
`earthly/lunar` writes today. Single-artifact repositories, which is nearly all
of them, never see this.

---

## Action 1: `install`

```yaml
- uses: earthly/lunar-actions/install@v1
  with:
    version: v3.18.0
    hub-host: hub.example.com
    hub-token: ${{ secrets.LUNAR_HUB_TOKEN }}
```

Later steps then call `lunar` directly, with Hub connectivity already in the
environment.

### Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `version` | yes | — | CLI version tag, e.g. `v3.18.0`. No default: per the ticket, pinned not floating. |
| `hub-host` | no | `''` | Sets `LUNAR_HUB_HOST` for subsequent steps. |
| `hub-token` | no | `''` | Sets `LUNAR_HUB_TOKEN` for subsequent steps. |
| `hub-grpc-port` | no | `443` | Sets `LUNAR_HUB_GRPC_PORT`. |
| `hub-http-port` | no | `443` | Sets `LUNAR_HUB_HTTP_PORT`. |
| `log-level` | no | `''` | Sets `LUNAR_LOG_LEVEL` when non-empty. |
| `install-dir` | no | `''` | Where to put the binary. Empty means the runner tool cache (see below). |
| `checksum` | no | `''` | Optional SHA-256 of the binary. Verified when set. |
| `export-env` | no | `true` | Write the `LUNAR_HUB_*` values to `$GITHUB_ENV`. Set `false` to keep them step-scoped. |

### Outputs

| Name | Description |
| --- | --- |
| `lunar-path` | Absolute path to the installed binary. |
| `version` | The version that was installed. |
| `cache-hit` | `true` when an existing binary was reused. |

### Behaviour

1. **Resolve the asset** from `RUNNER_OS`/`RUNNER_ARCH`:

   | `RUNNER_OS` | `RUNNER_ARCH` | Asset |
   | --- | --- | --- |
   | `Linux` | `X64` | `lunar-linux-amd64` |
   | `Linux` | `ARM64` | `lunar-linux-arm64` |
   | `macOS` | `ARM64` | `lunar-darwin-arm64` |

   Anything else fails with a message naming the combination. Every
   `lunar-dist` release carries exactly these three assets, so `macOS/X64` and
   Windows have no binary and should say so rather than 404 on a guessed
   filename. (The existing `sync-config` hardcodes `lunar-linux-amd64`, a
   latent failure on the self-hosted ARM runners this ticket cares about.)

2. **Choose the install directory** — `install-dir` when set, otherwise
   `$RUNNER_TOOL_CACHE/lunar/<version>/<arch>`, falling back to `$RUNNER_TEMP`
   when the tool cache is unset.

3. **Reuse if present** — if the binary is already there and `lunar version`
   reports `version`, set `cache-hit=true` and skip the download. Verifying by
   invoking the binary means a truncated file from an interrupted run is
   replaced rather than reused.

4. **Otherwise download** with `curl -fsSL --retry 3 --retry-all-errors`, then
   `chmod +x`, then verify `checksum` if supplied.

   `-f` is the load-bearing flag. Without it curl writes the 404 body to the
   output path and `chmod +x` succeeds, so the failure surfaces later as a
   confusing "cannot execute binary file". `sync-config` uses bare `curl -L`
   and has this behaviour today.

5. **Add to `PATH`** via `$GITHUB_PATH`.

6. **Export Hub env** when `export-env` is true: emit `::add-mask::` for the
   token first, then write the non-empty values to `$GITHUB_ENV`.

### Why the tool cache rather than `actions/cache`

On a self-hosted runner `RUNNER_TOOL_CACHE` persists between jobs on the same
machine and needs no network. `actions/cache` round-trips to a GitHub-hosted
cache service, which is often exactly what is blocked in the restricted-egress
environments this ticket is aimed at. On hosted runners the tool cache is fresh
each job, but the download is a single binary — the cost of a miss is small.

This also keeps `install` free of `uses:` dependencies on third-party actions,
which matters for customers who mirror or vet every action they run.

### Not in scope

No checksums or signatures are published alongside the `lunar-dist` binaries
today, so `install` cannot verify by default — hence `checksum` as an opt-in for
customers who pin one themselves. Publishing checksums is a `lunar-dist` change;
see Follow-ups.

---

## Action 2: `record-release`

```yaml
- uses: earthly/lunar-actions/record-release@v1
  with:
    component: github.com/my-org/my-service
    tag: ${{ github.ref_name }}
```

### Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `component` | no | `$LUNAR_COMPONENT_ID`, else `github.server_url` host + `/` + `github.repository` | Component id, e.g. `github.com/my-org/my-service`. Monorepo sub-components take the path form `github.com/my-org/my-repo/services/api`. |
| `tag` | no | `github.ref_name` when `github.ref_type` is `tag` | Release tag, written to `.release.tag`. Fails with a clear message if neither the input nor the ref supplies one. |
| `version` | no | `''` | Version without decoration, written to `.release.version`. Omitted when empty. |
| `image` | no | `''` | Released image reference, written to `.release.image`. Omitted when empty. |
| `sha` | no | `github.sha` | Released commit. Must resolve to 40 lowercase hex. |
| `author` | no | `github.actor` | Who released it. |
| `timestamp` | no | current UTC time | RFC 3339. |
| `workflow-run` | no | `github.server_url`/`github.repository`/actions/runs/`github.run_id` | Audit link. |
| `artifact` | no | `''` | When set, write under `.release.<artifact>` instead of `.release`. |
| `hub-host` / `hub-token` / `hub-grpc-port` / `hub-http-port` | no | inherited from the environment | Only needed when `install` ran with `export-env: false`. |
| `lunar-path` | no | `lunar` | Binary to invoke; resolved from `PATH` by default. |

### Outputs

| Name | Description |
| --- | --- |
| `component` | The resolved component id. |
| `sha` | The resolved commit SHA. |
| `path` | The JSON path the object was written to: `.release` or `.release.<artifact>`. |

### Behaviour

1. **Resolve `sha`.** If the workflow has checked out the repository, run
   `git rev-parse --verify "$SHA^{commit}"` so a short SHA or a tag object
   becomes the commit the Hub requires (`release.yml` does the same). Then
   validate against `^[0-9a-f]{40}$` and fail naming the offending value — the
   Hub's bare `InvalidArgument` is hard to act on from a workflow log.

2. **Require `tag`.** Fail if it is empty after defaulting: writing a release
   with no identity is the one thing this action must never do silently.

3. **One `lunar collect` call**, so the Hub records one collection and enqueues
   one policy re-evaluation:

   ```bash
   P=".release${ARTIFACT:+.$ARTIFACT}"
   args=(
     "$P.tag"          "$TAG"
     "$P.sha"          "$SHA"
     "$P.timestamp"    "$TIMESTAMP"
     "$P.author"       "$AUTHOR"
     "$P.workflow_run" "$RUN_URL"
   )
   [ -n "$VERSION" ] && args+=("$P.version" "$VERSION")
   [ -n "$IMAGE" ]   && args+=("$P.image"   "$IMAGE")

   lunar collect --component "$COMPONENT" --sha "$SHA" "${args[@]}"
   ```

   No `--json`, no `jq` (finding 6).

`record-release` does not install the CLI. It assumes `install` ran earlier in
the job (or `lunar` is otherwise on `PATH`) and fails with a message pointing at
`install` if it is not. Keeping the two composable avoids a second download path
and a second `version` input.

---

## End-to-end example

```yaml
name: release
on:
  push:
    tags: ['v*']

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: earthly/lunar-actions/install@v1
        with:
          version: v3.18.0
          hub-host: hub.example.com
          hub-token: ${{ secrets.LUNAR_HUB_TOKEN }}

      # ... build, test, publish ...

      - uses: earthly/lunar-actions/record-release@v1
        with:
          component: github.com/my-org/my-service
          image: registry.example.com/my-service:${{ github.ref_name }}
```

No `lunar-config.yml` in the repository (finding 3). `tag` defaults to the
pushed tag. The resulting Component JSON for that commit gains the `.release`
object shown above; verify with
`lunar component get-json github.com/my-org/my-service --git-sha <sha>`.

---

## Open questions for review

1. **Two actions, or one `lunar` action with a mode?** The ticket raises this.
   Recommending two: `install` is a setup step that other actions and hand-rolled
   `lunar` calls both build on, and it is the shape every `setup-*` action in the
   ecosystem uses. A mode flag would make `version` mean two different things.

2. **`export-env: true` as the default** puts `LUNAR_HUB_TOKEN` in `$GITHUB_ENV`,
   where every later step in the job can read it. It is masked in logs and is the
   convenience the ticket asks for, but it is a wider blast radius than a
   step-scoped `env:`. Default to `true` for ergonomics, or `false` for least
   privilege?

3. **`artifact` nesting in v1?** It is the one piece of `release.yml`'s shape
   that a single-artifact repository never needs. Including it lets
   `earthly/lunar` replace its hand-rolled step with the action (a natural first
   consumer and integration test); leaving it out keeps the consumer rule to
   exactly one key everywhere. Leaning towards including it.

Decided since revision 1: the name stays `record-release` (it is what
`earthly/lunar` calls the job); `record-release` does not auto-install the CLI;
values are plain strings so there is no `jq` question; `.deployment` is not
used.

## Follow-ups (separate tickets, not this PR)

- **Re-point the dashboards' released-commit signal at `.release.tag`.** Three
  SQL files in `earthly/lunar` (`grafana/sql/component/release_history.sql`,
  `grafana/sql/release-ledger/var_from_sha.sql`,
  `grafana/sql/release-ledger/release-notes.sql`) currently test
  `.deployment.attempts`; the predicate becomes
  `j->'release'->>'tag' IS NOT NULL`. Until this lands the `Deployed` column
  stays empty for everyone.
- **Replace `release.yml`'s hand-rolled step** in `earthly/lunar` with
  `record-release` once it exists (the `.release.signoff.*` keys stay as they
  are — they are a sign-off audit, not a release record).
- **Document `.release`** as a Component JSON category in `lunar-lib`'s
  `ai-context/component-json/structure.md`.
- `lunar-dist` publishes no checksums or signatures for the CLI binaries. That
  blocks verified installs for exactly the regulated customers this ticket
  targets.
- `earthly/lunar-actions` has **no tags and no releases**, while its README says
  to "pin to a release tag". The ticket's "versions are pinned, not floating"
  cannot be satisfied by consumers until this repo cuts a `v1`. The `@v1` used
  throughout this spec assumes that happens alongside the implementation.
