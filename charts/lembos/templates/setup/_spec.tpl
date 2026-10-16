{{/*
What the setup job makes exist, as the JSON its spec file holds (see Lembos.Setup's SetupSpec). Built from
values only — no `lookup` — so rendering it twice gives the same thing, which is what lets a GitOps
controller render this chart on every sync without anything being regenerated.
*/}}
{{- define "lembos.setup.spec" -}}
{{- $secrets := list -}}
{{- $platform := include "lembos.secretName" . -}}

{{- /* ── The release's own Secret ── */ -}}
{{- if not .Values.secrets.existingSecret -}}
{{- $clients := .Values.secrets.clientSecrets -}}
{{- $entries := list
  (dict "key" "client-secret-orchestrator" "value" $clients.orchestrator "generate" "key256")
  (dict "key" "client-secret-portal" "value" $clients.portal "generate" "key256")
  (dict "key" "client-secret-drift-reconciler" "value" $clients.driftReconciler "generate" "key256")
  (dict "key" "client-secret-agent-runner" "value" $clients.agentRunner "generate" "key256")
  (dict "key" "client-secret-directory-synchronizer" "value" $clients.directorySynchronizer "generate" "key256")
  (dict "key" "client-secret-execution-agent" "value" $clients.executionAgent "generate" "key256")
  (dict "key" "identity-encryption-key" "value" .Values.secrets.identityEncryptionKey "generate" "key256")
  (dict "key" "identity-admin-password" "value" .Values.secrets.identityAdminPassword "generate" "password") -}}

{{- /* PostgreSQL's password, unless a Secret somebody else manages holds it. External ones cannot be generated. */ -}}
{{- $mode := include "lembos.postgresql.mode" . -}}
{{- $external := .Values.postgresql.external -}}
{{- if and (eq $mode "external") (not $external.existingSecret) -}}
{{- $entries = append $entries (dict "key" "postgres-password" "value" (required "postgresql.external.password or postgresql.external.existingSecret is required when postgresql.mode is external" $external.password)) -}}
{{- else if or (eq $mode "high-available") (and (eq $mode "simple") (not .Values.postgresql.simple.existingSecret)) -}}
{{- $entries = append $entries (dict "key" "postgres-password" "value" .Values.secrets.postgresPassword "generate" "token") -}}
{{- end -}}

{{- /* Redis's password, where it is the release's to make. */ -}}
{{- $redis := include "lembos.redis.mode" . -}}
{{- $redisHa := index .Values "redis-ha" -}}
{{- if or (and (eq $redis "simple") (not .Values.redis.simple.existingSecret)) (and (eq $redis "high-available") (eq $redisHa.existingSecret $platform)) -}}
{{- $entries = append $entries (dict "key" (ternary $redisHa.authKey "redis-password" (eq $redis "high-available")) "value" .Values.secrets.redisPassword "generate" "token") -}}
{{- else if and (eq $redis "external") .Values.redis.external.password (not .Values.redis.external.existingSecret) -}}
{{- $entries = append $entries (dict "key" "redis-password" "value" .Values.redis.external.password) -}}
{{- end -}}

{{- /* GitHub issues these, so they are given or the install stops here rather than in a pod. */ -}}
{{- with .Values.secrets.gitHub -}}
{{- if and $.Values.platform.integrations.gitHub.enabled (not .existingSecret) -}}
{{- $entries = concat $entries (list
  (dict "key" "github-app-id" "value" (required "secrets.gitHub.appId is required when platform.integrations.gitHub.enabled" (toString .appId)))
  (dict "key" "github-app-org" "value" (required "secrets.gitHub.organization is required when platform.integrations.gitHub.enabled" .organization))
  (dict "key" "github-private-key-base64" "value" (required "secrets.gitHub.privateKeyBase64 is required when platform.integrations.gitHub.enabled" .privateKeyBase64))
  (dict "key" "github-client-id" "value" (required "secrets.gitHub.clientId is required when platform.integrations.gitHub.enabled" .clientId))
  (dict "key" "github-client-secret" "value" (required "secrets.gitHub.clientSecret is required when platform.integrations.gitHub.enabled" .clientSecret))) -}}
{{- end -}}
{{- end -}}

{{- $secrets = append $secrets (dict "name" $platform "type" "Opaque" "entries" $entries) -}}
{{- end -}}

{{- /*
CloudNativePG's owner role authenticates against a basic-auth Secret. It copies postgres-password, so the
role and every connection string are the same credential in the two shapes their readers expect.
*/ -}}
{{- if eq (include "lembos.postgresql.mode" .) "high-available" -}}
{{- $secrets = append $secrets (dict
  "name" (include "lembos.postgresql.appSecret" .)
  "type" "kubernetes.io/basic-auth"
  "entries" (list
    (dict "key" "username" "value" .Values.postgresql.highAvailable.owner)
    (dict "key" "password" "copyFrom" (dict "secret" $platform "key" "postgres-password")))) -}}
{{- end -}}

{{- /* ── The four key pairs ── */ -}}
{{- range $name := list "identitySigning" "identityDataProtection" "orchestratorDataProtection" "portalDataProtection" -}}
{{- $certificate := index $.Values.certificates $name -}}
{{- if not $certificate.existingSecret -}}
{{- $secrets = append $secrets (dict
  "name" (include "lembos.certificateSecretName" (dict "root" $ "name" $name))
  "type" "kubernetes.io/tls"
  "keyPair" (dict
    "subject" $certificate.subject
    "validityDays" (int $certificate.validityDays)
    "certificate" $certificate.certificate
    "privateKey" $certificate.privateKey)) -}}
{{- end -}}
{{- end -}}

{{- /* ── The ingress's local CA ── */ -}}
{{- if and .Values.ingress.tls.enabled .Values.ingress.tls.generate (not .Values.ingress.tls.secretName) -}}
{{- $domain := .Values.global.domain -}}
{{- $hosts := list (printf "*.%s" $domain) $domain -}}
{{- range (include "lembos.routes" . | fromJsonArray) -}}
{{- $hosts = append $hosts .host -}}
{{- end -}}
{{- $secrets = append $secrets (dict
  "name" (include "lembos.ingressTlsSecret" (dict "root" . "host" ""))
  "type" "kubernetes.io/tls"
  "localCa" (dict
    "caSecret" (printf "%s-ingress-ca" (include "lembos.fullname" .))
    "caSubject" (printf "Lembos local CA (%s)" $domain)
    "hosts" (uniq $hosts)
    "validityDays" (int .Values.ingress.tls.generateValidityDays))) -}}
{{- end -}}

{{- toJson (dict
  "secrets" $secrets
  "labels" (dict
    "app.kubernetes.io/part-of" "lembos"
    "app.kubernetes.io/instance" .Release.Name
    "app.kubernetes.io/managed-by" "lembos-setup")) -}}
{{- end -}}

{{/* Every Secret the job may touch, for the Role's resourceNames. */}}
{{- define "lembos.setup.secretNames" -}}
{{- $names := list -}}
{{- range (include "lembos.setup.spec" . | fromJson).secrets -}}
{{- $names = append $names .name -}}
{{- with .localCa -}}{{- $names = append $names .caSecret -}}{{- end -}}
{{- end -}}
{{- toJson (uniq $names) -}}
{{- end -}}
