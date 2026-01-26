{{/*
Expand the name of the chart.
*/}}
{{- define "sogo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "sogo.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "sogo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "sogo.labels" -}}
helm.sh/chart: {{ include "sogo.chart" . }}
{{ include "sogo.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "sogo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sogo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
PostgreSQL connection URL
*/}}
{{- define "sogo.postgresqlURL" -}}
{{- $user := .Values.postgresql.username -}}
{{- $host := printf "%s-postgres-rw.%s.svc.cluster.local" (include "sogo.fullname" .) .Release.Namespace -}}
{{- $port := "5432" -}}
{{- $db := .Values.postgresql.database -}}
{{- printf "postgresql://%s:${POSTGRES_PASSWORD}@%s:%s/%s?sslmode=require" $user $host $port $db -}}
{{- end }}
