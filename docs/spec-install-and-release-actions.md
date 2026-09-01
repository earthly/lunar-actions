# Spec: `install` and `record-release` actions

Status: **proposed** — no implementation in this PR.

Two new actions for `earthly/lunar-actions`:

1. **`install`** — put the Lunar CLI on a runner and wire up Hub credentials.
2. **`record-release`** — record that a commit was released, so it appears on the
   Release Ledger as a release rather than as another commit.

Today a workflow that wants either has to paste `curl`/`chmod` steps and a raw
`lunar collect` invocation into its own YAML.

---

## Findings that shape the design

These were established by reading the Hub and the dashboards, and by querying
two live installations. They are the reason the design below looks the way it
does, so they are worth reading before the input tables.

### 1. The Release Ledger's definition of "a release" is `.deployment.attempts`

A commit appears as a release when **both** hold:

- it has at least one scored check (`enforcement <> 'draft'`, `status <> 'skipped'`), and
- `.deployment.attempts` is a JSON **object** with at least one entry whose
  `status` is `approved`.

The shape is a map keyed by CI workflow-run id, values `{status, author, created_at}`:

```json
{
  "deployment": {
    "attempts": {
      "18234567890": {
        "status": "approved",
        "author": "octocat",
        "created_at": "2026-09-01T12:00:00Z"
      }
    }
  }
}
```

