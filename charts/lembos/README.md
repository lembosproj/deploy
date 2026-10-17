# Lembos Helm chart

Installs Lembos — Identity, the Orchestrator, the Portal and the platform Worker — with PostgreSQL, Redis and
Temporal each simple, highly available, or supplied as external services.

```shell
helm upgrade --install lembos oci://ghcr.io/lembosproj/charts/lembos --version 0.1.0 \
  --namespace lembos --create-namespace \
  --set global.domain=idp.example.com \
  --set identity.smtp.endpoint=smtp://relay.example.com:25
```

From a checkout of this repository, fetch the dependencies first and install the directory instead:

```shell
helm repo add dandydeveloper https://dandydeveloper.github.io/charts
helm repo add temporal https://go.temporal.io/helm-charts
helm dependency build charts/lembos
helm upgrade --install lembos charts/lembos --namespace lembos --create-namespace \
  --set global.domain=idp.example.com --set identity.smtp.endpoint=smtp://relay.example.com:25
```

The SMTP relay is the one value with no default: outside Development, Identity refuses to start with nowhere
to send invitations and password resets, so the chart refuses to render first.

## Prerequisites

| When                                         | Needs                                                       | Checked by the chart |
|----------------------------------------------|-------------------------------------------------------------|----------------------|
| Always                                       | Kubernetes 1.27+, an ingress controller or a Gateway        | —                    |
| Installing from a checkout                   | `helm dependency build` (fetches `redis-ha`, `temporal-ha`) | Helm                 |
| `postgresql.mode: high-available`            | The CloudNativePG operator, 1.25 or later                   | Yes                  |
| `gateway.enabled`                            | Gateway API CRDs (`gateway.networking.k8s.io/v1`)           | Yes                  |
| Autoscaling (on in a high-available install) | A metrics server                                            | —                    |
| `worker.autoscaling.scaler: keda`            | KEDA 2.17 or later                                          | Yes                  |

**High-available PostgreSQL is a CloudNativePG cluster**, and the operator is the one thing this chart cannot
bring with it. The chart renders the `Cluster` and the `Database` resources; the operator, installed once per
cluster, turns them into instances, replication, failover and the `-rw` Service that follows the primary.
`Database` resources arrived in CloudNativePG 1.25, hence the minimum:

```shell
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg cnpg/cloudnative-pg --namespace cnpg-system --create-namespace
```

Operators are cluster-wide — CRDs and a controller watching every namespace — so they are installed by whoever
runs the cluster rather than by each release; a chart that bundled one would fight a second release, or the
platform team's own copy, over it. A cluster without the operator can still run a high-available install
against `postgresql.mode: external` (a managed database). High-available Redis and Temporal need nothing
installed beforehand: they are ordinary workloads from the two upstream charts above.

The chart checks for what it marks "Yes" before rendering anything, and fails naming what to install, rather
than leaving the API server to refuse an unknown kind. `helm install` and `helm upgrade` ask the cluster; Argo
CD passes the cluster's API versions too. A plain `helm template` has no cluster to ask, so it is told:
`--api-versions postgresql.cnpg.io/v1/Cluster --api-versions postgresql.cnpg.io/v1/Database`.

## Install mode

`installMode` sets the shape of the whole release, and is the default for everything that does not state
its own:

| `installMode`    | Services                                           | Dependencies                              |
|------------------|----------------------------------------------------|-------------------------------------------|
| `simple`         | One pod each                                       | One pod each, as `aspire start` runs them |
| `high-available` | Two each, spread across nodes, with disruption     | Failover — see [Dependencies]             |
|                  | budgets; the Orchestrator and the Worker autoscale |                                           |

[Dependencies]: #dependencies

A component's own `replicas`, `autoscaling.enabled` or `podDisruptionBudget.enabled`, and a dependency's own
`mode`, override it — a simple install can still use an external PostgreSQL. The reverse is refused: a
high-available install with a simple dependency fails to render, because two of everything in front of one
PostgreSQL pod is still one pod from an outage.

