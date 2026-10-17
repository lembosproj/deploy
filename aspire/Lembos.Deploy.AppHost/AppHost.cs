// Lembos on a local k3s: this repository's chart, the platform's published images at its appVersion, with
// PostgreSQL, Redis and MailPit beside the cluster as Aspire resources — the chart's `external` dependency modes —
// and Temporal in the cluster, as the chart's simple mode runs it. An OpenTelemetry pipeline into Grafana observes
// it the way a production install would be. The chart's values are values.aspire.yaml.

var builder = DistributedApplication.CreateBuilder(args);

var chartDirectory = Path.GetFullPath(Path.Combine(builder.AppHostDirectory, "..", "..", "charts", "lembos"));

// The ASP.NET Core developer certificate — which `aspire certs trust` has the machine trust — carries
// *.dev.localhost, so every published host is under it and the browser trusts what answers.
const string domain = "dev.localhost";

// ── Dependencies, outside the cluster ──
//
// Persistent, like the cluster: the data outlives the app host. Passwords are persisted in user secrets, because
// the data volumes keep the ones the servers were initialised with.

var postgresPassword = builder.AddParameter("postgres-password",
    new GenerateParameterDefault { MinLength = 24, Special = false }, secret: true, persist: true);

var postgres = builder.AddPostgres("postgres", password: postgresPassword)
    .WithDataVolume()
    .WithLifetime(ContainerLifetime.Persistent);

// The chart's postgresql.databases. Its own PostgreSQL creates them at first start; an external server is
// expected to have them, so Aspire creates them here. Temporal creates its own two.
postgres.AddDatabase("identity");
postgres.AddDatabase("orchestrator");

var redisPassword = builder.AddParameter("redis-password",
    new GenerateParameterDefault { MinLength = 24, Special = false }, secret: true, persist: true);

// Plain TCP: the developer certificate does not name `redis`, which is what the pods connect to.
var redis = builder.AddRedis("redis", password: redisPassword)
    .WithoutHttpsCertificate()
    .WithDataVolume()
    .WithLifetime(ContainerLifetime.Persistent);

var mailpit = builder.AddMailPit("mailpit")
    .WithImageTag("v1.22.3")
    .WithLifetime(ContainerLifetime.Persistent);

// ── The cluster ──

var cluster = builder.AddK3sCluster("k3s", apiServerPort: 16443)
    .WithDataVolume()
    .WithLifetime(ContainerLifetime.Persistent)
    // The service load balancer is what binds Traefik — and Temporal's metrics Service — to the node's ports,
    // and the metrics server is what the Worker's autoscaler reads; the integration starts without both.
    .WithEnabledComponent("servicelb")
    .WithEnabledComponent("metrics-server")
    // Traefik answers on 80 and 443 inside the node, published as they are rather than proxied onto other
    // ports: the issuer every service validates is identity.dev.localhost, so the browser has to use exactly
    // that origin.
    .WithEndpoint(port: 80, targetPort: 80, name: "ingress-http", scheme: "tcp", isProxied: false)
    .WithEndpoint(port: 443, targetPort: 443, name: "ingress-https", scheme: "tcp", isProxied: false)
    // Inside the cluster *.dev.localhost would resolve to each pod's own loopback, but the services reach
    // Identity at its public origin — the token issuer — so the names go to Traefik instead.
    .WithCoreDnsCustomization("lembos.override",
        @"rewrite name regex (.*\.)?dev\.localhost\.? traefik.kube-system.svc.cluster.local. answer auto")
    // Traefik serves the developer certificate, and the release's namespace gets it as the TLS Secret
    // aspire-developer-certificate, which values.aspire.yaml has the services trust.
    .WithIngressDeveloperCertificate()
    .WithUrl($"https://portal.{domain}", "Portal")
    .WithUrl($"https://identity.{domain}", "Identity")
    .WithUrl($"https://orchestrator.{domain}/graphql", "GraphQL")
    .WithUrl($"https://temporal.{domain}", "Temporal UI");

// ── Observability, outside the cluster ──
//
// What a production install ships telemetry to: a collector, Tempo for traces, Loki for logs, Prometheus for
// metrics, and Grafana over all three. The services export OTLP straight to the collector, carrying their own
// Kubernetes attributes; the collector reads the cluster's and the kubelet's metrics through the API server
// and scrapes Temporal's.

var observability = Path.Combine(builder.AppHostDirectory, "observability");

