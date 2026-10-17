# Lembos deploy

Everything that installs [Lembos](https://github.com/lembosproj/platform), the Internal Developer Platform,
somewhere other than a developer's machine. The platform repository builds and publishes the images; this
one installs them.

```shell
helm upgrade --install lembos oci://ghcr.io/lembosproj/charts/lembos --version 0.1.0 \
  --namespace lembos --create-namespace \
  --set global.domain=idp.example.com \
  --set identity.smtp.endpoint=smtp://relay.example.com:25
```

## Getting started

Run the whole platform on your machine — a k3s cluster in Docker with this repository's chart installed into
it, PostgreSQL, Temporal and MailPit beside it as Aspire resources, and Grafana over its traces, logs and
metrics:

```shell
aspire start
```

You need Docker with about 4 CPUs and 8 GiB to spare, the .NET 10 SDK and the [Aspire CLI](https://aspire.dev)
with a trusted developer certificate. The Portal is then at `https://portal.dev.localhost` and Grafana at
`http://localhost:3000`. The [chart README](./charts/lembos/README.md#running-locally-with-aspire) walks
through it: signing in, the dashboards, and what to look at when something is wrong.

## What is here

| Path                                                                   | What                                                                                                                                                        |
|------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| [`aspire`](./aspire/Lembos.Deploy.AppHost)                             | The getting-started app host: k3s, this chart, its dependencies and an observability stack as Aspire resources                                         |
| [`charts/lembos`](./charts/lembos)                                     | The Helm chart: the four services, a setup job that makes every Secret and key, and PostgreSQL, Redis and Temporal — simple, highly available or external   |
| [`scripts/sync-platform-schema.sh`](./scripts/sync-platform-schema.sh) | Copies the platform's generated values contract into the chart's `values.schema.json`, at the release `appVersion` names                                    |

The [chart's README](./charts/lembos/README.md) covers prerequisites, secrets, publishing, network policies,
and the high-available options.

Planned here, and not built yet: Terraform modules that provision a cluster and its managed dependencies
for the chart, and more app hosts beside the getting-started one — internal dependencies, high-available —
so every setup the chart supports is installed somewhere.

## Versions

The chart and the platform are released apart:

| Version                       | Set by                                         | Names                                                            |
|-------------------------------|------------------------------------------------|------------------------------------------------------------------|
| The chart's `version`         | A `v*` tag in this repository                  | `oci://ghcr.io/lembosproj/charts/lembos`                         |
| The chart's `appVersion`      | `Chart.yaml`, changed in a reviewed change     | `ghcr.io/lembosproj/platform/<component>`, published by platform |

So a chart fix ships without a platform release, and adopting a platform release is a one-line change to
`appVersion`. The release workflow refuses to publish a chart whose `appVersion` has no published images.

## Kept in step with the platform

Two things are defined in the platform repository and mirrored here by hand — nothing compares them, so a
change to one is made to the other by whoever makes it:

- **The configuration contract.** The `platform` section of `values.yaml` mirrors the platform's
  [`PlatformConfig`](https://github.com/lembosproj/platform/blob/main/src/AppHost/Lembos.AppHost/Platform/PlatformConfig.cs): the same
  settings, distributed to the same components.
- **The setup spec.** The Secrets and keys the setup job is asked for (`templates/setup/_spec.tpl`) are the
  ones the platform's app host asks the same tool for under `aspire start` (`LocalSetupSpec`).

## Contributing

Read [the contribution documentation](./CONTRIBUTING.md) and [the Code of Conduct](./CODE-OF-CONDUCT.md).

## License

[Apache-2.0](./LICENSE).