The `platform` section of [`values.yaml`](./values.yaml) mirrors
[`PlatformConfig`](https://github.com/lembosproj/platform/blob/main/src/AppHost/Lembos.AppHost/Platform/PlatformConfig.cs), the platform's configuration contract.
The app host distributes each of its settings to the components that act on it
(`PlatformConfiguration.Build`), and these templates do the same distribution — so a setting means the same
thing under `aspire start` and in a cluster.

## What gets installed

| Component    | Kind                     | Published               | Notes                                                  |
|--------------|--------------------------|-------------------------|--------------------------------------------------------|
| Setup job    | Job (pre-install hook)   | —                       | Makes every Secret exist before anything else starts   |
| Identity     | Deployment               | `identity.<domain>`     | The OIDC issuer. Its admin listener is internal only   |
| Orchestrator | Deployment               | `orchestrator.<domain>` | `/graphql`, including subscriptions over WebSocket     |
| Portal       | Deployment               | `portal.<domain>`       | Blazor Server: every session is a WebSocket circuit    |
| Worker       | Deployment               | —                       | Reached by nobody; a workspace volume per pod          |
| PostgreSQL   | StatefulSet, or Cluster  | —                       | `postgresql.mode`; HA needs the CloudNativePG operator |
| Redis        | StatefulSet, or redis-ha | —                       | `redis.mode`                                           |
| Temporal     | auto-setup, or its chart | —                       | `temporal.mode`                                        |
| Temporal UI  | Deployment               | `temporal.<domain>`     | Internal unless `temporal.ui.ingress.enabled`          |
| MailPit      | Deployment               | `mail.<domain>`         | Only with `mailpit.enabled`; catches Identity's mail   |

Each service has its own ServiceAccount with no token mounted, a NetworkPolicy, and a
HorizontalPodAutoscaler and PodDisruptionBudget as `installMode` or its own settings decide.

## Images

The five images are built and published by [lembosproj/platform](https://github.com/lembosproj/platform),
one per version tag there, as public packages:

```text
ghcr.io/lembosproj/platform/{identity,orchestrator,portal,worker,setup}:<appVersion>
```

The chart pulls the tag its `appVersion` names unless `global.image.tag`, or a component's own `image.tag`,
says otherwise. A mirror is `global.image.registry` plus `global.imagePullSecrets`; the repository paths
stay as they are.

They run on Microsoft's chiseled Ubuntu .NET images: distroless, with no shell and no package manager, as the
non-root user `1654`, on a read-only root filesystem — which is what `global.podSecurityContext` and
`global.containerSecurityContext` assume.

The Worker downloads the Terraform and Helm versions each blueprint pins, so neither is baked in. Its
workspace — runs, toolchains, the provider cache and `HOME` — is `/var/lib/lembos`, on a volume each pod
claims when it starts and releases when it goes (a generic ephemeral volume). One per pod, because the
toolchain directory and the provider cache are single-writer; a shared volume would put several Workers
unzipping into one path. A new pod downloads its toolchains once.

**Every image is signed** when it is published, keylessly, with the identity of the workflow that built it
(`.github/workflows/release.yml` in `lembosproj/platform`, running on `main`), and the signature is
recorded in the Rekor transparency log. Verify one before trusting it, by digest rather than by tag — a tag
can be moved after signing and a signature over a digest cannot:

```shell
cosign verify \
  --certificate-identity-regexp '^https://github.com/lembosproj/platform/\.github/workflows/release\.yml@refs/heads/main$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/lembosproj/platform/orchestrator:0.0.2
```

An admission controller that checks signatures (Kyverno, Sigstore's policy controller) takes the same two
values; the regular expression is what stops an image signed by another repository's workflow from passing.

## Releases

The chart and the platform are versioned apart. `version` is the chart's own and comes from this
repository's tag; `appVersion` in `Chart.yaml` is the platform release it installs, and moves only when a
change here adopts a new one. A version tag publishes the chart:

```shell
git tag v0.2.0 && git push origin v0.2.0      # v0.2.0-rc.1 publishes a pre-release
```

The `Chart` workflow then checks that all five images exist at `appVersion` — a chart naming an image that
is not there installs nothing — packages the chart, pushes it to `oci://ghcr.io/<owner>/charts/lembos`, and
creates a GitHub Release with the chart attached and notes generated from the merged pull requests.

New GHCR packages start private; make the chart public once, in its package settings, for clusters that
pull without credentials.

## Configuration

Each service gets a ConfigMap holding an `appsettings.<Environment>.json`, mounted beside the one the image
ships. It layers over that file rather than replacing it, so the OIDC client registry and log levels stay
as built. Secrets never go in it: they arrive as environment variables from Secrets, which take precedence.

Settings only one service reads, and that this chart has no value for, go in `<component>.env`:

```yaml
identity:
  env:
    - name: Identity__RateLimit__Interactive__PermitLimit
      value: "40"
```

### Addresses

Every published component answers on `<component>.<global.domain>`, or on `<component>.host` when set.
Those names are not cosmetic: the OIDC issuer, the redirect URIs and the CORS origins are all derived from
them, so they have to be the names browsers use. When browsers reach the ingress on a port other than the
scheme's default, `global.publicPort` adds it to every one of those origins — and the ingress has to answer
on that port from inside the cluster too, because the services call Identity there.

The services call Identity at its **public** origin rather than at its Service, because that origin is the
token issuer they validate. Inside the cluster the name must therefore resolve and its certificate must be
trusted:

- **Resolution.** Usually the public DNS already does. If not, `global.hostAliases` or a CoreDNS override
  (as the getting-started app host does) points it at the ingress controller.
- **Trust.** A publicly trusted certificate needs nothing. A private CA goes in
  `global.trustedCertificates` (a Secret or ConfigMap, and `keys` to mount only the certificate); the
  services trust it through `SSL_CERT_DIR`.

**Each service answers only under the names it was given**: its public hostname, its Service's names inside
the cluster (`<release>-<component>`, alone and with the namespace, `.svc` and `global.clusterDomain`
suffixes) and `localhost` for `kubectl port-forward`. The chart writes that list as the service's
`AllowedHosts`, so a request arriving under any other name — an ingress rule pointing at the wrong Service, a
route a mesh added — is refused with a 400 rather than served under a hostname the deployment never
published. The probes send the Service name as `Host` for the same reason. A cluster whose DNS domain is not
`cluster.local` sets `global.clusterDomain`.

**The `platform` section is checked against `values.schema.json`**, whose `platform` property is the
platform's own contract: `lembosproj/platform` generates `contracts/platform-values.schema.json` from
`PlatformConfig`, its release publishes the file as a public OCI artifact beside the images
(`ghcr.io/lembosproj/platform/values-schema:<version>`), and `scripts/sync-platform-schema.sh` (which needs
`oras`) copies it here at the release `appVersion` names. A key the platform does not know fails `helm lint`
and `helm install` rather than reaching a service, where the strict binder would refuse it at startup — or,
for a key the chart distributes itself, be ignored and leave the platform on its default with nothing saying
so. The chart workflow compares the copy with the artifact, and the chart's release refuses a platform that
published none, so a setting the platform added reaches this chart's `values.yaml` and templates in the same
change that bumps `appVersion`.

## Secrets and keys

### The setup job

Every Secret the release needs is made by the setup job
([`Lembos.Setup`](https://github.com/lembosproj/platform/tree/main/src/Setup/Lembos.Setup)), a
`pre-install`/`pre-upgrade` hook — PreSync under Argo CD — that runs before anything reads one. Each value is resolved in this order:

1. an `existingSecret` you manage (Sealed Secrets, External Secrets, SOPS) — the job leaves it alone;
2. the value given in `values.yaml`, which the job writes;
3. the value already in the cluster, which the job keeps;
4. generated by the job.

The chart renders no secret material itself and never uses `lookup`, so rendering it again — which a GitOps
controller does on every sync — generates nothing. The Secrets the job creates are not part of the release:
`helm uninstall` and an Argo CD prune both leave them, because every token, session and stored credential is
encrypted under them. Nothing is rotated by an upgrade either. Rotating a value is deleting that key, or
the Secret, and upgrading.

The job's ServiceAccount may create Secrets in the release namespace and read or patch only the ones it
names. It labels what it creates `app.kubernetes.io/managed-by: lembos-setup`; back those up.

### The release's Secret

`<release>-secrets` holds the following, or `secrets.existingSecret` names a Secret you manage that does:

| Key                                    | What                                                                  |
|----------------------------------------|-----------------------------------------------------------------------|
| `client-secret-orchestrator`           | OAuth client secrets, registered by Identity and used by each client  |
| `client-secret-portal`                 |                                                                       |
| `client-secret-drift-reconciler`       |                                                                       |
| `client-secret-agent-runner`           |                                                                       |
| `client-secret-directory-synchronizer` |                                                                       |
| `client-secret-execution-agent`        |                                                                       |
| `identity-encryption-key`              | 32 random bytes, base64                                               |
| `identity-admin-password`              | The bootstrap administrator's password                                |
| `postgres-password`                    | Simple PostgreSQL or the HA cluster's owner role; external when given |
| `redis-password`                       | Simple Redis or redis-ha                                              |

GitHub's five credentials (`github-app-id`, `github-app-org`, `github-private-key-base64`, `github-client-id`,
`github-client-secret`) go in `secrets.gitHub.existingSecret`, or inline. They are required when
`platform.integrations.gitHub.enabled` and never generated, because GitHub issues them.

### Key pairs

Four `kubernetes.io/tls` Secrets: Identity's token-signing key, and the certificates that encrypt the Data
Protection key rings of Identity, the Orchestrator and the Portal. Each is `certificates.<name>.existingSecret`
(for instance issued by cert-manager), a PEM `certificate` + `privateKey` in values, or a self-signed pair the
setup job generates.

Self-signed is right for all four: nothing validates a chain for them. Losing one is not recoverable — the
signing key invalidates every token issued, a key-protection certificate makes its key ring unreadable — so
with cert-manager use a long `duration` and `privateKey.rotationPolicy: Never`. The services read these as
PEM, or as base64 PKCS#12; see `KeyProtectionCertificate` in the platform's `Lembos.ServiceDefaults`.

The platform's app host makes the same Secrets with the same tool, into user secrets instead of the cluster
(`LocalSetupSpec` in `Lembos.AppHost`). Nothing compares the two, so a secret added to
`templates/setup/_spec.tpl` is added there too, and the other way round.

## Publishing

`ingress.enabled` creates an Ingress per published component; `gateway.enabled` creates an HTTPRoute per
component attached to `gateway.parentRefs`. Either or both.

**WebSockets.** The Portal (Blazor Server) and the Orchestrator (GraphQL subscriptions) hold WebSockets open
for as long as a session or a stream lasts. Upgrades need nothing on mainstream controllers; idle timeouts
do. Both components' Ingresses default to ingress-nginx's `proxy-read-timeout`/`proxy-send-timeout` of an
hour (other controllers ignore them), and their HTTPRoutes take `gateway.timeouts`. For another controller,
set its equivalent in `<component>.ingress.annotations`.

**More than one Portal replica** needs sticky sessions — a circuit lives in the replica that started it.
`values-ha.yaml` shows the ingress-nginx annotations.

**Where the controller runs** has to be stated: `global.forwardedHeaders.knownNetworks` (the pod CIDR it runs
in) or `knownProxies` (its fixed addresses). The services rewrite each request's scheme, host and client
address from the `X-Forwarded-*` headers, and take them only from these sources — anything else on the cluster
network could otherwise present itself as any address, which is what Identity rate-limits by. The install
refuses to render outside Development with nothing named. `trustAnySource: true` keeps the old behaviour and is
right only where the network policies already admit nothing but the controller to the listeners.

**Identity's admin listener** is never published. It is a second port on the Identity pod with its own
ClusterIP Service, `<release>-identity-admin`, which no Ingress or HTTPRoute references and whose
NetworkPolicy admits only the Worker. Identity also answers `/admin/accounts` with 404 on any other port,
so the public route cannot reach the admin surface by path.

**The Temporal UI** is this chart's own Deployment in every mode, pointed at whichever frontend the mode
gives. It has no authentication of its own, so it is an internal ClusterIP Service by default:

```shell
kubectl -n lembos port-forward svc/lembos-temporal-ui 8080:8080
```

`temporal.ui.ingress.enabled` publishes it at `temporal.<domain>` through the same ingress as everything
else — right on a laptop, and anywhere else only when that ingress is internal. List who else may connect
in `networkPolicy.temporalWeb.from`.

## Scaling the Worker

A run is a `terraform` or `helm` process plus what it links, and its cost is a property of the pod it lands
on. Two settings decide how many runs a pod takes, and one decides how many pods there are.

**How many runs a pod takes** is `worker.maxConcurrentRuns` at most, and beneath that whatever
`worker.capacity` admits: a run is taken only while the container's CPU and memory are under the targets, as
fractions of the limits in `worker.resources`, and the workspace volume has `minimumFreeDiskMegabytes` left
after `reservedDiskPerRunMegabytes` for every run in flight. The first run is admitted on the disk check
alone. A run held back stays on its Temporal queue — it costs the pod nothing and counts as backlog.

| Value                                         | Default | Meaning                                                           |
|-----------------------------------------------|---------|-------------------------------------------------------------------|
| `worker.maxConcurrentRuns`                    | 4       | The ceiling, whatever the measurements say                        |
| `worker.capacity.targetCpuUsage`              | 0.8     | Admit while CPU is under this fraction of the pod's quota         |
| `worker.capacity.targetMemoryUsage`           | 0.8     | Admit while memory is under this fraction of the pod's limit      |
| `worker.capacity.minimumFreeDiskMegabytes`    | 1024    | Never go below this on the workspace volume                       |
| `worker.capacity.reservedDiskPerRunMegabytes` | 512     | What a run in flight may still write                              |
| `worker.cacheRetention`                       | 30 days | Evict cached providers and tool versions no run has used for this |

**How many pods there are** is `worker.autoscaling`, on in a high-available install. `scaler: hpa` is a
HorizontalPodAutoscaler on CPU and memory, which cannot see runs held back for memory or disk. `scaler: keda`
renders a KEDA `ScaledObject` instead, with a trigger per execution queue — the runs waiting on
`execution-terraform` and `execution-helm`, `keda.targetQueueSize` per pod — and the same CPU and memory
beside them, so the fleet grows from exactly what the pods hold back. It needs KEDA 2.17 or later, and the
chart refuses it on a cluster without the CRD. A Temporal reached over TLS or with an API key takes a
`TriggerAuthentication` in the release's namespace, named in `keda.triggerAuthentication`. Scale-down keeps
the ten-minute stabilisation either way: a pod removed mid-apply hands its run to another, which starts it
again.

## Network policies

With `networkPolicy.create` (the default), every pod gets a policy that denies everything it does not list:

| Pod          | Accepts from                                              | Reaches                                                     |
|--------------|-----------------------------------------------------------|-------------------------------------------------------------|
| Identity     | ingress controller (8080); Worker (admin port)            | DNS, PostgreSQL, Redis, Temporal, SMTP or MailPit, GitHub   |
| Orchestrator | ingress controller, Portal, Worker (8080)                 | DNS, PostgreSQL, Redis, Temporal, Identity's public origin  |
| Portal       | ingress controller (8080)                                 | DNS, Redis, Orchestrator, Identity's public origin          |
| Worker       | nothing                                                   | DNS, Temporal, Orchestrator, Identity admin, `workerEgress` |
| Setup job    | nothing                                                   | DNS, the API server                                         |
| PostgreSQL   | Identity, Orchestrator, Temporal                          | nothing                                                     |
| Redis        | Identity, Orchestrator, Portal                            | nothing                                                     |
| Temporal     | Identity, Orchestrator, Worker, Temporal UI, itself       | DNS, PostgreSQL, itself                                     |
| Temporal UI  | ingress controller when published, `temporalWeb.from`     | DNS, Temporal                                               |
| MailPit      | Identity (1025); ingress controller when published (8080) | nothing                                                     |

Set `networkPolicy.ingressController` to where your ingress controller or Gateway runs, and `networkPolicy.dns`
to your cluster DNS. The Worker reaches whatever its blueprints name — registries, git hosts, cloud APIs,
target clusters — so `networkPolicy.workerEgress` allows everything until you narrow it. With `global.otel.endpoint` set, every
service may also reach the endpoint's port — 4317 for gRPC, 4318 for HTTP unless the URL names one — wherever
it resolves, so a collector can run in the cluster or beyond it. The high-available
PostgreSQL and Redis pods are not given policies by this chart: the CloudNativePG operator must reach its
instances, and redis-ha has its own `networkPolicy` settings.

## Dependencies

Each of PostgreSQL, Redis and Temporal has a `mode` — `simple`, `high-available` or `external` — which
follows `installMode` when empty. Only the block the mode names is read:

| Dependency | `simple`                         | `high-available`                                  | `external`            |
|------------|----------------------------------|---------------------------------------------------|-----------------------|
| PostgreSQL | `postgresql.simple`: StatefulSet | `postgresql.highAvailable`: CloudNativePG Cluster | `postgresql.external` |
| Redis      | `redis.simple`: StatefulSet      | `redis-ha`: Sentinel, HAProxy in front            | `redis.external`      |
| Temporal   | `temporal.simple`: auto-setup    | `temporal-ha`: Temporal's official chart          | `temporal.external`   |

[`values-ha.yaml`](./values-ha.yaml) is a high-available install with all three. `redis-ha` and `temporal-ha`
are upstream charts, dependencies in `Chart.yaml` fetched with `helm dependency build`, which installs exactly
the versions and digests [`Chart.lock`](./Chart.lock) records. Moving one is changing its version in
`Chart.yaml` and running `helm dependency update`, which rewrites the lock; commit both. Helm decides whether
to render a dependency from a boolean in that dependency's own values, which a mode cannot set, so
`redis-ha.enabled` and `temporal-ha.enabled` have to agree with their modes; the chart fails naming the value
when they do not.

- **PostgreSQL.** One database per service (ADR002). The simple server creates them at first start. The
  high-available mode is a CloudNativePG `Cluster` this chart renders, with the other databases as `Database`
  resources owned by one role, whose basic-auth Secret the setup job keeps in step with `postgres-password`;
  it needs the CloudNativePG operator installed first — see [Prerequisites](#prerequisites). An external server needs a user with `CREATEDB`, or the databases created ahead of time.
- **Redis.** Holds the Portal's Data Protection key ring, beside the tokens it encrypts — losing it signs
  everybody out, so the simple one is persisted with append-only files. Under `redis-ha` — the chart Argo CD
  runs its own Redis with — HAProxy always routes to the current primary, so the services keep a plain
  `host:port` connection string.
- **Temporal.** Simple is the auto-setup image `aspire start` runs: every Temporal service in one process,
  which creates its databases, applies the schema and registers the `default` namespace on start, and reports
  ready only once that namespace answers. High-available is the official chart — frontend, history, matching
  and worker as separate Deployments, a schema job and the namespace job; the schema job runs as an ordinary
  Job rather than a hook, so it can wait for a PostgreSQL in the same release. The services speak plain gRPC
  to the `default` namespace; TLS, API keys and Temporal Cloud are not supported yet. The simple server's
  Prometheus metrics are `temporal.simple.metrics`: a `<release>-temporal-metrics` Service whose type a
  scraper outside the cluster can reach, and the NetworkPolicy peers allowed to scrape it.

**Release-prefixed names.** Upstream charts cannot read this chart's values, so the names they are given —
`temporal-ha.server.config.persistence.datastores.*.sql` and `redis-ha.existingSecret` — are written out for
a release called `lembos` and marked "release-prefixed" in `values.yaml`. Under another release name the
chart fails at render time naming each value to change and what to change it to.

## Grafana dashboards

[`dashboards/`](./dashboards) holds the platform's Grafana dashboards — **Lembos — Platform** for the whole
install, **Lembos — Service** for one service — and the chart can ship them:

```yaml
grafanaDashboards:
  enabled: true          # a ConfigMap per dashboard, labelled grafana_dashboard: "1"
  namespace: monitoring  # where Grafana's dashboard sidecar looks, when not the release's namespace
```

Grafana's dashboard sidecar — the one kube-prometheus-stack and the Grafana chart run — loads them from the
label. Without one, import the JSON files as they are: each asks for a metrics, a logs and a traces data
source on import, so no data source names are assumed.

They read what an OpenTelemetry pipeline produces when the services export to it (`global.otel.endpoint`):

| Signal  | Expected in | What the queries rely on                                                                                                                                                                       |
|---------|-------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Metrics | Prometheus  | OTLP ingestion with `service.name`, `service.namespace` and the `k8s.*` names promoted to labels; the k8s attributes processor and the kubelet and cluster receivers for the Kubernetes panels |
| Logs    | Loki 3      | OTLP ingestion, so `service_name` is a label and severity and `trace_id` are structured metadata                                                                                               |
| Traces  | Tempo       | Its metrics generator writing the service graph and span metrics to the same Prometheus                                                                                                        |

The getting-started app host runs exactly that pipeline; its `observability/` and `otel-agent.yaml` are a
working configuration to copy.

## Running locally with Aspire

[`aspire/Lembos.Deploy.AppHost`](../../aspire/Lembos.Deploy.AppHost) runs the whole platform on one machine:
a k3s cluster in a Docker container, this chart installed into it from this directory with Temporal in the
release, PostgreSQL, Redis and MailPit beside the cluster as Aspire resources — so the chart's `external` modes
are exercised too — and an OpenTelemetry pipeline into Grafana. Its values are
[`values.aspire.yaml`](../../aspire/Lembos.Deploy.AppHost/values.aspire.yaml): published images at this
repository's `appVersion`, Traefik in front
serving the AppHost's trusted developer certificate, k3s's NetworkPolicy controller enforcing the policies,
and the Worker autoscaled from one replica to three.

The app host uses the CommunityToolkit k3s integration as `Lab.Aspire.Hosting.K3s`, a build of the pull
request that adds what it relies on — host aliases, the ingress developer certificate, chart directories —
until a CommunityToolkit release carries it.

### What you need

Docker with about 4 CPUs and 8 GiB of memory to spare, the .NET 10 SDK, the [Aspire CLI](https://aspire.dev)
with a trusted developer certificate (`aspire certs trust`), and ports 80, 443 and 3000 free. Traefik is
published on 80 and 443 because `identity.dev.localhost` with no port is the issuer every service validates;
Grafana is on 3000. `kubectl` is optional, for looking inside.

### Start

```shell
aspire start          # from the repository root; the dashboard link is printed
```

| Resource          | What it does                                                                                          |
|-------------------|-------------------------------------------------------------------------------------------------------|
| `k3s`             | The cluster. Persistent, with its data and node identity in volumes, so it survives `aspire stop`     |
| `k3s-dns`         | Makes `postgres`, `redis`, `mailpit` and `otel-collector` resolvable from pods, adds the              |
|                   | `*.dev.localhost` rewrite, restarts CoreDNS, then exits                                               |
| `k3s-certificate` | Makes the developer certificate Traefik's default, and stores it in each release's namespace          |
| `postgres`        | The services' and Temporal's PostgreSQL, with the `identity` and `orchestrator` databases             |
| `redis`           | The Portal's and Identity's Redis                                                                     |
| `mailpit`         | Where invitations, confirmations and password resets land                                             |
| `otel-collector`  | Receives the services' telemetry, reads the cluster's metrics, scrapes Temporal's                     |
| `lembos`          | `helm upgrade --install` of this chart, then exits — every start applies the current chart and values |

The first start takes several minutes, most of it pulling images. `lembos` finishes once every pod is
ready.

**Why `k3s-dns` exists.** Pods resolve names through k3s's CoreDNS, which cannot ask Docker's DNS, so they
cannot find the Aspire containers by name. The k3s integration looks each one up on the network it shares
with the cluster and writes the addresses into the `coredns-custom` ConfigMap — so `values.aspire.yaml` sets
`extraObjects: []`, leaving that ConfigMap to the integration.

### Sign in

| What        | Where                                        |
|-------------|----------------------------------------------|
| Portal      | `https://portal.dev.localhost`               |
| Identity    | `https://identity.dev.localhost`             |
| GraphQL     | `https://orchestrator.dev.localhost/graphql` |
| Temporal UI | `https://temporal.dev.localhost`             |
| Grafana     | `http://localhost:3000`                      |
| MailPit     | the `mailpit` resource in the dashboard      |

Sign in as `admin@lembos.local`, with the password the setup job generated:

```shell
export KUBECONFIG=aspire/Lembos.Deploy.AppHost/.k3s/k3s/local/kubeconfig.yaml
kubectl -n lembos get secret lembos-secrets -o jsonpath='{.data.identity-admin-password}' | base64 -d; echo
```

### Observing it

The services export traces, metrics and logs over OTLP (`global.otel.endpoint`) straight to `otel-collector`
beside the cluster, each signal already naming its pod, Deployment and node (the chart sets them as resource
attributes). The collector reads the cluster's state and the kubelet's resource usage through the API server
with the cluster's kubeconfig, scrapes Temporal's server metrics through the `lembos-temporal-metrics` Service
(`temporal.simple.metrics`, published on the node by the service load balancer), and routes each signal to its
store: traces to Tempo, logs to Loki, metrics to Prometheus. Grafana reads all three,
linked to each other — an exemplar or a log line opens its trace, and a trace opens its logs.

| Dashboard             | What it answers                                                                                                                                                                                                                  |
|-----------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Lembos — Platform** | Is the platform healthy? Request rate, errors and latency per service, workflow triggers and Temporal, pod CPU and memory, restarts, the Worker autoscaler, .NET runtime, logs by level, the service map, failed and slow traces |
| **Lembos — Service**  | Where is one service spending its time? Rate, status and latency per route, its pods, its runtime, its logs and traces                                                                                                           |
| **Lembos — Temporal** | Is Temporal keeping up? Request rate and errors, persistence latency, task queue backlog and schedule-to-start latency, workflow outcomes                                                                                        |

The dashboards are the chart's own ([Grafana dashboards](#grafana-dashboards)), mounted from `dashboards/`;
edit one in Grafana and export the JSON back there to keep the change. Metrics arrive every 60 seconds, so rates are taken
over several minutes and a fresh start takes a couple of minutes to fill in.

### The Worker's autoscaler

`values.aspire.yaml` turns on the HorizontalPodAutoscaler, between one and three Workers on CPU. Watch it on
the platform dashboard, or:

```shell
kubectl -n lembos get hpa,pods -l app.kubernetes.io/component=worker -w
```

### Another platform release, or a changed value

`aspire stop`, then change `appVersion` in `Chart.yaml`, a template, or a value in either file, and
`aspire start` again: the `lembos` resource upgrades the release from this directory, and the setup job keeps
every secret it made.

### Tear down

```shell
aspire stop                                    # the cluster, the dependencies and the stores keep running
docker rm -f $(docker ps -aq --filter name=k3s- --filter name=postgres- --filter name=redis- --filter name=mailpit- \
  --filter name=otel-collector- --filter name=prometheus- --filter name=loki- --filter name=tempo- --filter name=grafana-)
docker volume ls | grep -E 'lembos.deploy|lembos-deploy'   # the volumes left behind; remove them for a fresh start
```

### When something is wrong

| Symptom                                    | Look at                                                                       |
|--------------------------------------------|-------------------------------------------------------------------------------|
| `lembos` fails after ten minutes           | `kubectl -n lembos get pods`, then the logs of whichever is not ready         |
| A service cannot reach PostgreSQL or Redis | The `k3s-dns` logs: each `<name> -> <address>` it wrote                       |
| The install fails before anything starts   | `kubectl -n lembos logs job/lembos-setup` — the setup job's own report        |
| Nothing answers on `*.dev.localhost`       | Something else holds 80 or 443, so the `k3s` container could not publish them |
| The browser warns about the certificate    | The developer certificate is not trusted yet: `aspire certs trust`            |
| A dashboard panel says "No data"           | Nothing has happened yet — no 5xx, no failed trace — or the first minutes     |
