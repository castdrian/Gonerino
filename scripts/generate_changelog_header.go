package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

func main() {
	_, source, _, _ := runtime.Caller(0)
	root := filepath.Dir(filepath.Dir(source))
	if override := os.Getenv("GONERINO_ROOT"); override != "" {
		root = override
	}
	sourcePath := filepath.Join(root, "CHANGELOG.md")
	outputPath := filepath.Join(root, "headers", "ChangelogData.h")
	contents, err := os.ReadFile(sourcePath)
	if err != nil {
		if !os.IsNotExist(err) {
			panic(err)
		}
		contents = []byte("# Changelog\n")
	}
	escaped := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\r", "", "\n", `\n`).Replace(string(contents))
	output := []byte(`#define GONERINO_CHANGELOG @"` + escaped + `"` + "\n")
	if err := os.WriteFile(outputPath, output, 0644); err != nil {
		panic(err)
	}
}
