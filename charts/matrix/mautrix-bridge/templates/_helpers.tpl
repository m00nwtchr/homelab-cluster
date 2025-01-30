{{- define "bridge-mode" -}}
  {{- if eq .Values.bridge.type "meta" -}}
    {{- .Values.meta.mode -}}
  {{- else -}}
    {{- .Values.bridge.type -}}
  {{- end -}}
{{- end -}}

{{- define "bridge-domain" -}}
{{- if empty .Values.bridge.publicDomain -}}
{{- $bridgeDomain := printf "%s.%s" .Release.Name .Values.matrix.serverName -}}
{{- $bridgeDomain -}}
{{- else -}}
{{- .Values.bridge.publicDomain -}}
{{- end -}}
{{- end -}}

{{- define "escape-dots" -}}
  {{- $str := . -}}
  {{- $escStr := . | replace "." "\\." -}}
  {{- $escStr -}}
{{- end -}}


{{- define "gen-secret" -}}
{{- $secret := lookup "v1" "Secret" .Release.Namespace "conduit-registration-secret" -}}
{{- if $secret -}}
token: {{ $secret.data.token }}
{{- else -}}
token: {{ randAlphaNum 72 | b64enc }}
{{- end -}}
{{- end -}}