{{/* Resource name */}}
{{- define "nginx-demo.fullname" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels */}}
{{- define "nginx-demo.labels" -}}
app.kubernetes.io/name: {{ include "nginx-demo.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "nginx-demo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nginx-demo.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
