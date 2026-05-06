# lunar-actions

Reusable GitHub Actions for [Lunar](https://docs.earthly.dev/) — Earthly's CI guardrails platform.

## Actions

### `attach`

Attaches the Lunar agent to the current CI job so it can trace and report on workflow execution.

```yaml
- uses: earthly/lunar-actions/attach@main
  with:
    manifest-url: github://my-org/my-config-repo@main
    hub-token: ${{ secrets.LUNAR_HUB_TOKEN }}
    hub-host: hub.example.com
```

### `sync-config`

Tells Lunar Hub to pull the latest config (manifest + snippets) from your config repo. Run this on every push to `main` of the config repo.

```yaml
- uses: earthly/lunar-actions/sync-config@main
  with:
    manifest-url: github://my-org/my-config-repo@main
    hub-token: ${{ secrets.LUNAR_HUB_TOKEN }}
    hub-host: hub.example.com
    lunar-version: v1.1.1
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

These inputs map 1:1 to the equivalent flags on `lunar hub pull`. See the [CLI reference](https://docs.earthly.dev/lunar/lunar-cli) for behavior details.

### `sync-manifest` (deprecated)

Kept as an alias for `sync-config` so existing pinned references keep working. New workflows should use `sync-config`. Will be removed in a future release.

## Versioning

Pin to `@main` for the latest, or to a release tag if you want a stable reference.
