# Lembos deploy — guide for Claude

Installs Lembos, whose source lives in [lembosproj/platform](https://github.com/lembosproj/platform). This
repository never builds an image: the chart pulls `ghcr.io/lembosproj/platform/<component>:<appVersion>`, which the
platform publishes. Read [README.md](./README.md) for the layout and the versioning.

## Commands

```shell
helm repo add dandydeveloper https://dandydeveloper.github.io/charts
helm repo add temporal https://go.temporal.io/helm-charts
helm dependency build charts/lembos                                   # what Chart.lock pins; needed to render
helm lint charts/lembos -f charts/lembos/ci/default-values.yaml
dotnet build Lembos.Deploy.slnx                                       # the getting-started app host
aspire start / aspire stop                                            # k3s + the published chart; Docker must be up
```

The app host installs **this directory's** chart with `aspire/Lembos.Deploy.AppHost/values.aspire.yaml`, at
`appVersion`, under `*.dev.localhost` with the AppHost's developer certificate, and runs Grafana on
`http://localhost:3000` (dashboards in `charts/lembos/dashboards`, shipped by the chart too). It uses
the k3s integration as `Lab.Aspire.Hosting.K3s`, a build of the CommunityToolkit pull request, until a
release carries it. Its kubeconfig is
`aspire/Lembos.Deploy.AppHost/.k3s/k3s/local/kubeconfig.yaml`; `source scripts/k3s-env.sh` exports it and adds
`k` (kubectl in `lembos`) and `lembos-admin-password`.

`.github/workflows/chart.yml` also renders every values file through `kubeconform -strict`; copy its loop to
reproduce a failure.

## Rules

- **The chart follows the platform, never leads it.** The `platform` section of `values.yaml` mirrors the
  platform's `PlatformConfig`, and the setup job's Secrets mirror its `LocalSetupSpec`. Nothing checks either,
  so a change to one starts in the platform repository and is carried here by hand.
- **`appVersion` names a published platform release.** Bump it to adopt one; the chart's own `version` comes
  from the tag and is never edited.
- **A dependency moves in `Chart.yaml` and `Chart.lock` together** (`helm dependency update`), in one change.
- **Comments say why**, as in the platform's `docs/code-conventions.md`; the chart's templates and values are
  the reference for density.
- **Docs travel with the chart.** A value added or changed is described in `values.yaml` and, when it changes
  how an install is shaped, in `charts/lembos/README.md`. Markdown must pass `markdownlint` with
  `.markdownlint.json`.

## Commits

Conventional prefixes — `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, `BREAKING CHANGE:` — with a body
explaining why. PRs follow `.github/pull_request_template.md`.
