{{/* ── Names and labels ── */}}

{{- define "lembos.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "lembos.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* A component's resource name: <fullname>-<component>. */}}
{{- define "lembos.componentName" -}}
{{- printf "%s-%s" (include "lembos.fullname" .root) .component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "lembos.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "lembos.selectorLabels" -}}
app.kubernetes.io/name: {{ include "lembos.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "lembos.labels" -}}
helm.sh/chart: {{ include "lembos.chart" .root }}
{{ include "lembos.selectorLabels" . }}
app.kubernetes.io/part-of: lembos
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- with .root.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Labels for resources that belong to no one component — the shared Secret, the certificates. */}}
{{- define "lembos.sharedLabels" -}}
{{ include "lembos.labels" (dict "root" . "component" "platform") }}
{{- end -}}

{{/* ── Images ── */}}

{{/* One of the four service images: <global.image.registry>/<repository>:<tag>. */}}
{{- define "lembos.serviceImage" -}}
{{- $global := .root.Values.global.image -}}
{{- $tag := .image.tag | default $global.tag | default .root.Chart.AppVersion -}}
{{- if $global.registry -}}
{{- printf "%s/%s:%s" $global.registry .image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .image.repository $tag -}}
{{- end -}}
{{- end -}}

{{/* A dependency image, which names its own registry. */}}
{{- define "lembos.image" -}}
{{- printf "%s:%s" .repository (toString .tag) -}}
{{- end -}}

{{- define "lembos.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/* ── Public addresses ── */}}

{{/* The hostname a published component answers on: its `host`, or <component>.<global.domain>. */}}
{{- define "lembos.host" -}}
{{- $values := index .root.Values .component -}}
{{- $values.host | default (printf "%s.%s" .component .root.Values.global.domain) -}}
{{- end -}}

{{/* The origin browsers and the other services address a component by. */}}
{{- define "lembos.origin" -}}
{{- printf "%s://%s%s" .root.Values.global.publicScheme (include "lembos.host" .) (include "lembos.publicPortSuffix" .root) -}}
{{- end -}}

{{/* ":<global.publicPort>", or nothing when browsers use the scheme's default port. */}}
{{- define "lembos.publicPortSuffix" -}}
{{- with .Values.global.publicPort }}:{{ . }}{{ end -}}
{{- end -}}

{{/* The names one Service answers to from inside the cluster, in the form AllowedHosts takes. {root, name} */}}
{{- define "lembos.serviceHosts" -}}
{{- $ns := .root.Release.Namespace -}}
{{- printf "%s;%s.%s;%s.%s.svc;%s.%s.svc.%s" .name .name $ns .name $ns .name $ns .root.Values.global.clusterDomain -}}
{{- end -}}

{{/*
The Host values a component serves, for ASP.NET Core's host filtering: its public hostname, the names its
Service has inside the cluster, and loopback for kubectl port-forward. Nothing else reaches a pod on purpose,
so a request under any other name — a mistaken ingress rule, a stray mesh route — is refused with a 400
rather than served under a hostname the deployment never published and the services would then build
links from. Identity's admin Service is added by its own configmap.
*/}}
{{- define "lembos.allowedHosts" -}}
{{- $service := include "lembos.serviceHosts" (dict "root" .root "name" (include "lembos.componentName" .)) -}}
{{- printf "%s;%s;localhost" (include "lembos.host" .) $service -}}
{{- end -}}

{{/* ── Secrets ── */}}

{{/* The release's own Secret, which the setup job fills — or the one the operator manages instead. */}}
{{- define "lembos.secretName" -}}
{{- .Values.secrets.existingSecret | default (printf "%s-secrets" (include "lembos.fullname" .)) -}}
{{- end -}}

{{/* The kubernetes.io/tls Secret one of `certificates` resolves to. */}}
{{- define "lembos.certificateSecretName" -}}
{{- $certificate := index .root.Values.certificates .name -}}
{{- $certificate.existingSecret | default (printf "%s-%s" (include "lembos.fullname" .root) (.name | kebabcase)) -}}
{{- end -}}

{{/* ── Install mode ── */}}

{{/* The whole release's shape: simple or high-available. */}}
{{- define "lembos.installMode" -}}
{{- $mode := .Values.installMode -}}
{{- if not (has $mode (list "simple" "high-available")) -}}
{{- fail (printf "installMode is %q. It must be simple or high-available." (toString $mode)) -}}
{{- end -}}
{{- $mode -}}
{{- end -}}

{{- define "lembos.highAvailable" -}}
{{- if eq (include "lembos.installMode" .) "high-available" -}}true{{- end -}}
{{- end -}}

{{/*
A component's replica count: its own `replicas`, else one per component in a simple install and two in a
high-available one — the fewest that survive losing a node.
*/}}
{{- define "lembos.replicas" -}}
{{- $values := index .root.Values .component -}}
{{- if kindIs "invalid" $values.replicas -}}
{{- ternary 2 1 (eq (include "lembos.highAvailable" .root) "true") -}}
{{- else -}}
{{- $values.replicas -}}
{{- end -}}
{{- end -}}

{{/*
Whether a component autoscales: its own `autoscaling.enabled`, else only in a high-available install and only
for the two whose load moves — the Orchestrator with the Portal's traffic, the Worker with runs. Identity's
load is sign-ins, and the Portal needs sticky sessions before it can be spread wider than its fixed replicas.
*/}}
{{- define "lembos.autoscaling" -}}
{{- $enabled := (index .root.Values .component).autoscaling.enabled -}}
{{- if kindIs "invalid" $enabled -}}
{{- if and (include "lembos.highAvailable" .root) (has .component (list "orchestrator" "worker")) -}}true{{- end -}}
{{- else if $enabled -}}true
{{- end -}}
{{- end -}}

{{/* Whether a component has a PodDisruptionBudget: its own setting, else whenever the install is high-available. */}}
{{- define "lembos.podDisruptionBudget" -}}
{{- $enabled := (index .root.Values .component).podDisruptionBudget.enabled -}}
{{- if kindIs "invalid" $enabled -}}
{{- include "lembos.highAvailable" .root -}}
{{- else if $enabled -}}true
{{- end -}}
{{- end -}}

{{/* ── Dependencies ── */}}

{{/*
A dependency's mode — simple, high-available or external — refusing anything else by name. Empty follows
installMode.
*/}}
{{- define "lembos.mode" -}}
{{- $mode := (index .root.Values .dependency).mode | default (include "lembos.installMode" .root) -}}
{{- if not (has $mode (list "simple" "high-available" "external")) -}}
{{- fail (printf "%s.mode is %q. It must be simple, high-available or external, or empty to follow installMode." .dependency (toString $mode)) -}}
{{- end -}}
{{- $mode -}}
{{- end -}}

{{- define "lembos.postgresql.mode" -}}
{{- include "lembos.mode" (dict "root" . "dependency" "postgresql") -}}
{{- end -}}

{{- define "lembos.redis.mode" -}}
{{- include "lembos.mode" (dict "root" . "dependency" "redis") -}}
{{- end -}}

{{- define "lembos.temporal.mode" -}}
{{- include "lembos.mode" (dict "root" . "dependency" "temporal") -}}
{{- end -}}

{{/*
An upstream chart's resource prefix, by the rule those charts share: fullnameOverride, else the release name
when it already contains the chart's name, else <release>-<name>. Computed here because their Services are
what the services connect to. An aliased dependency is named by its alias.
*/}}
{{- define "lembos.subchartFullname" -}}
{{- if .values.fullnameOverride -}}
{{- .values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .name .values.nameOverride -}}
{{- if contains $name .root.Release.Name -}}
{{- .root.Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .root.Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "lembos.redisHa.fullname" -}}
{{- include "lembos.subchartFullname" (dict "root" . "name" "redis-ha" "values" (index .Values "redis-ha")) -}}
{{- end -}}

{{- define "lembos.temporalHa.fullname" -}}
{{- include "lembos.subchartFullname" (dict "root" . "name" "temporal-ha" "values" (index .Values "temporal-ha")) -}}
{{- end -}}

{{/* The CloudNativePG Cluster, which is also the prefix of its -rw Service. */}}
{{- define "lembos.postgresql.clusterName" -}}
{{- include "lembos.componentName" (dict "root" . "component" "postgresql") -}}
{{- end -}}

{{/* The basic-auth Secret CloudNativePG's owner role authenticates with; the setup job keeps it. */}}
{{- define "lembos.postgresql.appSecret" -}}
{{- printf "%s-app" (include "lembos.postgresql.clusterName" .) -}}
{{- end -}}

{{- define "lembos.postgresql.host" -}}
{{- $mode := include "lembos.postgresql.mode" . -}}
{{- if eq $mode "simple" -}}
{{- include "lembos.componentName" (dict "root" . "component" "postgresql") -}}
{{- else if eq $mode "high-available" -}}
{{- printf "%s-rw" (include "lembos.postgresql.clusterName" .) -}}
{{- else -}}
{{- required "postgresql.external.host is required when postgresql.mode is external" .Values.postgresql.external.host -}}
{{- end -}}
{{- end -}}

{{- define "lembos.postgresql.port" -}}
{{- if eq (include "lembos.postgresql.mode" .) "external" -}}{{- .Values.postgresql.external.port -}}{{- else -}}5432{{- end -}}
{{- end -}}

{{- define "lembos.postgresql.username" -}}
{{- $mode := include "lembos.postgresql.mode" . -}}
{{- if eq $mode "simple" -}}
{{- .Values.postgresql.simple.username -}}
{{- else if eq $mode "high-available" -}}
{{- .Values.postgresql.highAvailable.owner -}}
{{- else -}}
{{- required "postgresql.external.username is required when postgresql.mode is external" .Values.postgresql.external.username -}}
{{- end -}}
{{- end -}}

{{/* Where the PostgreSQL password is, as a secretKeyRef body. */}}
{{- define "lembos.postgresql.passwordRef" -}}
{{- $mode := include "lembos.postgresql.mode" . -}}
{{- if eq $mode "high-available" -}}
name: {{ include "lembos.postgresql.appSecret" . }}
key: password
{{- else -}}
{{- $source := ternary .Values.postgresql.simple .Values.postgresql.external (eq $mode "simple") -}}
{{- if $source.existingSecret -}}
name: {{ $source.existingSecret }}
key: {{ $source.existingSecretPasswordKey }}
{{- else -}}
name: {{ include "lembos.secretName" . }}
key: postgres-password
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
An Npgsql connection string. The password is spliced in by Kubernetes from LEMBOS_POSTGRES_PASSWORD, which
every container that takes one declares first — dependent environment variables resolve in order.
*/}}
{{- define "lembos.postgresql.connectionString" -}}
{{- $parts := list
  (printf "Host=%s" (include "lembos.postgresql.host" .root))
  (printf "Port=%s" (include "lembos.postgresql.port" .root))
  (printf "Database=%s" .database)
  (printf "Username=%s" (include "lembos.postgresql.username" .root))
  "Password=$(LEMBOS_POSTGRES_PASSWORD)" -}}
{{- if eq (include "lembos.postgresql.mode" .root) "external" -}}
{{- $parts = append $parts (printf "SSL Mode=%s" .root.Values.postgresql.external.sslMode) -}}
{{- with .root.Values.postgresql.external.extraConnectionParameters -}}
{{- $parts = append $parts (trimSuffix ";" .) -}}
{{- end -}}
{{- end -}}
{{- join ";" $parts -}}
{{- end -}}

{{/*
Temporal's two databases, as JSON, where this release has to make them exist: under a high-available
PostgreSQL, whose owner role cannot create databases, they are Database resources. Read from whichever
Temporal names them, so the two cannot disagree.
*/}}
{{- define "lembos.temporal.databases" -}}
{{- $mode := include "lembos.temporal.mode" . -}}
{{- if eq $mode "simple" -}}
{{- toJson (list "temporal" "temporal_visibility") -}}
{{- else if eq $mode "high-available" -}}
{{- $stores := (index .Values "temporal-ha").server.config.persistence.datastores -}}
{{- toJson (list $stores.default.sql.databaseName $stores.visibility.sql.databaseName) -}}
{{- else -}}
{{- toJson list -}}
{{- end -}}
{{- end -}}

{{/* redis-ha's HAProxy always routes to the current primary, so the services need no Sentinel awareness. */}}
{{- define "lembos.redis.host" -}}
{{- $mode := include "lembos.redis.mode" . -}}
{{- if eq $mode "simple" -}}
{{- include "lembos.componentName" (dict "root" . "component" "redis") -}}
{{- else if eq $mode "high-available" -}}
{{- printf "%s-haproxy" (include "lembos.redisHa.fullname" .) -}}
{{- else -}}
{{- required "redis.external.host is required when redis.mode is external" .Values.redis.external.host -}}
{{- end -}}
{{- end -}}

{{- define "lembos.redis.port" -}}
{{- if eq (include "lembos.redis.mode" .) "external" -}}{{- .Values.redis.external.port -}}{{- else -}}6379{{- end -}}
{{- end -}}

{{/* Whether Redis takes a password. */}}
{{- define "lembos.redis.hasPassword" -}}
{{- $mode := include "lembos.redis.mode" . -}}
{{- if eq $mode "simple" -}}true
{{- else if eq $mode "high-available" -}}{{- if (index .Values "redis-ha").auth -}}true{{- end -}}
{{- else if or .Values.redis.external.password .Values.redis.external.existingSecret -}}true
{{- end -}}
{{- end -}}

{{- define "lembos.redis.passwordRef" -}}
{{- $mode := include "lembos.redis.mode" . -}}
{{- if eq $mode "high-available" -}}
name: {{ (index .Values "redis-ha").existingSecret }}
key: {{ (index .Values "redis-ha").authKey }}
{{- else -}}
{{- $source := ternary .Values.redis.simple .Values.redis.external (eq $mode "simple") -}}
{{- if $source.existingSecret -}}
name: {{ $source.existingSecret }}
key: {{ $source.existingSecretPasswordKey }}
{{- else -}}
name: {{ include "lembos.secretName" . }}
key: redis-password
{{- end -}}
{{- end -}}
{{- end -}}

{{/* A StackExchange.Redis configuration string, with the password spliced in from LEMBOS_REDIS_PASSWORD. */}}
{{- define "lembos.redis.connectionString" -}}
{{- $parts := list (printf "%s:%s" (include "lembos.redis.host" .) (include "lembos.redis.port" .)) -}}
{{- if include "lembos.redis.hasPassword" . -}}
{{- $parts = append $parts "password=$(LEMBOS_REDIS_PASSWORD)" -}}
{{- end -}}
{{- if and (eq (include "lembos.redis.mode" .) "external") .Values.redis.external.tls -}}
{{- $parts = append $parts "ssl=true" -}}
{{- end -}}
{{- join "," $parts -}}
{{- end -}}

{{- define "lembos.temporal.port" -}}
{{- if eq (include "lembos.temporal.mode" .) "external" -}}{{- .Values.temporal.external.port -}}{{- else -}}7233{{- end -}}
{{- end -}}

{{/* host:port, which is what a Temporal client dials — not a URL. */}}
{{- define "lembos.temporal.address" -}}
{{- $mode := include "lembos.temporal.mode" . -}}
{{- if eq $mode "simple" -}}
{{- printf "%s:7233" (include "lembos.componentName" (dict "root" . "component" "temporal")) -}}
{{- else if eq $mode "high-available" -}}
{{- printf "%s-frontend:7233" (include "lembos.temporalHa.fullname" .) -}}
{{- else -}}
{{- printf "%s:%v" (required "temporal.external.host is required when temporal.mode is external" .Values.temporal.external.host) .Values.temporal.external.port -}}
{{- end -}}
{{- end -}}

{{/* Where Identity sends mail, as an SMTP endpoint: the one given, else the release's MailPit. */}}
{{- define "lembos.smtp.endpoint" -}}
{{- if .Values.identity.smtp.endpoint -}}
{{- .Values.identity.smtp.endpoint -}}
{{- else if .Values.mailpit.enabled -}}
{{- printf "smtp://%s:1025" (include "lembos.componentName" (dict "root" . "component" "mailpit")) -}}
{{- end -}}
{{- end -}}

{{/* ── Environment shared by the four services ── */}}

{{/* A secretKeyRef environment variable. */}}
{{- define "lembos.secretEnv" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ .secret }}
      key: {{ .key }}
{{- end -}}

{{- define "lembos.postgresEnv" -}}
- name: LEMBOS_POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      {{- include "lembos.postgresql.passwordRef" . | nindent 6 }}
{{- end -}}

{{- define "lembos.redisEnv" -}}
{{- if include "lembos.redis.hasPassword" . }}
- name: LEMBOS_REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      {{- include "lembos.redis.passwordRef" . | nindent 6 }}
{{- end }}
- name: ConnectionStrings__cache
  value: {{ include "lembos.redis.connectionString" . | quote }}
{{- end -}}

{{/* A Data Protection key-protection certificate, as the PEM pair every service accepts. */}}
{{- define "lembos.keyProtectionEnv" -}}
{{- $secret := include "lembos.certificateSecretName" (dict "root" .root "name" .name) -}}
{{ include "lembos.secretEnv" (dict "name" "DataProtection__KeyProtectionCertificatePem" "secret" $secret "key" "tls.crt") }}
{{ include "lembos.secretEnv" (dict "name" "DataProtection__KeyProtectionPrivateKeyPem" "secret" $secret "key" "tls.key") }}
{{- end -}}

{{/*
Settings every .NET service reads from its environment rather than its appsettings: the host's own
variables, which are read before any settings file is.
*/}}
{{- define "lembos.hostEnv" -}}
- name: ASPNETCORE_ENVIRONMENT
  value: {{ .root.Values.global.environment | quote }}
- name: OTEL_SERVICE_NAME
  value: {{ .component | quote }}
# The pod's own Kubernetes identity on every signal, as an in-cluster collector's k8sattributes processor would
# add it — so telemetry can go straight to a collector anywhere and still say which pod sent it.
- name: K8S_POD_NAME
  valueFrom:
    fieldRef: {fieldPath: metadata.name}
- name: K8S_NODE_NAME
  valueFrom:
    fieldRef: {fieldPath: spec.nodeName}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: {{ printf "service.namespace=lembos,deployment.environment=%s,service.instance.id=$(K8S_POD_NAME),k8s.namespace.name=%s,k8s.deployment.name=%s,k8s.pod.name=$(K8S_POD_NAME),k8s.container.name=%s,k8s.node.name=$(K8S_NODE_NAME)" .root.Values.global.environment .root.Release.Namespace (include "lembos.componentName" .) .component | quote }}
{{- with .root.Values.global.otel }}
{{- if .endpoint }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ .endpoint | quote }}
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: {{ .protocol | quote }}
{{- with .headers }}
- name: OTEL_EXPORTER_OTLP_HEADERS
  value: {{ . | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
The settings file name. Environment-specific, so it layers over the appsettings.json the image ships —
which carries the OIDC client registry and log levels — rather than replacing it.
*/}}
{{- define "lembos.settingsFile" -}}
{{- printf "appsettings.%s.json" .Values.global.environment -}}
{{- end -}}

{{/* Settings every service takes, as JSON for the caller to merge. */}}
{{- define "lembos.commonSettings" -}}
{{- toJson (dict
  "HealthChecks" (dict "Enabled" true)
  "UserManagement" (dict "Mode" .Values.platform.userManagement.mode)
  "ForwardedHeaders" (dict
    "KnownNetworks" .Values.global.forwardedHeaders.knownNetworks
    "KnownProxies" .Values.global.forwardedHeaders.knownProxies
    "TrustAnySource" .Values.global.forwardedHeaders.trustAnySource)) -}}
{{- end -}}

{{/* The trigger dispatcher's settings, to the two services that hold a trigger table — as JSON. */}}
{{- define "lembos.workflowTriggerSettings" -}}
{{- with .Values.platform.workflowTriggers -}}
{{- toJson (dict
  "Enabled" .enabled
  "PollInterval" .pollInterval
  "BatchSize" .batchSize
  "LeaseDuration" .leaseDuration
  "InitialRetryDelay" .initialRetryDelay
  "MaximumRetryDelay" .maximumRetryDelay) -}}
{{- end -}}
{{- end -}}

{{/* The ConfigMap holding a component's settings file. */}}
{{- define "lembos.settingsConfigMap" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "lembos.componentName" .ctx }}
  namespace: {{ .ctx.root.Release.Namespace }}
  labels:
    {{- include "lembos.labels" .ctx | nindent 4 }}
data:
  {{ include "lembos.settingsFile" .ctx.root }}: |
    {{- toPrettyJson .settings | nindent 4 }}
{{- end -}}

{{/* Where the settings file is mounted: beside the service's own appsettings.json. */}}
{{- define "lembos.settingsMount" -}}
- name: settings
  mountPath: /app/{{ include "lembos.settingsFile" . }}
  subPath: {{ include "lembos.settingsFile" . }}
  readOnly: true
{{- end -}}

{{- define "lembos.settingsVolume" -}}
- name: settings
  configMap:
    name: {{ include "lembos.componentName" . }}
{{- end -}}

{{/* ── Pod pieces shared by the four services ── */}}

{{/*
The CA bundle the services trust beyond the image's own: the one named in global.trustedCertificates, or the
CA this chart generated for the ingress. As JSON: {secretName, configMapName, keys}.
*/}}
{{- define "lembos.trust" -}}
{{- $trust := .Values.global.trustedCertificates -}}
{{- if or $trust.secretName $trust.configMapName -}}
{{- toJson $trust -}}
{{- else if and .Values.ingress.tls.enabled .Values.ingress.tls.generate -}}
{{- toJson (dict "secretName" (printf "%s-ingress-ca" (include "lembos.fullname" .)) "keys" (list "ca.crt")) -}}
{{- else -}}
{{- toJson dict -}}
{{- end -}}
{{- end -}}

{{- define "lembos.trustVolume" -}}
{{- $trust := include "lembos.trust" . | fromJson -}}
{{- if $trust.secretName }}
- name: trusted-certificates
  secret:
    secretName: {{ $trust.secretName }}
    {{- include "lembos.trustItems" $trust | nindent 4 }}
{{- else if $trust.configMapName }}
- name: trusted-certificates
  configMap:
    name: {{ $trust.configMapName }}
    {{- include "lembos.trustItems" $trust | nindent 4 }}
{{- end }}
{{- end -}}

{{/* Only the named keys — a CA Secret from cert-manager also holds the CA's private key. */}}
{{- define "lembos.trustItems" -}}
{{- with .keys }}
items:
  {{- range . }}
  - key: {{ . }}
    path: {{ . }}
  {{- end }}
{{- end }}
{{- end -}}

{{- define "lembos.trustMount" -}}
{{- $trust := include "lembos.trust" . | fromJson -}}
{{- if or $trust.secretName $trust.configMapName }}
- name: trusted-certificates
  mountPath: /etc/lembos/trust
  readOnly: true
{{- end }}
{{- end -}}

{{/* .NET reads every file in each SSL_CERT_DIR entry, so a mounted bundle needs no c_rehash. */}}
{{- define "lembos.trustEnv" -}}
{{- $trust := include "lembos.trust" . | fromJson -}}
{{- if or $trust.secretName $trust.configMapName }}
- name: SSL_CERT_DIR
  value: /etc/ssl/certs:/etc/lembos/trust
{{- end }}
{{- end -}}

{{/*
For every pod running one of this repository's .NET images, which have no init process: the pod's pause
container becomes PID 1 instead of the app. As PID 1 the app ignores every signal it has no handler for,
SIGABRT among them — and SIGABRT is how the runtime ends a process on an unhandled exception. A service that
failed to start (a database not up yet) then spun at full CPU, "Running" and never restarted, until its
startup probe gave up minutes later; a setup job would have held the install forever.
*/}}
{{- define "lembos.dotnetProcess" -}}
shareProcessNamespace: true
{{- end -}}

{{/*
Probes for a .NET service on its http port: /alive says the process answers, /health that its dependencies
do. The startup probe allows for migrations, which run before the service reports ready. Each carries the
Service name as Host, because the kubelet otherwise sends the pod's IP — a name the service's host
filtering (lembos.allowedHosts) refuses, which would read as a service that never came up. {root, component}
*/}}
{{- define "lembos.probes" -}}
{{- $host := include "lembos.componentName" . -}}
startupProbe:
  httpGet: {path: /alive, port: http, httpHeaders: [{name: Host, value: {{ $host | quote }}}]}
  periodSeconds: 5
  failureThreshold: 60
livenessProbe:
  httpGet: {path: /alive, port: http, httpHeaders: [{name: Host, value: {{ $host | quote }}}]}
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
readinessProbe:
  httpGet: {path: /health, port: http, httpHeaders: [{name: Host, value: {{ $host | quote }}}]}
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
{{- end -}}

{{/*
Scheduling for one component, falling back to the global settings. In a high-available install a component
with no affinity of its own prefers a node none of its replicas is on, so losing a node loses one of them.
*/}}
{{- define "lembos.scheduling" -}}
{{- with (.values.nodeSelector | default .root.Values.global.nodeSelector) }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with (.values.tolerations | default .root.Values.global.tolerations) }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with (.values.affinity | default .root.Values.global.affinity) }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- else }}
{{- if and .component (include "lembos.highAvailable" .root) }}
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              {{- include "lembos.selectorLabels" . | nindent 14 }}
{{- end }}
{{- end }}
{{- with .root.Values.global.hostAliases }}
hostAliases:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/* ── Network policy peers ── */}}

