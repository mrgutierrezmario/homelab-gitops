{{- define "mcp.name" -}}
{{ .Release.Name }}
{{- end }}

{{- define "mcp.labels" -}}
app.kubernetes.io/name: insidertrack-mcp
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "mcp.selectorLabels" -}}
app.kubernetes.io/name: insidertrack-mcp
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* <mountPath>/health, the open route the server adds beside the endpoint. */}}
{{- define "mcp.healthPath" -}}
{{ .Values.mountPath | trimSuffix "/" }}/health
{{- end }}
