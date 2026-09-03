# lunar-actions

Reusable GitHub Actions for [Lunar](https://docs.earthly.dev/) — Earthly's CI guardrails platform.

## Actions

| Action | Purpose |
| --- | --- |
| [`install`](#install) | Install a pinned Lunar CLI on the runner and export Hub settings for later steps |
| [`record-release`](#record-release) | Record that a commit was released, so Lunar shows it as a release |
| [`sync-config`](#sync-config) | Tell Lunar Hub to pull the latest config from your config repo |
| `sync-manifest` | Deprecated alias of `sync-config` |

For attaching the Lunar agent to a CI job (formerly `lunar-actions/attach`), use [`earthly/lunar-ci-action`](https://github.com/earthly/lunar-ci-action) — properly versioned, node20-based, and the action documented in the [`agent-managed`](https://docs-lunar.earthly.dev/install/agent-managed/) install guide.

### `install`

Downloads the Lunar CLI for the runner's OS and architecture from [lunar-dist](https://github.com/earthly/lunar-dist/releases), puts it on `PATH`, and by default exports `LUNAR_HUB_*` so later steps can call `lunar` directly. Works on GitHub-hosted and self-hosted runners. No `lunar-config.yml` is needed in the repository.

```yaml
- uses: earthly/lunar-actions/install@main
  with:
    version: v3.20.0
    hub-host: hub.example.com
    hub-token: ${{ secrets.LUNAR_HUB_TOKEN }}
- run: lunar version
```

#### Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `version` | yes | — | CLI version, as a [lunar-dist tag](https://github.com/earthly/lunar-dist/tags), e.g. `v3.20.0`. Pinned on purpose: there is no floating default. |
| `hub-host` | no | `""` | Lunar Hub hostname, exported as `LUNAR_HUB_HOST` |
| `hub-token` | no | `""` | Lunar Hub API token, masked and exported as `LUNAR_HUB_TOKEN` |
| `hub-grpc-port` | no | `443` | Exported as `LUNAR_HUB_GRPC_PORT` together with `hub-host` |
| `hub-http-port` | no | `443` | Exported as `LUNAR_HUB_HTTP_PORT` together with `hub-host` |
| `log-level` | no | `""` | Exported as `LUNAR_LOG_LEVEL` when set |
| `install-dir` | no | tool cache | Where to put the binary. Defaults to `$RUNNER_TOOL_CACHE/lunar/<version>/<arch>`, which persists between jobs on a self-hosted runner. |
| `checksum` | no | `""` | Expected SHA-256 of the binary. Verified when set. |
| `export-env` | no | `true` | Write the `LUNAR_HUB_*` values to `GITHUB_ENV` for every later step in the job. Set `false` to keep them step-scoped and pass `hub-*` to the steps that need them. |
| `download-base-url` | no | lunar-dist releases | Override to an internal mirror of lunar-dist on runners that cannot reach github.com. `<version>/<asset>` is appended. |

#### Outputs

| Name | Description |
| --- | --- |
| `lunar-path` | Absolute path to the installed binary |
| `version` | The version tag that was installed |
| `cache-hit` | `true` when an already-installed binary of this version was reused |

Supported runners are Linux x64, Linux arm64 and macOS arm64 — the binaries lunar-dist publishes. Anything else fails with a message naming the combination. lunar-dist does not publish checksums yet, so `checksum` is opt-in for teams that pin one themselves.

### `record-release`

Records a release against the released commit with `lunar collect`. That commit's Component JSON gains a `.release` object, which is how a release shows up in Lunar as a release rather than as one more commit. Needs the CLI on `PATH` (run `install` first) and Hub settings, either exported by `install` or passed here. No `lunar-config.yml` is needed.

```yaml
on:
  push:
    tags: ['v*']

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: earthly/lunar-actions/install@main
        with:
          version: v3.20.0
          hub-host: hub.example.com
          hub-token: ${{ secrets.LUNAR_HUB_TOKEN }}

      # ... build, test, publish ...

      - uses: earthly/lunar-actions/record-release@main
        with:
          image: registry.example.com/my-service:${{ github.ref_name }}
```

On a tag push that is all it takes: `component` defaults to the repository, `tag` to the pushed tag and `sha` to the released commit.

#### What gets written

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

`tag`, `sha`, `timestamp`, `author` and `workflow_run` are always written; `version` and `image` only when given. A commit counts as released when `.release.tag` is set. Set `artifact` to write under `.release.<artifact>` instead, for commits that ship several independently versioned artifacts.

#### Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `component` | no | the repository | Component id, e.g. `github.com/my-org/my-service`. Falls back to `$LUNAR_COMPONENT_ID`, then to `<server host>/<owner>/<repo>`. |
| `tag` | no | the pushed tag | Written to `.release.tag`. Required when the run is not a tag push. |
| `version` | no | `""` | Version without tag decoration, e.g. `1.2.3`. Written to `.release.version` when set. |
| `image` | no | `""` | Released image reference. Written to `.release.image` when set. |
| `sha` | no | `github.sha` | Released commit. Must resolve to a full 40-character SHA; with a checkout present, short SHAs and tag objects are resolved for you. |
| `author` | no | `github.actor` | Who released it |
| `timestamp` | no | now (UTC) | RFC 3339 |
| `workflow-run` | no | this run | URL of the run that recorded the release |
| `artifact` | no | `""` | Write under `.release.<artifact>`. Letters, digits, `-` and `_` only. |
| `hub-host`, `hub-token`, `hub-grpc-port`, `hub-http-port` | no | exported by `install` | Only needed when `install` ran with `export-env: false`. Ports default to `443`. |
| `lunar-path` | no | `lunar` on `PATH` | CLI binary to invoke |

#### Outputs

| Name | Description |
| --- | --- |
| `component` | The component the release was recorded against |
| `sha` | The full commit SHA the release was recorded against |
| `path` | `.release` or `.release.<artifact>` |

The component must already be cataloged in Lunar; the Hub does not create components from this call. The write lands immediately and re-runs are idempotent (the same keys are overwritten); the release renders in the dashboards once that commit has policy results. Verify with `lunar component get-json <component> --git-sha <sha>`.

### `sync-config`

Tells Lunar Hub to pull the latest config (manifest + snippets) from your config repo. Run this on every push to `main` of the config repo.

```yaml
- uses: earthly/lunar-actions/sync-config@main
  with:
    manifest-url: github://my-org/my-config-repo@main
    hub-token: ${{ secrets.LUNAR_HUB_TOKEN }}
    hub-host: hub.example.com
    lunar-version: v1.1.2
    rerun-code-collectors: "true"  # optional
    rerun-catalogers: "false"       # optional
```

#### Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `manifest-url` | yes | — | Config repo URL, `github://<org>/<repo>@<branch>` |
| `hub-token` | yes | — | Lunar Hub API token |
| `hub-host` | yes | — | Lunar Hub hostname |
| `lunar-version` | yes | — | Lunar CLI version tag (see [lunar-dist](https://github.com/earthly/lunar-dist/tags)) |
| `hub-grpc-port` | no | `443` | gRPC port on the Hub |
| `hub-http-port` | no | `443` | HTTP port on the Hub |
| `rerun-code-collectors` | no | `false` | Rerun affected code collectors after pulling |
| `include-pr-commits` | no | `false` | When rerunning collectors, also process PR commits |
| `pr-max-age-days` | no | `5` | Ignore PR commits older than this when rerunning collectors |
| `rerun-catalogers` | no | `false` | Rerun global catalogers after pulling. Per-component catalogers (`component-repo` / `component-cron`) are unaffected and continue to run on their own hooks. **Requires lunar v1.1.2+.** |
| `log-level` | no | `debug` | Lunar log level |
| `lunar-binary-path` | no | `/usr/local/bin/lunar` | Filesystem path to install the Lunar CLI. Override on self-hosted runners that can't write to `/usr/local/bin`. |

These inputs map 1:1 to the equivalent flags on `lunar hub pull`. See the [CLI reference](https://docs.earthly.dev/lunar/lunar-cli) for behavior details.

### `sync-manifest` (deprecated)

Kept as an alias for `sync-config` so existing pinned references keep working. New workflows should use `sync-config`. Will be removed in a future release.

## Versioning

Pin to `@main` for the latest, or to a release tag if you want a stable reference.