{{- define "lembos.peer" -}}
- podSelector:
    matchLabels:
      {{- include "lembos.selectorLabels" . | nindent 6 }}
{{- end -}}

{{- define "lembos.ingressControllerPeer" -}}
- namespaceSelector:
    {{- toYaml .Values.networkPolicy.ingressController.namespaceSelector | nindent 4 }}
  podSelector:
    {{- toYaml (.Values.networkPolicy.ingressController.podSelector | default dict) | nindent 4 }}
{{- end -}}

{{/* Egress every pod gets: DNS. */}}
{{- define "lembos.dnsEgress" -}}
- to:
    - namespaceSelector:
        {{- toYaml .Values.networkPolicy.dns.namespaceSelector | nindent 8 }}
      podSelector:
        {{- toYaml .Values.networkPolicy.dns.podSelector | nindent 8 }}
  ports:
    - {protocol: UDP, port: 53}
    - {protocol: TCP, port: 53}
{{- end -}}

{{/*
Egress to Identity's public origin, which is where the services fetch discovery documents, introspect and
request tokens: it is the issuer they validate, so they cannot be pointed at the Service instead. Depending
on the CNI that traffic is seen addressed to the ingress controller's pods or to its load balancer, so both
are allowed.
*/}}
{{- define "lembos.otelEgress" -}}
{{- with .Values.global.otel.endpoint }}
{{- $port := regexFind ":[0-9]+$" (urlParse .).host | trimPrefix ":" | default (ternary "4317" "4318" (eq $.Values.global.otel.protocol "grpc")) }}
# Telemetry, on the OTLP endpoint's port wherever it resolves: a collector in the cluster or beyond it.
- ports:
    - {protocol: TCP, port: {{ $port }}}
{{- end }}
{{- end -}}