var prometheus = builder.AddContainer("prometheus", "prom/prometheus", "v3.15.0")
    .WithBindMount(Path.Combine(observability, "prometheus.yaml"), "/etc/prometheus/prometheus.yaml", isReadOnly: true)
    .WithArgs(
        "--config.file=/etc/prometheus/prometheus.yaml",
        "--storage.tsdb.path=/prometheus",
        // OTLP from the collector, and remote write from Tempo's metrics generator.
        "--web.enable-otlp-receiver",
        "--web.enable-remote-write-receiver",
        "--enable-feature=exemplar-storage")
    .WithVolume("lembos-deploy-prometheus", "/prometheus")
    .WithHttpEndpoint(targetPort: 9090, name: "http")
    .WithLifetime(ContainerLifetime.Persistent);

var loki = builder.AddContainer("loki", "grafana/loki", "3.6.18")
    .WithBindMount(Path.Combine(observability, "loki.yaml"), "/etc/loki/loki.yaml", isReadOnly: true)
    .WithArgs("-config.file=/etc/loki/loki.yaml")
    .WithVolume("lembos-deploy-loki", "/loki")
    .WithHttpEndpoint(targetPort: 3100, name: "http")
    .WithLifetime(ContainerLifetime.Persistent);

var tempo = builder.AddContainer("tempo", "grafana/tempo", "2.9.5")
    .WithBindMount(Path.Combine(observability, "tempo.yaml"), "/etc/tempo/tempo.yaml", isReadOnly: true)
    .WithArgs("-config.file=/etc/tempo/tempo.yaml")
    .WithVolume("lembos-deploy-tempo", "/var/tempo")
    // The image runs as an unprivileged user that cannot write to a freshly created volume.
    .WithContainerRuntimeArgs("--user", "0")
    .WithHttpEndpoint(targetPort: 3200, name: "http")
    .WithLifetime(ContainerLifetime.Persistent)
    .WaitFor(prometheus);

var otelCollector = builder.AddContainer("otel-collector", "otel/opentelemetry-collector-contrib", "0.163.1")
    .WithBindMount(Path.Combine(observability, "otel-collector.yaml"), "/etc/otelcol-contrib/config.yaml", isReadOnly: true)
    .WithEndpoint(targetPort: 4317, name: "grpc", scheme: "tcp")
    .WithEndpoint(targetPort: 4318, name: "http", scheme: "http")
    // The cluster's kubeconfig, for the k8s_cluster and kubeletstats receivers and the k8sattributes processor.
    .WithReference(cluster)
    .WithEnvironment("K8S_NODE_NAME", cluster.Resource.Name)
    .WithLifetime(ContainerLifetime.Persistent)
    .WaitFor(cluster)
    .WaitFor(prometheus)
    .WaitFor(loki)
    .WaitFor(tempo);

builder.AddContainer("grafana", "grafana/grafana", "13.2.4")
    .WithBindMount(Path.Combine(observability, "grafana", "provisioning"), "/etc/grafana/provisioning", isReadOnly: true)
    // The chart's own dashboards, the ones it ships for any Grafana.
    .WithBindMount(Path.Combine(chartDirectory, "dashboards"), "/var/lib/grafana/dashboards", isReadOnly: true)
    // A local tool on a loopback port: no sign-in, so the dashboards are one click from the Aspire dashboard.
    .WithEnvironment("GF_AUTH_ANONYMOUS_ENABLED", "true")
    .WithEnvironment("GF_AUTH_ANONYMOUS_ORG_ROLE", "Admin")
    .WithEnvironment("GF_AUTH_DISABLE_LOGIN_FORM", "true")
    .WithEnvironment("GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH", "/var/lib/grafana/dashboards/lembos-platform.json")
    .WithHttpEndpoint(port: 3000, targetPort: 3000, name: "http")
    .WithLifetime(ContainerLifetime.Persistent)
    .WaitFor(prometheus)
    .WaitFor(loki)
    .WaitFor(tempo);

// Pods resolve these by their resource names, and reach them on their container ports.
cluster
    .WithHostAlias(postgres)
    .WithHostAlias(redis)
    .WithHostAlias(mailpit)
    .WithHostAlias(otelCollector);

// ── The release ──

cluster.AddHelmRelease("lembos", chartDirectory, @namespace: "lembos")
    .WithHelmValuesFile("values.aspire.yaml")
    .WithHelmValue("postgresql.external.password", postgresPassword)
    .WithHelmValue("redis.external.password", redisPassword);

builder.Build().Run();
