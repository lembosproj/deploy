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
```

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
