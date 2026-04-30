{{- define "nginx-demo-eso.fullname" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "nginx-demo-eso.labels" -}}
app.kubernetes.io/name: {{ include "nginx-demo-eso.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "nginx-demo-eso.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nginx-demo-eso.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
