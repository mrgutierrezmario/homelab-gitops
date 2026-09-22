{{- define "ln.name" -}}
{{ .Release.Name }}
{{- end }}

{{- define "ln.postgresName" -}}
{{ .Release.Name }}-postgres
{{- end }}

{{- define "ln.minioName" -}}
{{ .Release.Name }}-minio
{{- end }}

{{- define "ln.labels" -}}
app.kubernetes.io/name: lecture-notes
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "ln.selectorLabels" -}}
app.kubernetes.io/name: lecture-notes
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "ln.publicUrl" -}}
https://{{ .Values.ingress.host }}.{{ .Values.tailnet }}
{{- end }}
