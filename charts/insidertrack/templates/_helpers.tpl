{{- define "it.name" -}}
{{ .Release.Name }}
{{- end }}

{{- define "it.postgresName" -}}
{{ .Release.Name }}-postgres
{{- end }}

{{- define "it.labels" -}}
app.kubernetes.io/name: insidertrack
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/* component is "app" or "postgres" */}}
{{- define "it.selectorLabels" -}}
app.kubernetes.io/name: insidertrack
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "it.publicDomain" -}}
{{ .Values.ingress.host }}.{{ .Values.tailnet }}
{{- end }}
