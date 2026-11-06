{{/* Common labels for wrapper-owned objects, separate from upstream helpers. */}}
{{- define "harbor-wrapper.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/* Shared spec for the independently enabled secret mappings. */}}
{{- define "harbor-wrapper.secret" -}}
{{- $root := .root -}}
{{- $secret := .secret -}}
{{- $feature := .feature -}}
apiVersion: secrets.infisical.com/v1beta1
kind: InfisicalStaticSecret
metadata:
  name: {{ $secret.secretName }}
  namespace: {{ $root.Release.Namespace }}
  labels:
    {{- include "harbor-wrapper.labels" $root | nindent 4 }}
spec:
  infisicalAuthRef:
    name: {{ required (printf "infisical.authRef.name is required when %s is enabled" $feature) $root.Values.infisical.authRef.name | quote }}
    namespace: {{ required (printf "infisical.authRef.namespace is required when %s is enabled" $feature) $root.Values.infisical.authRef.namespace | quote }}
  syncOptions:
    refreshInterval: {{ $secret.refreshInterval | quote }}
  sources:
    - projectSlug: {{ required (printf "infisical.projectSlug is required when %s is enabled" $feature) $root.Values.infisical.projectSlug | quote }}
      environmentSlug: {{ required (printf "infisical.environmentSlug is required when %s is enabled" $feature) $root.Values.infisical.environmentSlug | quote }}
      secretPath: {{ $secret.secretPath | quote }}
      recursive: {{ $secret.recursive }}
  targets:
    - name: {{ $secret.secretName }}
      namespace: {{ $root.Release.Namespace }}
      kind: Secret
      secretType: Opaque
      creationPolicy: Orphan
      metadata:
        labels: {}
        annotations: {}
      template:
        engineVersion: v1
        data:
          {{- range $key, $text := .data }}
          {{ $key }}: {{ $text | quote }}
          {{- end }}
{{- end -}}
