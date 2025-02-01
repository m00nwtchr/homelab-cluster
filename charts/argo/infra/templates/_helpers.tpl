{{- define "domainDashed" -}}
{{- .Values.domain | replace "." "-" -}}
{{- end -}}