{{- define "lembos.publicOriginEgress" -}}
- to:
    {{- include "lembos.ingressControllerPeer" . | nindent 4 }}
{{- with .Values.networkPolicy.externalHttps }}
- to:
    {{- range .cidrs }}
    - ipBlock:
        cidr: {{ . }}
    {{- end }}
  ports:
    {{- range .ports }}
    - {protocol: TCP, port: {{ . }}}
    {{- end }}
{{- end }}
{{- end -}}

{{/*
The pods behind a dependency, as a NetworkPolicy peer: the release's own, an upstream chart's or the
operator's by the labels they set, or anywhere for an external service.
*/}}
{{- define "lembos.postgresqlPeer" -}}
{{- $mode := include "lembos.postgresql.mode" . -}}
{{- if eq $mode "simple" -}}
{{- include "lembos.peer" (dict "root" . "component" "postgresql") -}}
{{- else if eq $mode "high-available" -}}
- podSelector:
    matchLabels:
      cnpg.io/cluster: {{ include "lembos.postgresql.clusterName" . }}
{{- else -}}
- ipBlock:
    cidr: 0.0.0.0/0
{{- end -}}
{{- end -}}

{{- define "lembos.redisPeer" -}}
{{- $mode := include "lembos.redis.mode" . -}}
{{- if eq $mode "simple" -}}
{{- include "lembos.peer" (dict "root" . "component" "redis") -}}
{{- else if eq $mode "high-available" -}}
- podSelector:
    matchLabels:
      app: {{ (index .Values "redis-ha").nameOverride | default "redis-ha" }}-haproxy
      release: {{ .Release.Name }}
{{- else -}}
- ipBlock:
    cidr: 0.0.0.0/0
{{- end -}}
{{- end -}}

