package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

var sectionPattern = regexp.MustCompile(`(?m)^## ([^\n]+)$`)
var commitPattern = regexp.MustCompile(`(?i)^([a-z]+)(?:\([^)]*\))?(!)?:\s*(.+)$`)

var groups = map[string]string{
	"feat":     "Features",
	"fix":      "Fixes",
	"perf":     "Performance",
	"refactor": "Refactoring",
	"docs":     "Documentation",
	"test":     "Tests",
	"build":    "Build",
	"ci":       "CI",
	"chore":    "Maintenance",
	"style":    "Style",
	"revert":   "Reverts",
}

var groupOrder = []string{
	"Breaking changes",
	"Features",
	"Fixes",
	"Performance",
	"Refactoring",
	"Documentation",
	"Tests",
	"Build",
	"CI",
	"Maintenance",
	"Style",
	"Reverts",
	"Other changes",
}

func rootDirectory() string {
	if override := os.Getenv("GONERINO_ROOT"); override != "" {
		return override
	}
	_, source, _, _ := runtime.Caller(0)
	return filepath.Dir(filepath.Dir(source))
}

func command(root string, name string, args ...string) string {
	process := exec.Command(name, args...)
	process.Dir = root
	output, err := process.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(output))
}

func previousTag(root string) string {
	return command(root, "git", "describe", "--tags", "--abbrev=0")
}

func commitsSince(root, tag string) [][2]string {
	rangeName := "HEAD"
	if tag != "" {
		rangeName = tag + "..HEAD"
	}
	output := command(root, "git", "log", "--no-merges", "--format=%h%x09%s", rangeName)
	commits := make([][2]string, 0)
	for _, line := range strings.Split(output, "\n") {
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) == 2 {
			commits = append(commits, [2]string{parts[0], parts[1]})
		}
	}
	return commits
}

func sectionVersion(heading string) string {
	return strings.SplitN(heading, " ", 2)[0]
}

func currentSection(contents, version string) string {
	matches := sectionPattern.FindAllStringSubmatchIndex(contents, -1)
	for index, match := range matches {
		heading := contents[match[2]:match[3]]
		if sectionVersion(heading) != version {
			continue
		}
		start := match[0]
		end := len(contents)
		if index+1 < len(matches) {
			end = matches[index+1][0]
		}
		return strings.TrimSpace(contents[start:end])
	}
	return ""
}

func generatedSection(version string, commits [][2]string) string {
	grouped := map[string][]string{}
	for _, commit := range commits {
		match := commitPattern.FindStringSubmatch(commit[1])
		group := "Other changes"
		entry := strings.TrimSpace(commit[1])
		if match != nil {
			group = groups[strings.ToLower(match[1])]
			if group == "" {
				group = "Other changes"
			}
			entry = strings.TrimSpace(match[3])
			if match[2] != "" {
				group = "Breaking changes"
			}
		}
		grouped[group] = append(grouped[group], fmt.Sprintf("- %s (%s)", entry, commit[0]))
	}
	lines := []string{"## " + version + " - " + time.Now().Format("2006-01-02"), ""}
	for _, group := range groupOrder {
		entries := grouped[group]
		if len(entries) == 0 {
			continue
		}
		lines = append(lines, "### "+group, "")
		lines = append(lines, entries...)
		lines = append(lines, "")
	}
	if len(lines) == 2 {
		lines = append(lines, "No conventional commits were found for this release.", "")
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

func removeCurrentSection(contents, version string) string {
	matches := sectionPattern.FindAllStringSubmatchIndex(contents, -1)
	if len(matches) == 0 {
		return contents
	}
	parts := make([]string, 0, len(matches)+1)
	parts = append(parts, contents[:matches[0][0]])
	for index, match := range matches {
		end := len(contents)
		if index+1 < len(matches) {
			end = matches[index+1][0]
		}
		if sectionVersion(contents[match[2]:match[3]]) != version {
			parts = append(parts, contents[match[0]:end])
		}
	}
	return strings.Join(parts, "")
}

func updateChangelog(root, version string) error {
	changelogPath := filepath.Join(root, "CHANGELOG.md")
	releaseNotesPath := filepath.Join(root, ".github", "release-notes.md")
	contents := "# Changelog\n"
	if existing, err := os.ReadFile(changelogPath); err == nil {
		contents = string(existing)
	} else if !os.IsNotExist(err) {
		return err
	}
	commits := commitsSince(root, previousTag(root))
	section := ""
	if len(commits) > 0 {
		section = generatedSection(version, commits)
	} else {
		section = currentSection(contents, version)
	}
	if section == "" {
		section = generatedSection(version, nil)
	}
	withoutCurrent := removeCurrentSection(contents, version)
	history := strings.TrimSpace(strings.TrimPrefix(withoutCurrent, "# Changelog"))
	result := "# Changelog\n\n" + section
	if history != "" {
		result += "\n\n" + history
	}
	result += "\n"
	if err := os.WriteFile(changelogPath, []byte(result), 0644); err != nil {
		return err
	}
	return os.WriteFile(releaseNotesPath, []byte(section+"\n"), 0644)
}

func main() {
	version := flag.String("version", "", "")
	flag.Parse()
	if *version == "" {
		panic("version is required")
	}
	if err := updateChangelog(rootDirectory(), *version); err != nil {
		panic(err)
	}
}
