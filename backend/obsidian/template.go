package obsidian

import "text/template"

var meetingTemplate = template.Must(template.New("meeting").Parse(`---
title: "{{.Title}}"
date: {{.Date}}
duration: {{.Duration}}
speakers:
{{- range .Speakers}}
  - "{{.}}"
{{- end}}
tags: [meeting, meetnotes]
---

# {{.Title}}

## Summary
{{.Summary}}

{{if .Decisions -}}
## Key Decisions
{{range .Decisions}}- {{.}}
{{end}}
{{end -}}

{{if .ActionItems -}}
## Action Items
{{range .ActionItems}}- [ ] {{.Description}}{{if .Assignee}} (@{{.Assignee}}){{end}}
{{end}}
{{end -}}

{{if .Topics -}}
## Discussion Topics
{{range .Topics}}### {{.Title}}
{{.Summary}}

{{end}}
{{end -}}

## Full Transcript
{{range .Segments}}**{{.Speaker}}** ({{.Timestamp}}): {{.Text}}
{{end}}
`))
