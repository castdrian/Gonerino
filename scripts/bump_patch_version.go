package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
)

func main() {
	_, source, _, _ := runtime.Caller(0)
	root := filepath.Dir(filepath.Dir(source))
	if override := os.Getenv("GONERINO_ROOT"); override != "" {
		root = override
	}
	path := filepath.Join(root, "control")
	contents, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	pattern := regexp.MustCompile(`(?m)^Version:[ \t]*([0-9]+)\.([0-9]+)\.([0-9]+)[ \t]*$`)
	match := pattern.FindSubmatchIndex(contents)
	if match == nil {
		panic("control does not contain a semantic version")
	}
	major, err := strconv.Atoi(string(contents[match[2]:match[3]]))
	if err != nil {
		panic(err)
	}
	minor, err := strconv.Atoi(string(contents[match[4]:match[5]]))
	if err != nil {
		panic(err)
	}
	patch, err := strconv.Atoi(string(contents[match[6]:match[7]]))
	if err != nil {
		panic(err)
	}
	next := fmt.Sprintf("%d.%d.%d", major, minor, patch+1)
	replacement := []byte("Version: " + next)
	updated := make([]byte, 0, len(contents)+len(replacement))
	updated = append(updated, contents[:match[0]]...)
	updated = append(updated, replacement...)
	updated = append(updated, contents[match[1]:]...)
	if err := os.WriteFile(path, updated, 0644); err != nil {
		panic(err)
	}
	fmt.Println(next)
}
