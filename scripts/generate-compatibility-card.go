package main

import (
	"fmt"
	"html"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

type entry struct {
	fields map[string]string
}

type config struct {
	rows   []entry
	legend []entry
}

type statusInfo struct {
	label string
	color string
	fill  string
}

var statuses = map[string]statusInfo{
	"verified":    {label: "Verified", color: "#30d158", fill: "#193325"},
	"partial":     {label: "Partial", color: "#ffd60a", fill: "#3a3217"},
	"untested":    {label: "Untested", color: "#8e8e93", fill: "#292a2e"},
	"unsupported": {label: "Unsupported", color: "#ff453a", fill: "#3b1d20"},
}

func projectRoot() string {
	if override := os.Getenv("GONERINO_ROOT"); override != "" {
		return override
	}
	_, source, _, _ := runtime.Caller(0)
	return filepath.Dir(filepath.Dir(source))
}

func parseString(value string) (string, error) {
	value = stripInlineComment(value)
	if len(value) < 2 {
		return "", fmt.Errorf("unsupported TOML value %q", value)
	}
	switch value[0] {
	case '"':
		if value[len(value)-1] != '"' {
			return "", fmt.Errorf("unsupported TOML value %q", value)
		}
		return strconv.Unquote(value)
	case '\'':
		if value[len(value)-1] != '\'' {
			return "", fmt.Errorf("unsupported TOML value %q", value)
		}
		return value[1 : len(value)-1], nil
	default:
		return "", fmt.Errorf("unsupported TOML value %q", value)
	}
}

func stripInlineComment(value string) string {
	value = strings.TrimSpace(value)
	quote := byte(0)
	escaped := false
	for index := 0; index < len(value); index++ {
		character := value[index]
		if quote == '"' {
			if escaped {
				escaped = false
				continue
			}
			if character == '\\' {
				escaped = true
				continue
			}
			if character == quote {
				quote = 0
			}
			continue
		}
		if quote == '\'' {
			if character == quote {
				quote = 0
			}
			continue
		}
		if character == '"' || character == '\'' {
			quote = character
			continue
		}
		if character == '#' {
			return strings.TrimSpace(value[:index])
		}
	}
	return value
}

func parseConfig(path string) (config, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return config{}, err
	}
	result := config{}
	section := ""
	var current *entry
	for _, rawLine := range strings.Split(string(contents), "\n") {
		line := stripInlineComment(rawLine)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[[") && strings.HasSuffix(line, "]]") {
			section = strings.TrimSpace(line[2 : len(line)-2])
			item := entry{fields: map[string]string{}}
			switch section {
			case "rows":
				result.rows = append(result.rows, item)
				current = &result.rows[len(result.rows)-1]
			case "legend":
				result.legend = append(result.legend, item)
				current = &result.legend[len(result.legend)-1]
			default:
				current = nil
			}
			continue
		}
		separator := strings.IndexByte(line, '=')
		if separator < 0 {
			return config{}, fmt.Errorf("invalid TOML line %q", line)
		}
		key := strings.TrimSpace(line[:separator])
		value, err := parseString(line[separator+1:])
		if err != nil {
			return config{}, err
		}
		if section == "" {
			continue
		} else if current != nil {
			current.fields[key] = value
		}
	}
	return result, nil
}

func field(item entry, key string) string {
	return item.fields[key]
}

func statusData(value string) statusInfo {
	if status, ok := statuses[value]; ok {
		return status
	}
	return statuses["untested"]
}

func wrap(value string, width int, limit int) []string {
	words := strings.Fields(value)
	lines := make([]string, 0, limit)
	current := ""
	for _, word := range words {
		candidate := word
		if current != "" {
			candidate = current + " " + word
		}
		if current != "" && len([]rune(candidate)) > width {
			lines = append(lines, current)
			if len(lines) == limit {
				return lines
			}
			current = word
		} else {
			current = candidate
		}
	}
	if current != "" && len(lines) < limit {
		lines = append(lines, current)
	}
	return lines
}

