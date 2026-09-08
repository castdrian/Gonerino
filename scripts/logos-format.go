package main

import (
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"
)

func main() {
	contents, err := io.ReadAll(os.Stdin)
	if err != nil {
		os.Exit(1)
	}
	filterTokens := []string{"%property", "%config", "%hookf", "%ctor", "%dtor", "%init", "%c", "%orig", "%log"}
	specialTokens := []string{"%hook", "%end", "%new", "%group", "%subclass"}
	lines := strings.Split(string(contents), "\n")
	formatted := make([]string, 0, len(lines))
	for _, line := range lines {
		for _, token := range filterTokens {
			if strings.Contains(line, token) {
				pattern := regexp.MustCompile(`%(` + regexp.QuoteMeta(token[1:]) + `)\b`)
				line = pattern.ReplaceAllString(line, `@logosformat$1`)
			}
		}
		for _, token := range specialTokens {
			if strings.Contains(line, token) {
				pattern := regexp.MustCompile(`%(` + regexp.QuoteMeta(token[1:]) + `)\b`)
				line = pattern.ReplaceAllString(line, `@logosformat$1`) + ";"
			}
		}
		formatted = append(formatted, line)
	}
	command := exec.Command("clang-format", os.Args[1:]...)
	command.Stdin = strings.NewReader(strings.Join(formatted, "\n"))
	command.Stderr = os.Stderr
	output, err := command.Output()
	if err != nil {
		if exitError, ok := err.(*exec.ExitError); ok {
			os.Stderr.Write(exitError.Stderr)
			os.Exit(exitError.ExitCode())
		}
		os.Exit(1)
	}
	for _, line := range strings.Split(string(output), "\n") {
		if strings.Contains(line, "@logosformat") {
			line = strings.ReplaceAll(line, "@logosformat", "%")
			if containsAny(line, specialTokens) {
				line = strings.ReplaceAll(line, ";", "")
			}
		}
		os.Stdout.WriteString(line + "\n")
	}
}

func containsAny(value string, candidates []string) bool {
	for _, candidate := range candidates {
		if strings.Contains(value, candidate) {
			return true
		}
	}
	return false
}
