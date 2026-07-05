{{- define "gitops-demo.fullname" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "gitops-demo.labels" -}}
app.kubernetes.io/name: {{ include "gitops-demo.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