{{/* The official chart's pods — every service and the schema job — by the labels it sets. */}}
{{- define "lembos.temporalHaPodLabels" -}}
app.kubernetes.io/name: {{ (index .Values "temporal-ha").nameOverride | default "temporal-ha" }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Whatever answers on Temporal's frontend port. */}}
{{- define "lembos.temporalPeer" -}}
{{- $mode := include "lembos.temporal.mode" . -}}
{{- if eq $mode "simple" -}}
{{- include "lembos.peer" (dict "root" . "component" "temporal") -}}
{{- else if eq $mode "high-available" -}}
- podSelector:
    matchLabels:
      {{- include "lembos.temporalHaPodLabels" . | nindent 6 }}
      app.kubernetes.io/component: frontend
{{- else -}}
- ipBlock:
    cidr: 0.0.0.0/0
{{- end -}}
{{- end -}}

{{/* Every Temporal pod that opens connections to PostgreSQL. */}}
{{- define "lembos.temporalServerPeer" -}}
{{- $mode := include "lembos.temporal.mode" . -}}
{{- if eq $mode "simple" -}}
{{- include "lembos.peer" (dict "root" . "component" "temporal") -}}
{{- else if eq $mode "high-available" -}}
- podSelector:
    matchLabels:
      {{- include "lembos.temporalHaPodLabels" . | nindent 6 }}
{{- end -}}
{{- end -}}

{{- define "lembos.postgresqlEgress" -}}
- to:
    {{- include "lembos.postgresqlPeer" . | nindent 4 }}
  ports:
    - {protocol: TCP, port: {{ include "lembos.postgresql.port" . }}}
{{- end -}}

{{- define "lembos.redisEgress" -}}
- to:
    {{- include "lembos.redisPeer" . | nindent 4 }}
  ports:
    - {protocol: TCP, port: {{ include "lembos.redis.port" . }}}
{{- end -}}

{{- define "lembos.temporalEgress" -}}
- to:
    {{- include "lembos.temporalPeer" . | nindent 4 }}
  ports:
    - {protocol: TCP, port: {{ include "lembos.temporal.port" . }}}
{{- end -}}

{{/*
Every published route, as JSON: the three services, and the two developer UIs when they are on. One list, so
the Ingresses, the HTTPRoutes and the generated certificate's names cannot disagree about what is published.
Identity's account-management listener is never in it.
*/}}
{{- define "lembos.routes" -}}
{{- $routes := list -}}
{{- range $component := list "identity" "orchestrator" "portal" -}}
{{- $values := index $.Values $component -}}
{{- if $values.ingress.enabled -}}
{{- $routes = append $routes (dict
  "component" $component
  "host" (include "lembos.host" (dict "root" $ "component" $component))
  "annotations" ($values.ingress.annotations | default dict)
  "longLived" (has $component (list "portal" "orchestrator"))) -}}
{{- end -}}
{{- end -}}
{{- with .Values.temporal.ui -}}
{{- if and .enabled .ingress.enabled -}}
{{- $routes = append $routes (dict
  "component" "temporal-ui"
  "host" (.ingress.host | default (printf "temporal.%s" $.Values.global.domain))
  "annotations" (.ingress.annotations | default dict)
  "longLived" false) -}}
{{- end -}}
{{- end -}}
{{- with .Values.mailpit -}}
{{- if and .enabled .ingress.enabled -}}
{{- $routes = append $routes (dict
  "component" "mailpit"
  "host" (.ingress.host | default (printf "mail.%s" $.Values.global.domain))
  "annotations" (.ingress.annotations | default dict)
  "longLived" true) -}}
{{- end -}}
{{- end -}}
{{- toJson $routes -}}
{{- end -}}

{{/* The TLS Secret an Ingress host is served with. */}}
{{- define "lembos.ingressTlsSecret" -}}
{{- $tls := .root.Values.ingress.tls -}}
{{- if $tls.secretName -}}
{{- $tls.secretName -}}
{{- else if $tls.generate -}}
{{- printf "%s-ingress-tls" (include "lembos.fullname" .root) -}}
{{- else -}}
{{- printf "%s-tls" .host -}}
{{- end -}}
{{- end -}}

{{- define "lembos.gitHubSecretName" -}}
{{- .Values.secrets.gitHub.existingSecret | default (include "lembos.secretName" .) -}}
{{- end -}}
