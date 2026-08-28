{{/*
Chart name, truncated and DNS-1123-safe.
*/}}
{{- define "cloudcrafter.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name for the whole release (not used per-microservice —
see cloudcrafter.serviceFullname for that).
*/}}
{{- define "cloudcrafter.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "cloudcrafter.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Per-microservice resource name. Kept as the plain service name (e.g. "users")
rather than prefixed with the release name, so that:
  - the existing Ingress/Service names Task 1 already relies on
    (individual services' server.js files have no coupling to this, but
    k8s/<name>-service.yaml files and the Ingress backend names do) stay
    stable when moving from raw manifests to Helm, and
  - other charts/scripts (e.g. localstack/deploy-lambda.sh, which targets
    the notifications-external Service by name) keep working unmodified.
Takes a dict with "root" (the top-level template context) and "name"
(the microservice key, e.g. "users").
*/}}
{{- define "cloudcrafter.serviceFullname" -}}
{{- .name -}}
{{- end -}}

{{/*
Standard Helm labels, applied to every resource plus any operator-supplied
global.extraLabels (e.g. environment tags for later multi-env work).
*/}}
{{- define "cloudcrafter.labels" -}}
helm.sh/chart: {{ include "cloudcrafter.name" . }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: cloudcrafter
{{- with .Values.global.extraLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Selector labels for a specific microservice. Deliberately just "app: <name>"
to exactly match the Task 1 raw manifests' selector convention
(k8s/*-deployment.yaml / k8s/*-service.yaml both use `app: <service>`), so
Services select the right Pods whether the cluster was set up via kubectl
apply -f k8s/ or via this chart.
*/}}
{{- define "cloudcrafter.selectorLabels" -}}
app: {{ .name }}
{{- end -}}

{{/*
Resolves the namespace resources should render into: only set when
global.namespaceOverride is explicitly provided; otherwise resources omit
metadata.namespace entirely and simply follow `helm install -n <namespace>` /
the current kube-context namespace, same as plain `kubectl apply` would.
This is what keeps the chart free of any hardcoded namespace (see
values.yaml global.namespaceOverride and README.md "Multi-environment
portability").
*/}}
{{- define "cloudcrafter.namespace" -}}
{{- if .Values.global.namespaceOverride -}}
{{- .Values.global.namespaceOverride -}}
{{- else -}}
{{- .Release.Namespace -}}
{{- end -}}
{{- end -}}
