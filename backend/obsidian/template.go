package obsidian

import (
	"strings"
	"text/template"
)

var templateFuncs = template.FuncMap{
	"yamlEscape": func(s string) string {
		s = strings.ReplaceAll(s, `\`, `\\`)
		s = strings.ReplaceAll(s, `"`, `\"`)
		return s
	},
}

var meetingTemplate = template.Must(template.New("meeting").Funcs(templateFuncs).Parse(`---
title: "{{yamlEscape .Title}}"
date: {{.Date}}
duration: {{.Duration}}
speakers:
{{- range .Speakers}}
  - "{{yamlEscape .}}"
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