func renderLegendItem(x, y float64, item entry) []string {
	status := statusData(field(item, "status"))
	label := field(item, "label")
	if label == "" {
		label = status.label
	}
	description := wrap(field(item, "description"), 25, 2)
	parts := []string{
		fmt.Sprintf(`<circle cx="%.0f" cy="%.0f" r="5" fill="%s"/>`, x+7, y+8, status.color),
		fmt.Sprintf(`<text x="%.0f" y="%.0f" fill="#f5f5f7" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="13" font-weight="600">%s</text>`, x+20, y+13, html.EscapeString(label)),
	}
	for index, line := range description {
		parts = append(parts, fmt.Sprintf(`<text x="%.0f" y="%.0f" fill="#98989f" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="11">%s</text>`, x, y+34+float64(index*16), html.EscapeString(line)))
	}
	return parts
}

func render(data config) string {
	width := 1040.0
	margin := 40.0
	rowHeight := 72.0
	rowGap := 2.0
	legendHeight := 104.0
	columns := 2.0
	columnGap := 36.0
	columnWidth := (width - margin*2 - columnGap) / columns
	rowsPerColumn := math.Max(math.Ceil(float64(len(data.rows))/columns), 1)
	rowsHeight := rowsPerColumn*rowHeight + math.Max(rowsPerColumn-1, 0)*rowGap
	height := margin + rowsHeight + 28 + legendHeight + margin
	parts := []string{
		fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" width="%.0f" height="%.0f" viewBox="0 0 %.0f %.0f" role="img" aria-labelledby="title description">`, width, height, width, height),
		`<title id="title">Compatibility</title>`,
		`<desc id="description">Gonerino compatibility information and status legend.</desc>`,
		`<rect width="100%" height="100%" rx="26" fill="#121316" stroke="#2a2d33" stroke-width="2"/>`,
	}
	for index, row := range data.rows {
		column := float64(index) / rowsPerColumn
		column = math.Floor(column)
		rowIndex := float64(index) - column*rowsPerColumn
		x := margin + column*(columnWidth+columnGap)
		y := margin + rowIndex*(rowHeight+rowGap)
		status := statusData(field(row, "status"))
		label := html.EscapeString(field(row, "label"))
		value := field(row, "value")
		if value == "" {
			value = "Not specified"
		}
		value = html.EscapeString(value)
		parts = append(parts,
			fmt.Sprintf(`<line x1="%.0f" y1="%.0f" x2="%.0f" y2="%.0f" stroke="#2a2d33" stroke-width="1"/>`, x, y+rowHeight-1, x+columnWidth, y+rowHeight-1),
			fmt.Sprintf(`<circle cx="%.0f" cy="%.0f" r="5" fill="%s"/>`, x+7, y+25, status.color),
			fmt.Sprintf(`<text x="%.0f" y="%.0f" fill="#f5f5f7" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="15" font-weight="600">%s</text>`, x+24, y+23, label),
			fmt.Sprintf(`<text x="%.0f" y="%.0f" fill="#98989f" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="13">%s</text>`, x+24, y+48, value),
			fmt.Sprintf(`<rect x="%.0f" y="%.0f" width="104" height="28" rx="14" fill="%s"/>`, x+columnWidth-112, y+10, status.fill),
			fmt.Sprintf(`<text x="%.0f" y="%.0f" text-anchor="middle" fill="%s" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="11" font-weight="600">%s</text>`, x+columnWidth-60, y+28, status.color, html.EscapeString(status.label)),
		)
	}
	legendY := margin + rowsHeight + 28
	parts = append(parts,
		fmt.Sprintf(`<line x1="%.0f" y1="%.0f" x2="%.0f" y2="%.0f" stroke="#2a2d33" stroke-width="1"/>`, margin, legendY-14, width-margin, legendY-14),
		fmt.Sprintf(`<text x="%.0f" y="%.0f" fill="#98989f" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="11" font-weight="600" letter-spacing="1">STATUS</text>`, margin, legendY+10),
	)
	legendWidth := (width - margin*2) / math.Max(float64(len(data.legend)), 1)
	for index, item := range data.legend {
		parts = append(parts, renderLegendItem(margin+float64(index)*legendWidth, legendY+28, item)...)
	}
	parts = append(parts, "</svg>")
	return strings.Join(parts, "\n") + "\n"
}

func main() {
	root := projectRoot()
	data, err := parseConfig(filepath.Join(root, ".github", "compatibility.toml"))
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".github", "compatibility.svg"), []byte(render(data)), 0644); err != nil {
		panic(err)
	}
}