Sources — `grafana/sql/component/release_history.sql:146-166` (the Deployment
history tab's `Deployed` column) and `grafana/sql/release-ledger/var_from_sha.sql:9-10,38-46`
plus `release-notes.sql` (the ledger's release-range baseline). The comment at
`release_history.sql:150` states `.deployment` is the canonical CD category.

There is **no `lunar release` command**. Release association is a `lunar collect`
write; the ledger is a Grafana dashboard over the resulting Component JSON.

The payload above was checked against the reader's own SQL — the `jsonb_each` /
`jsonb_typeof` expressions lifted verbatim out of `release_history.sql:151-161`
and `var_from_sha.sql:38-46` — run over synthetic blobs, with control arms for
each way it could plausibly be got wrong:

| Blob | `total` | `approved` | qualifies as a release |
| --- | ---: | ---: | --- |
| **proposed** — `attempts` an object, `status: approved` | 1 | 1 | **yes** |
| `attempts` an array instead of an object | 0 | 0 | no |
| `status` something other than `approved` | 1 | 0 | no |
| `.release.tag` only, no `.deployment` | 0 | 0 | no |
| `.deployment` present but no `attempts` key | 0 | 0 | no |

Two of those controls are worth dwelling on. The array case scores zero rather
than erroring, which is the silent failure this shape invites. And the
`.release.tag`-only case is the one an implementation would most naturally
land on from reading the ticket — it writes something plausible, the CLI call
succeeds, and the ledger stays empty.

The third row is the intended behaviour of the `status` input: a non-`approved`
attempt is still counted in `total`, so the Deployment history tab shows
"attempted, none approved" rather than nothing at all.

### 2. Nothing writes that path today — the column has never had data

`.deployment.attempts` is read in three places and written in none. Greps over
`earthly/lunar` and `earthly/lunar-lib` at `origin/main` find no writer: not a
collector, not Hub code, not an e2e test.

Confirmed against live data on two installations:

| Installation | default-branch component records | `.deployment.attempts` present | `.deployment` present | `.release` present |
|---|---:|---:|---:|---:|
| staging | 483,152 | 0 | 0 | 9 |
| internal | 3,552 | 0 | 0 | 27 |

So the `Deployed` column on every component's Deployment history tab, and the
ledger's release-range baseline selector, are inert everywhere — waiting on a
producer. **That producer is this action.** It is also why the payload shape
below has to match the reader exactly: there is no existing data to compare
against, and a near-miss (an array instead of an object, a different status
string) fails silently — the write succeeds and the ledger simply stays empty.

The 36 rows carrying `.release` are `.release.ticket` from the ticket collectors,
plus a single hand-made `.release.version = "v1.2.3"`. So `.release` is a live
namespace with room in it.

The documented key is `.release.tag`, not `.release.version`: `.release.tag`
appears 8 times across `docs/` and `cmd/` — including the `lunar collect` help
text and `docs/bash-sdk/collector.md:84` — alongside `.release.image`.
`.release.version` appears in no doc. This spec follows the documented spelling
and treats that one live row as a one-off.

`.deployment` is not in `ai-context/component-json/structure.md`'s category list
in `lunar-lib`. That is a docs gap in a different repo, noted under Follow-ups.

### 3. `lunar collect` genuinely needs no `lunar-config.yml`

`cmd/lunar/main.go:101-108` returns early when the file is absent
(`if !exists { return nil }`) — it is read only to *default* Hub host/ports when
they aren't already set. Host and token from the environment are sufficient. The
ticket's constraint checks out, and the README should say so plainly.

### 4. Hub-side constraints on the write

From `hub/collect_external.go:36-131`:

- The SHA must be **40 lowercase hex characters** — a short SHA or uppercase is
  rejected with `InvalidArgument`.
- The component must **already be in the catalog**; the RPC never auto-creates
  one (`NotFound: component not found`).
- The write does **not** require the commit to be VCS-ingested. Ingestion gates
  the *policy re-evaluation* (`hub/server.go:2618`), not the write.

That last point interacts with finding 1: the write lands immediately, but the
release only *renders* once the commit also has scored checks. Worth stating in
the README so "I ran the action and the ledger is empty" is self-diagnosable.

### 5. Numeric path segments are safe

`.deployment.attempts.<run_id>` uses a numeric key. `util/maps.Add` creates a
`map[string]any` for every intermediate segment and never an array, so the
result satisfies the reader's `jsonb_typeof(...) = 'object'` guard.

Same function: `Add` returns early when the value is `""`, so an empty input is
dropped rather than written as an empty string.

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

   Anything else fails with a message naming the combination. Every `lunar-dist`
   release carries exactly these three assets (spot-checked across the four most
   recent), so `macOS/X64` and Windows have no binary and should say so rather
   than 404 on a guessed filename.

   The existing `sync-config` hardcodes `lunar-linux-amd64`, which is a latent
   failure on the self-hosted ARM runners this ticket cares about.

2. **Choose the install directory** — `install-dir` when set, otherwise
   `$RUNNER_TOOL_CACHE/lunar/<version>/<arch>`, falling back to `$RUNNER_TEMP`
   when the tool cache is unset.

3. **Reuse if present** — if the binary is already there and `lunar version`
   reports `version`, set `cache-hit=true` and skip the download. Verifying by
   invoking the binary rather than trusting the path means a truncated or
   half-written file from an interrupted run is replaced rather than reused.

4. **Otherwise download** with `curl -fsSL --retry 3 --retry-all-errors`, then
   `chmod +x`, then verify `checksum` if supplied.

   `-f` is the load-bearing flag. Without it curl writes the 404 body to the
   output path and `chmod +x` succeeds, so the failure surfaces later as a
   confusing "cannot execute binary file" in an unrelated step. `sync-config`
   currently uses bare `curl -L` and has this behaviour.

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
    version: ${{ github.ref_name }}
```

### Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `component` | no | `$LUNAR_COMPONENT_ID`, else derived from `github.server_url` + `github.repository` | Component id, e.g. `github.com/my-org/my-service`. Monorepo sub-components take the path form `github.com/my-org/my-repo/services/api`. |
| `version` | no | `github.ref_name` when the ref is a tag, else empty | Release version or tag. Written to `.release.tag`, the documented key. |
| `image` | no | `''` | Released image reference, e.g. `registry.example.com/my-app:v1.2.3`. Written to `.release.image`. Omitted when empty. |
| `sha` | no | `github.sha` | Released commit. Must be 40 lowercase hex. |
| `status` | no | `approved` | Attempt outcome. Only `approved` marks the commit as released; any other value records an attempt that did not succeed. |
| `author` | no | `github.actor` | Who released it. |
| `attempt-id` | no | `github.run_id` | Key for this attempt under `.deployment.attempts`. |
| `created_at` | no | current UTC time | RFC 3339 timestamp. |
| `hub-host` / `hub-token` / `hub-grpc-port` / `hub-http-port` | no | inherited from the environment | Only needed when `install` ran with `export-env: false`. |
| `lunar-path` | no | `lunar` | Binary to invoke; resolved from `PATH` by default. |

### Outputs

| Name | Description |
| --- | --- |
| `component` | The resolved component id. |
| `sha` | The resolved commit SHA. |
| `attempt-id` | The key written under `.deployment.attempts`. |

### Behaviour

A single `lunar collect` call, so the Hub records one collection and enqueues
one policy re-evaluation:

```bash
lunar collect --component "$COMPONENT" --sha "$SHA" -j \
  ".deployment.attempts.$ATTEMPT_ID" "$(jq -nc \
      --arg s "$STATUS" --arg a "$AUTHOR" --arg t "$CREATED_AT" \
      '{status:$s, author:$a, created_at:$t}')" \
  ".release.tag" "$(jq -nc --arg v "$VERSION" '$v')"
```

`-j` applies to every value in the call, so both are JSON-encoded — the tag
string included, which is why it goes through `jq` rather than being passed
bare. `.release.tag` and `.release.image` are each omitted entirely when their
input is empty; `util/maps.Add` would drop an empty value anyway (finding 5),
but omitting the pair keeps the call honest about what it is writing.

Before calling, validate `sha` against `^[0-9a-f]{40}$` and fail with a message
naming the offending value. The Hub rejects anything else with a bare
`InvalidArgument`, which is hard to act on from a workflow log.

### Why write both paths

`.deployment.attempts` is what the ledger reads (finding 1) and is what makes
"the release lands in the ledger" true. `.release.tag` is the human-readable
identity the ticket asks for; no dashboard reads it today, but it is the
documented key for exactly this, it is cheap, and it is what a policy or a future
ledger column would reach for. Writing only `.release.tag` would satisfy the
ticket's wording while leaving the ledger empty — which is the trap this spec
exists to avoid.

### On `jq`

`jq` is present on GitHub-hosted runners but is not guaranteed on a self-hosted
one. Since self-hosted support is an explicit requirement, the implementation
should either build the JSON with `printf` and escape the four inputs itself, or
check for `jq` and fail with a clear message. Flagged as an open question below.

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
          version: ${{ github.ref_name }}
```

No `lunar-config.yml` in the repository (finding 3).

---

## Open questions for review

1. **Two actions, or one `lunar` action with a mode?** The ticket raises this.
   Recommending two: `install` is a setup step that other actions and hand-rolled
   `lunar` calls both build on, and it is the shape every `setup-*` action in the
   ecosystem uses. A mode flag would make `version` mean two different things.

2. **`record-release` as the name.** Alternatives: `associate-release`, matching
   the ticket's wording; or `deploy` / `record-deployment`, matching the data
   model, which is a *deployment attempt* rather than a release. The ledger calls
   the artefact a release, so `record-release` reads better at the call site,
   but it does hide that a non-`approved` status is also expressible.

3. **Should `record-release` install the CLI if it is missing?** Currently it
   assumes `install` ran. Auto-installing would make it usable standalone at the
   cost of needing its own `version` input and a second download path.

4. **`jq` dependency** — escape in shell, or require `jq` and fail clearly?

5. **`export-env: true` as the default** puts `LUNAR_HUB_TOKEN` in `$GITHUB_ENV`,
   where every later step in the job can read it. It is masked in logs and is the
   convenience the ticket asks for, but it is a wider blast radius than a
   step-scoped `env:`. Default to `true` for ergonomics, or `false` for least
   privilege?

6. **`.deployment` vs `.cd`.** The dashboards read `.deployment.attempts` and
   call it canonical; `lunar-lib`'s ArgoCD collectors write `.cd.gitops`, and
   `.deployment` is absent from the documented category list. This action should
   follow the reader — the dashboards — but the divergence is worth a decision.

## Follow-ups (separate tickets, not this PR)

- `lunar-dist` publishes no checksums or signatures for the CLI binaries. That
  blocks verified installs for exactly the regulated customers this ticket
  targets.
- `earthly/lunar-actions` has **no tags and no releases**, while its README says
  to "pin to a release tag". The ticket's "versions are pinned, not floating"
  cannot be satisfied by consumers until this repo cuts a `v1`. The `@v1` used
  throughout this spec assumes that happens alongside the implementation.
- `.deployment` should be documented as a Component JSON category in
  `lunar-lib`'s `ai-context/component-json/structure.md`, and the `.cd`
  divergence resolved.
