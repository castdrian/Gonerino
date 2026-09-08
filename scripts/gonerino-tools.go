package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
)

const pinnedDeviceID = "00008030-001624583AF9402E"

const youtubeBundleID = "com.google.ios.youtube"

var blockListKeys = []string{
	"GonerinoBlockedChannels",
	"GonerinoBlockedVideos",
	"GonerinoBlockedWords",
}

func repoRoot() (string, error) {
	if override := os.Getenv("GONERINO_ROOT"); override != "" {
		return filepath.Abs(override)
	}
	if _, source, _, ok := runtime.Caller(0); ok {
		directory := filepath.Dir(filepath.Dir(source))
		if _, err := os.Stat(filepath.Join(directory, "control")); err == nil {
			return directory, nil
		}
	}
	directory, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(directory, "control")); err == nil {
			return directory, nil
		}
		parent := filepath.Dir(directory)
		if parent == directory {
			return "", errors.New("could not locate Gonerino repository root")
		}
		directory = parent
	}
}

func ensureParent(path string) error {
	return os.MkdirAll(filepath.Dir(path), 0755)
}

func writeText(path, contents string) error {
	if err := ensureParent(path); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(contents), 0644)
}

func runOutput(directory, name string, args ...string) ([]byte, error) {
	command := exec.Command(name, args...)
	if directory != "" {
		command.Dir = directory
	}
	return command.Output()
}

func runToFile(directory, outputPath, name string, args ...string) error {
	if err := ensureParent(outputPath); err != nil {
		return err
	}
	file, err := os.Create(outputPath)
	if err != nil {
		return err
	}
	defer file.Close()
	command := exec.Command(name, args...)
	if directory != "" {
		command.Dir = directory
	}
	command.Stdout = file
	command.Stderr = file
	return command.Run()
}

func runDiscard(name string, args ...string) error {
	command := exec.Command(name, args...)
	command.Stdout = nil
	command.Stderr = nil
	return command.Run()
}

func cliPath() string {
	if value := os.Getenv("JB_P1LOT_BIN"); value != "" {
		return value
	}
	if value, err := exec.LookPath("jb-p1lot"); err == nil {
		return value
	}
	return "jb-p1lot"
}

func cliArgs(device, action string, args ...string) []string {
	result := []string{action, "--json", "--device", device}
	return append(result, args...)
}

func cliToFile(outputPath, device, action string, args ...string) error {
	return runToFile("", outputPath, cliPath(), cliArgs(device, action, args...)...)
}

func cliOutput(device, action string, args ...string) ([]byte, error) {
	return runOutput("", cliPath(), cliArgs(device, action, args...)...)
}

func commandOutput(path string) string {
	contents, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return commandOutputBytes(contents)
}

func commandOutputBytes(contents []byte) string {
	var value any
	if json.Unmarshal(contents, &value) != nil {
		return ""
	}
	if data, ok := findValue(value, "data"); ok {
		if output, ok := findValue(data, "output"); ok {
			if text, ok := output.(string); ok {
				return text
			}
		}
		if text, ok := data.(string); ok {
			return text
		}
	}
	if text, ok := value.(string); ok {
		return text
	}
	return ""
}

func findValue(value any, key string) (any, bool) {
	switch typed := value.(type) {
	case map[string]any:
		if result, ok := typed[key]; ok {
			return result, true
		}
		for _, child := range typed {
			if result, ok := findValue(child, key); ok {
				return result, true
			}
		}
	case []any:
		for _, child := range typed {
			if result, ok := findValue(child, key); ok {
				return result, true
			}
		}
	}
	return nil, false
}

func jsonNumber(path, key string) (float64, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	var value any
	if err := json.Unmarshal(contents, &value); err != nil {
		return 0, err
	}
	result, ok := findValue(value, key)
	if !ok {
		return 0, fmt.Errorf("JSON key %s is missing", key)
	}
	switch typed := result.(type) {
	case float64:
		return typed, nil
	case string:
		return strconv.ParseFloat(typed, 64)
	default:
		return 0, fmt.Errorf("JSON key %s is not numeric", key)
	}
}

func nowMillis() int64 {
	return time.Now().UnixMilli()
}

func sleepMillis(milliseconds int) {
	time.Sleep(time.Duration(milliseconds) * time.Millisecond)
}

func runID() string {
	return time.Now().UTC().Format("20060102T150405Z") + "-" + strconv.Itoa(os.Getpid())
}

func firstNonEmptyLine(value string) string {
	for _, line := range strings.Split(value, "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			return line
		}
	}
	return ""
}

func checkDeviceStatus(path, expectedID string) error {
	contents, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var value any
	if err := json.Unmarshal(contents, &value); err != nil {
		return fmt.Errorf("device status was not JSON: %w", err)
	}
	if identifier, ok := findValue(value, "id"); !ok || identifier != expectedID {
		return fmt.Errorf("device status did not match device %s", expectedID)
	}
	if product, ok := findValue(value, "productType"); !ok || product != "iPhone12,8" {
		return errors.New("pinned device is not the iPhone SE")
	}
	bridge, ok := findValue(value, "bridge")
	if !ok || bridge != true {
		return errors.New("pinned device bridge is unavailable")
	}
	return nil
}

type metadataFixture struct {
	Name            string            `json:"name"`
	RendererClass   string            `json:"rendererClass"`
	Node            map[string]any    `json:"node"`
	Expected        map[string]string `json:"expected"`
	ExpectedVisible bool              `json:"expectedVisible"`
}

var metadataPaths = map[string][][]string{
	"long": {
		{"videoId"}, {"videoID"}, {"videoTitle"}, {"title"}, {"ownerDisplayName"}, {"channelName"}, {"channel"},
		{"element", "properties", "videoId"}, {"element", "properties", "videoTitle"}, {"element", "properties", "channelName"},
		{"element", "allProperties", "videoId"}, {"element", "allProperties", "videoTitle"}, {"element", "allProperties", "channelName"},
		{"renderer", "videoRenderer", "videoId"}, {"renderer", "videoRenderer", "videoTitle"}, {"renderer", "videoRenderer", "ownerDisplayName"},
	},
	"elements": {
		{"contentVideoId"}, {"videoId"}, {"contentTitle"}, {"videoTitle"}, {"ownerDisplayName"}, {"channelName"},
		{"element", "properties", "contentVideoId"}, {"element", "properties", "contentTitle"}, {"element", "properties", "ownerDisplayName"},
		{"element", "allProperties", "contentVideoId"}, {"element", "allProperties", "contentTitle"}, {"element", "allProperties", "ownerDisplayName"},
	},
	"shorts": {
		{"videoId"}, {"videoID"}, {"title"}, {"videoTitle"}, {"channel"}, {"channelName"}, {"ownerDisplayName"},
		{"currentVideo", "videoId"}, {"currentVideo", "videoTitle"}, {"currentVideo", "title"}, {"currentVideo", "channel"}, {"currentVideo", "channelName"},
	},
}

func valueAt(node map[string]any, path []string) string {
	var value any = node
	for _, key := range path {
		object, ok := value.(map[string]any)
		if !ok {
			return ""
		}
		value = object[key]
	}
	result, ok := value.(string)
	if !ok {
		return ""
	}
	return result
}

func rendererKind(renderer string) string {
	name := strings.ToLower(renderer)
	if strings.Contains(name, "elm") || strings.Contains(name, "element") {
		return "elements"
	}
	if strings.Contains(name, "short") || strings.Contains(name, "reel") {
		return "shorts"
	}
	if strings.Contains(name, "ytvideo") {
		return "long"
	}
	return ""
}

func syntheticChannel(value string) bool {
	value = strings.ToLower(strings.TrimSpace(value))
	return value == "action menu" || value == "more actions"
}

func extractMetadata(fixture metadataFixture) map[string]string {
	result := map[string]string{}
	kind := rendererKind(fixture.RendererClass)
	for _, path := range metadataPaths[kind] {
		value := valueAt(fixture.Node, path)
		if value == "" {
			continue
		}
		key := strings.ToLower(path[len(path)-1])
		switch {
		case strings.Contains(key, "id") && result["id"] == "":
			result["id"] = value
		case (strings.Contains(key, "title") || key == "name") && result["title"] == "":
			result["title"] = value
		case (strings.Contains(key, "channel") || strings.Contains(key, "owner")) && result["channel"] == "" && !syntheticChannel(value):
			result["channel"] = value
		}
	}
	return result
}

func metadataBlocked(metadata map[string]string, videoIDs, channels, words []string) bool {
	for _, value := range videoIDs {
		if metadata["id"] == value {
			return true
		}
	}
	channel := strings.ToLower(metadata["channel"])
	title := strings.ToLower(metadata["title"])
	for _, value := range channels {
		if channel == strings.ToLower(value) {
			return true
		}
	}
	for _, value := range words {
		if strings.Contains(title, strings.ToLower(value)) {
			return true
		}
	}
	return false
}

func testMetadataFixtures(root string) error {
	contents, err := os.ReadFile(filepath.Join(root, "tests", "metadata-fixtures.json"))
	if err != nil {
		return err
	}
	var fixtures []metadataFixture
	if err := json.Unmarshal(contents, &fixtures); err != nil {
		return err
	}
	failures := []string{}
	for _, fixture := range fixtures {
		actual := extractMetadata(fixture)
		if !reflect.DeepEqual(actual, fixture.Expected) {
			failures = append(failures, fmt.Sprintf("%s: expected %#v, got %#v", fixture.Name, fixture.Expected, actual))
		}
		if rendererKind(fixture.RendererClass) == "" && !fixture.ExpectedVisible {
			failures = append(failures, fixture.Name+": unknown renderer must remain visible")
		}
	}
	known := []metadataFixture{}
	for _, fixture := range fixtures {
		if fixture.Expected != nil {
			known = append(known, fixture)
		}
	}
	if len(known) < 4 {
		failures = append(failures, "snapshot contract needs at least four known renderer fixtures")
	} else {
		blockedIDs := []string{known[0].Expected["id"]}
		blockedChannels := []string{known[1].Expected["channel"]}
		blockedWords := []string{"elements"}
		visible := []int{}
		for index, fixture := range fixtures {
			if !metadataBlocked(extractMetadata(fixture), blockedIDs, blockedChannels, blockedWords) {
				visible = append(visible, index)
			}
		}
		expected := []int{}
		for index := range fixtures {
			if index != 0 && index != 1 && index != 3 {
				expected = append(expected, index)
			}
		}
		if !reflect.DeepEqual(visible, expected) {
			failures = append(failures, fmt.Sprintf("snapshot mapping expected %#v, got %#v", expected, visible))
		}
	}
	if len(failures) > 0 {
		return errors.New(strings.Join(failures, "\n"))
	}
	fmt.Printf("metadata fixture checks passed (%d fixtures)\n", len(fixtures))
	return nil
}

func plistJSON(path string) (map[string]any, error) {
	contents, err := exec.Command("/usr/bin/plutil", "-convert", "json", "-o", "-", path).Output()
	if err != nil {
		return nil, err
	}
	values := map[string]any{}
	if err := json.Unmarshal(contents, &values); err != nil {
		return nil, err
	}
	return values, nil
}

func writePlistJSON(path string, values map[string]any) error {
	if err := ensureParent(path); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".gonerino-plist-*.json")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	encoder := json.NewEncoder(temporary)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(values); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return exec.Command("/usr/bin/plutil", "-convert", "binary1", "-o", path, temporaryPath).Run()
}

func mergeBlocklists(currentPath, backupPath, outputPath string) error {
	values, err := plistJSON(currentPath)
	if err != nil {
		return err
	}
	backupContents, err := os.ReadFile(backupPath)
	if err != nil {
		return err
	}
	backup := map[string]any{}
	if err := json.Unmarshal(backupContents, &backup); err != nil {
		return err
	}
	for _, key := range blockListKeys {
		value, ok := backup[key]
		if !ok {
			return fmt.Errorf("backup value for %s is missing", key)
		}
		if _, ok := value.([]any); !ok {
			return fmt.Errorf("backup value for %s is not an array", key)
		}
		values[key] = value
	}
	return writePlistJSON(outputPath, values)
}

func testBlocklistRestore(_ string) error {
	temporary, err := os.MkdirTemp("", "gonerino-blocklist-test-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temporary)
	current := filepath.Join(temporary, "current.plist")
	backup := filepath.Join(temporary, "block-lists.json")
	restored := filepath.Join(temporary, "restored.plist")
	currentValues := map[string]any{
		"GonerinoBlockedChannels": []any{"old channel"},
		"GonerinoBlockedVideos":   []any{map[string]any{"id": "old"}},
		"GonerinoBlockedWords":    []any{"old word"},
		"UnrelatedYouTubeSetting": map[string]any{"enabled": true},
	}
	backupValues := map[string]any{
		"GonerinoBlockedChannels": []any{"new channel"},
		"GonerinoBlockedVideos":   []any{map[string]any{"id": "new"}},
		"GonerinoBlockedWords":    []any{"new word"},
	}
	if err := writePlistJSON(current, currentValues); err != nil {
		return err
	}
	contents, err := json.MarshalIndent(backupValues, "", "  ")
	if err != nil {
		return err
	}
	if err := writeText(backup, string(contents)+"\n"); err != nil {
		return err
	}
	if err := mergeBlocklists(current, backup, restored); err != nil {
		return err
	}
	values, err := plistJSON(restored)
	if err != nil {
		return err
	}
	for _, key := range blockListKeys {
		if !reflect.DeepEqual(values[key], backupValues[key]) {
			return fmt.Errorf("%s was not restored", key)
		}
	}
	if !reflect.DeepEqual(values["UnrelatedYouTubeSetting"], currentValues["UnrelatedYouTubeSetting"]) {
		return errors.New("an unrelated YouTube preference changed")
	}
	fmt.Println("block-list restore checks passed")
	return nil
}

func backupBlocklists(deviceID, outputDirectory string) (string, error) {
	if err := os.MkdirAll(outputDirectory, 0755); err != nil {
		return "", err
	}
	statusPath := filepath.Join(outputDirectory, "device-status.json")
	if err := cliToFile(statusPath, deviceID, "device_status"); err != nil {
		return "", err
	}
	if err := checkDeviceStatus(statusPath, pinnedDeviceID); err != nil {
		return "", err
	}
	preferencePathJSON := filepath.Join(outputDirectory, "preference-path.json")
	findCommand := "find /var/mobile/Containers/Data/Application -path '*/Library/Preferences/com.google.ios.youtube.plist' -type f -print 2>/dev/null | head -1"
	if err := cliToFile(preferencePathJSON, deviceID, "shell_exec", "--command", findCommand); err != nil {
		return "", err
	}
	preferencePath := firstNonEmptyLine(commandOutput(preferencePathJSON))
	if !strings.HasPrefix(preferencePath, "/var/mobile/Containers/Data/Application/") || !strings.HasSuffix(preferencePath, "/Library/Preferences/com.google.ios.youtube.plist") {
		return "", errors.New("could not locate YouTube's app-container preferences")
	}
	remoteCopy := "/tmp/gonerino-" + runID() + "-youtube.plist"
	defer func() {
		_, _ = cliOutput(deviceID, "shell_exec", "--command", "rm -f '"+remoteCopy+"'")
	}()
	if err := cliToFile(filepath.Join(outputDirectory, "copy.json"), deviceID, "shell_exec", "--command", "cp '"+preferencePath+"' '"+remoteCopy+"'"); err != nil {
		return "", err
	}
	if err := cliToFile(filepath.Join(outputDirectory, "download.json"), deviceID, "file_transfer", "--direction", "download", "--source", remoteCopy, "--destination", filepath.Join(outputDirectory, "youtube-preferences.plist")); err != nil {
		return "", err
	}
	values, err := plistJSON(filepath.Join(outputDirectory, "youtube-preferences.plist"))
	if err != nil {
		return "", err
	}
	backup := map[string]any{}
	for _, key := range blockListKeys {
		value, ok := values[key]
		if !ok {
			value = []any{}
		}
		if _, ok := value.([]any); !ok {
			return "", fmt.Errorf("preference value for %s is not an array", key)
		}
		backup[key] = value
	}
	contents, err := json.MarshalIndent(backup, "", "  ")
	if err != nil {
		return "", err
	}
	if err := writeText(filepath.Join(outputDirectory, "block-lists.json"), string(contents)+"\n"); err != nil {
		return "", err
	}
	manifest := fmt.Sprintf("device=%s\npreference_path=%s\nbackup_dir=%s\n", deviceID, preferencePath, outputDirectory)
	if err := writeText(filepath.Join(outputDirectory, "manifest.txt"), manifest); err != nil {
		return "", err
	}
	return outputDirectory, nil
}

func restoreBlocklists(deviceID, backupDirectory, outputDirectory string) (string, error) {
	backupPath := filepath.Join(backupDirectory, "block-lists.json")
	if _, err := os.Stat(backupPath); err != nil {
		return "", errors.New("block-list backup is missing")
	}
	if err := os.MkdirAll(outputDirectory, 0755); err != nil {
		return "", err
	}
	statusPath := filepath.Join(outputDirectory, "device-status.json")
	if err := cliToFile(statusPath, deviceID, "device_status"); err != nil {
		return "", err
	}
	if err := checkDeviceStatus(statusPath, pinnedDeviceID); err != nil {
		return "", err
	}
	preferencePathJSON := filepath.Join(outputDirectory, "preference-path.json")
	findCommand := "find /var/mobile/Containers/Data/Application -path '*/Library/Preferences/com.google.ios.youtube.plist' -type f -print 2>/dev/null | head -1"
	if err := cliToFile(preferencePathJSON, deviceID, "shell_exec", "--command", findCommand); err != nil {
		return "", err
	}
	preferencePath := firstNonEmptyLine(commandOutput(preferencePathJSON))
	if !strings.HasPrefix(preferencePath, "/var/mobile/Containers/Data/Application/") || !strings.HasSuffix(preferencePath, "/Library/Preferences/com.google.ios.youtube.plist") {
		return "", errors.New("could not locate YouTube's app-container preferences")
	}
	remoteCurrent := "/tmp/gonerino-" + runID() + "-youtube-current.plist"
	remoteRestore := "/tmp/gonerino-" + runID() + "-youtube-restore.plist"
	defer func() {
		_, _ = cliOutput(deviceID, "shell_exec", "--command", "rm -f '"+remoteCurrent+"' '"+remoteRestore+"'")
	}()
	copyCommand := "killall -9 YouTube >/dev/null 2>&1 || true; cp '" + preferencePath + "' '" + remoteCurrent + "'"
	if err := cliToFile(filepath.Join(outputDirectory, "copy.json"), deviceID, "shell_exec", "--command", copyCommand); err != nil {
		return "", err
	}
	currentPath := filepath.Join(outputDirectory, "youtube-preferences-current.plist")
	if err := cliToFile(filepath.Join(outputDirectory, "download.json"), deviceID, "file_transfer", "--direction", "download", "--source", remoteCurrent, "--destination", currentPath); err != nil {
		return "", err
	}
	restoredPath := filepath.Join(outputDirectory, "youtube-preferences-restored.plist")
	if err := mergeBlocklists(currentPath, backupPath, restoredPath); err != nil {
		return "", err
	}
	if err := cliToFile(filepath.Join(outputDirectory, "upload.json"), deviceID, "file_transfer", "--direction", "upload", "--source", restoredPath, "--destination", remoteRestore); err != nil {
		return "", err
	}
	installCommand := "chown mobile:mobile '" + remoteRestore + "' && chmod 600 '" + remoteRestore + "' && mv '" + remoteRestore + "' '" + preferencePath + "' && killall -9 cfprefsd >/dev/null 2>&1 || true"
	if err := cliToFile(filepath.Join(outputDirectory, "install.json"), deviceID, "shell_exec", "--command", installCommand); err != nil {
		return "", err
	}
	manifest := fmt.Sprintf("device=%s\npreference_path=%s\nbackup_dir=%s\nrestore_dir=%s\n", deviceID, preferencePath, backupDirectory, outputDirectory)
	if err := writeText(filepath.Join(outputDirectory, "manifest.txt"), manifest); err != nil {
		return "", err
	}
	return outputDirectory, nil
}

type metricSamples struct {
	cpu         []float64
	rss         []float64
	physicalMem []float64
	footprint   []float64
	cpuTime     []float64
}

func resourceValue(value string, memory bool) (float64, bool) {
	match := regexp.MustCompile(`^(-?[0-9]+(?:\.[0-9]+)?)([KMGTP]?)$`).FindStringSubmatch(value)
	if match == nil {
		return 0, false
	}
	number, err := strconv.ParseFloat(match[1], 64)
	if err != nil || math.IsNaN(number) || math.IsInf(number, 0) {
		return 0, false
	}
	multipliers := map[string]float64{
		"":  1,
		"K": 0.001,
		"M": 1,
		"G": 1000,
		"T": 1000000,
	}
	if memory {
		multipliers = map[string]float64{
			"":  1.0 / 1024.0,
			"K": 1,
			"M": 1024,
			"G": 1024 * 1024,
			"T": 1024 * 1024 * 1024,
		}
	}
	factor, ok := multipliers[match[2]]
	if !ok {
		return 0, false
	}
	return number * factor, true
}

func metricSample(path string) metricSamples {
	result := metricSamples{}
	for _, line := range strings.Split(commandOutput(path), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		if _, err := strconv.Atoi(fields[0]); err != nil {
			continue
		}
		cpu, cpuErr := strconv.ParseFloat(fields[1], 64)
		rss, rssErr := strconv.ParseFloat(fields[2], 64)
		if cpuErr == nil && rssErr == nil && !math.IsNaN(cpu) && !math.IsNaN(rss) && !math.IsInf(cpu, 0) && !math.IsInf(rss, 0) {
			result.cpu = append(result.cpu, cpu)
			result.rss = append(result.rss, rss)
		}
		if len(fields) < 6 {
			continue
		}
		resource := fields[2]
		value := fields[5]
		if resource == "phys_mem" {
			if parsed, ok := resourceValue(value, true); ok {
				result.physicalMem = append(result.physicalMem, parsed)
			}
		} else if resource == "phys_footprint" {
			if parsed, ok := resourceValue(value, true); ok {
				result.footprint = append(result.footprint, parsed)
			}
		} else if resource == "cpu_time" {
			if parsed, ok := resourceValue(value, false); ok {
				result.cpuTime = append(result.cpuTime, parsed)
			}
		}
	}
	return result
}

func appendFloats(destination *[]float64, source []float64) {
	*destination = append(*destination, source...)
}

func metricsForRun(runDirectory string) metricSamples {
	result := metricSamples{}
	paths := []string{}
	for _, name := range []string{"metrics-before.json"} {
		path := filepath.Join(runDirectory, name)
		if _, err := os.Stat(path); err == nil {
			paths = append(paths, path)
		}
	}
	periodic, _ := filepath.Glob(filepath.Join(runDirectory, "metrics-sample-*.json"))
	sort.Strings(periodic)
	paths = append(paths, periodic...)
	for _, name := range []string{"metrics-after.json"} {
		path := filepath.Join(runDirectory, name)
		if _, err := os.Stat(path); err == nil {
			paths = append(paths, path)
		}
	}
	for _, path := range paths {
		sample := metricSample(path)
		appendFloats(&result.cpu, sample.cpu)
		appendFloats(&result.rss, sample.rss)
		if len(sample.footprint) > 0 {
			appendFloats(&result.footprint, sample.footprint)
		} else {
			appendFloats(&result.physicalMem, sample.physicalMem)
		}
		appendFloats(&result.cpuTime, sample.cpuTime)
	}
	return result
}

func median(values []float64) *float64 {
	if len(values) == 0 {
		return nil
	}
	copyValues := append([]float64(nil), values...)
	sort.Float64s(copyValues)
	index := len(copyValues) / 2
	value := copyValues[index]
	if len(copyValues)%2 == 0 {
		value = (copyValues[index-1] + copyValues[index]) / 2
	}
	return &value
}

func maximum(values []float64) *float64 {
	if len(values) == 0 {
		return nil
	}
	value := values[0]
	for _, candidate := range values[1:] {
		if candidate > value {
			value = candidate
		}
	}
	return &value
}

func runValues(runDirectory string) map[string]string {
	result := map[string]string{}
	contents, err := os.ReadFile(filepath.Join(runDirectory, "run.txt"))
	if err != nil {
		return result
	}
	for _, line := range strings.Split(string(contents), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if ok {
			result[key] = value
		}
	}
	return result
}

func touchMetrics(runDirectory string) (delays []float64, stalls, hangs int) {
	contents, err := os.ReadFile(filepath.Join(runDirectory, "touch-latency.tsv"))
	if err != nil {
		return
	}
	lines := strings.Split(string(contents), "\n")
	for _, line := range lines[1:] {
		fields := strings.Split(line, "\t")
		if len(fields) < 10 {
			continue
		}
		delay, delayErr := strconv.ParseFloat(fields[6], 64)
		stall, stallErr := strconv.Atoi(fields[7])
		hang, hangErr := strconv.Atoi(fields[8])
		if delayErr == nil && stallErr == nil && hangErr == nil {
			delays = append(delays, delay)
			stalls += stall
			hangs += hang
		}
	}
	return
}

func frameMetrics(runDirectory string) (durations []float64, failures int) {
	contents, err := os.ReadFile(filepath.Join(runDirectory, "frame-responsiveness.tsv"))
	if err != nil {
		return
	}
	lines := strings.Split(string(contents), "\n")
	for _, line := range lines[1:] {
		fields := strings.Split(line, "\t")
		if len(fields) < 6 {
			if strings.TrimSpace(line) != "" {
				failures++
			}
			continue
		}
		duration, durationErr := strconv.ParseFloat(fields[3], 64)
		screenStatus, screenErr := strconv.Atoi(fields[4])
		snapshotStatus, snapshotErr := strconv.Atoi(fields[5])
		if durationErr != nil || screenErr != nil || snapshotErr != nil {
			failures++
			continue
		}
		durations = append(durations, duration)
		if screenStatus != 0 || snapshotStatus != 0 {
			failures++
		}
	}
	return
}

func crashLines(runDirectory, suffix string) []string {
	contents, err := os.ReadFile(filepath.Join(runDirectory, "crashes-"+suffix+".json"))
	if err != nil {
		return nil
	}
	lines := []string{}
	for _, line := range strings.Split(commandOutputBytes(contents), "\n") {
		if strings.TrimSpace(line) != "" {
			lines = append(lines, line)
		}
	}
	return lines
}

func missingArtifacts(runDirectory string) []string {
	names := []string{
		"run.txt",
		"metrics-before.json",
		"metrics-after.json",
		"touch-latency.tsv",
		"frame-responsiveness.tsv",
		"crashes-before.json",
		"crashes-after.json",
	}
	missing := []string{}
	for _, name := range names {
		if _, err := os.Stat(filepath.Join(runDirectory, name)); err != nil {
			missing = append(missing, name)
		}
	}
	return missing
}

type performanceSummary struct {
	Run                    string   `json:"run"`
	Mode                   string   `json:"mode"`
	Profile                string   `json:"profile"`
	CPUSamples             int      `json:"cpu_samples"`
	CPUMeasurementSource   *string  `json:"cpu_measurement_source"`
	PeriodicMetricSamples  int      `json:"periodic_metric_samples"`
	CPUMedianPercent       *float64 `json:"cpu_median_percent"`
	CPUTimeSamples         int      `json:"cpu_time_samples"`
	CPUTimeDeltaUnits      *float64 `json:"cpu_time_delta_units"`
	CPUTimeRatePercent     *float64 `json:"cpu_time_rate_percent"`
	RSSSamples             int      `json:"rss_samples"`
	RSSMedianKB            *float64 `json:"rss_median_kb"`
	MemorySamples          int      `json:"memory_samples"`
	MemoryMedianKB         *float64 `json:"memory_median_kb"`
	MemoryGrowthRatio      *float64 `json:"memory_growth_ratio"`
	TouchSamples           int      `json:"touch_samples"`
	TouchMedianDelayMS     *float64 `json:"touch_median_delay_ms"`
	TouchMaxDelayMS        *float64 `json:"touch_max_delay_ms"`
	StallsOver50MS         int      `json:"stalls_over_50ms"`
	Hangs                  int      `json:"hangs"`
	FrameSamples           int      `json:"frame_samples"`
	FrameFailures          int      `json:"frame_failures"`
	FrameMaxCommandMS      *float64 `json:"frame_max_command_ms"`
	CrashesBefore          int      `json:"crashes_before"`
	CrashesAfter           int      `json:"crashes_after"`
	NewCrashLines          int      `json:"new_crash_lines"`
	MissingArtifacts       []string `json:"missing_artifacts"`
	MatchedCPUDeltaPercent *float64 `json:"matched_cpu_delta_percent,omitempty"`
	MatchedTouchDeltaMS    *float64 `json:"matched_touch_delta_ms,omitempty"`
}

func summarizePerformance(runDirectory string) performanceSummary {
	values := runValues(runDirectory)
	metrics := metricsForRun(runDirectory)
	delays, stalls, hangs := touchMetrics(runDirectory)
	frames, frameFailures := frameMetrics(runDirectory)
	beforeCrashes := crashLines(runDirectory, "before")
	afterCrashes := crashLines(runDirectory, "after")
	duration, _ := strconv.ParseFloat(values["duration_ms"], 64)
	var cpuTimeDelta, cpuTimeRate *float64
	if len(metrics.cpuTime) >= 2 {
		delta := metrics.cpuTime[len(metrics.cpuTime)-1] - metrics.cpuTime[0]
		cpuTimeDelta = &delta
		if duration > 0 {
			rate := delta / duration * 100
			cpuTimeRate = &rate
		}
	}
	cpus := median(metrics.cpu)
	source := ""
	if len(metrics.cpu) > 0 {
		source = "ps"
	} else if cpuTimeRate != nil {
		cpus = cpuTimeRate
		source = "ltop_cpu_time"
	}
	var sourcePtr *string
	if source != "" {
		sourcePtr = &source
	}
	memory := metrics.footprint
	if len(memory) == 0 {
		memory = metrics.physicalMem
	}
	var growth *float64
	if len(memory) >= 2 && memory[0] > 0 {
		value := (memory[len(memory)-1] - memory[0]) / memory[0]
		growth = &value
	}
	periodic, _ := filepath.Glob(filepath.Join(runDirectory, "metrics-sample-*.json"))
	result := performanceSummary{
		Run:                   runDirectory,
		Mode:                  values["mode"],
		Profile:               values["profile"],
		CPUSamples:            len(metrics.cpu),
		CPUMeasurementSource:  sourcePtr,
		PeriodicMetricSamples: len(periodic),
		CPUMedianPercent:      cpus,
		CPUTimeSamples:        len(metrics.cpuTime),
		CPUTimeDeltaUnits:     cpuTimeDelta,
		CPUTimeRatePercent:    cpuTimeRate,
		RSSSamples:            len(metrics.rss),
		RSSMedianKB:           median(metrics.rss),
		MemorySamples:         len(memory),
		MemoryMedianKB:        median(memory),
		MemoryGrowthRatio:     growth,
		TouchSamples:          len(delays),
		TouchMedianDelayMS:    median(delays),
		TouchMaxDelayMS:       maximum(delays),
		StallsOver50MS:        stalls,
		Hangs:                 hangs,
		FrameSamples:          len(frames),
		FrameFailures:         frameFailures,
		FrameMaxCommandMS:     maximum(frames),
		CrashesBefore:         len(beforeCrashes),
		CrashesAfter:          len(afterCrashes),
		NewCrashLines:         uniqueDifference(afterCrashes, beforeCrashes),
		MissingArtifacts:      missingArtifacts(runDirectory),
	}
	return result
}

func uniqueDifference(values, excluded []string) int {
	seen := map[string]bool{}
	for _, value := range excluded {
		seen[value] = true
	}
	newValues := map[string]bool{}
	for _, value := range values {
		if !seen[value] {
			newValues[value] = true
		}
	}
	return len(newValues)
}

type performanceRunDescriptor struct {
	Profile string
	Mode    string
	Path    string
}

func loadPerformanceRuns(suiteDirectory string) []performanceRunDescriptor {
	contents, err := os.ReadFile(filepath.Join(suiteDirectory, "runs.tsv"))
	if err != nil {
		return nil
	}
	runs := []performanceRunDescriptor{}
	for _, line := range strings.Split(string(contents), "\n")[1:] {
		fields := strings.Split(line, "\t")
		if len(fields) != 3 {
			continue
		}
		path := fields[2]
		if !filepath.IsAbs(path) {
			path = filepath.Join(suiteDirectory, path)
		}
		if info, err := os.Stat(path); err == nil && info.IsDir() {
			runs = append(runs, performanceRunDescriptor{Profile: fields[0], Mode: fields[1], Path: path})
		}
	}
	return runs
}

func suiteValues(suiteDirectory string) map[string]string {
	contents, err := os.ReadFile(filepath.Join(suiteDirectory, "suite.txt"))
	if err != nil {
		return map[string]string{}
	}
	values := map[string]string{}
	for _, line := range strings.Split(string(contents), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if ok {
			values[key] = value
		}
	}
	return values
}

type performanceReport struct {
	Suite    string                `json:"suite"`
	Runs     []*performanceSummary `json:"runs"`
	Failures []string              `json:"failures"`
	Passed   bool                  `json:"passed"`
}

func performanceAnalysis(suiteDirectory string) ([]byte, bool, error) {
	descriptors := loadPerformanceRuns(suiteDirectory)
	if len(descriptors) == 0 {
		return nil, false, errors.New("performance suite has no completed runs")
	}
	runs := []*performanceSummary{}
	failures := []string{}
	grouped := map[string]map[string]*performanceSummary{}
	values := suiteValues(suiteDirectory)
	profiles := strings.Fields(values["profiles"])
	if len(profiles) == 0 {
		profiles = strings.Fields("home subscriptions search long-form shorts")
	}
	for _, descriptor := range descriptors {
		summary := summarizePerformance(descriptor.Path)
		summary.Profile = descriptor.Profile
		summary.Mode = descriptor.Mode
		runs = append(runs, &summary)
		if grouped[descriptor.Profile] == nil {
			grouped[descriptor.Profile] = map[string]*performanceSummary{}
		}
		grouped[descriptor.Profile][descriptor.Mode] = &summary
		if len(summary.MissingArtifacts) > 0 {
			failures = append(failures, fmt.Sprintf("%s/%s: missing artifacts %v", descriptor.Mode, descriptor.Profile, summary.MissingArtifacts))
		}
		if summary.CPUMedianPercent == nil || summary.MemorySamples == 0 {
			failures = append(failures, fmt.Sprintf("%s/%s: missing process CPU or memory samples", descriptor.Mode, descriptor.Profile))
		}
		if summary.PeriodicMetricSamples < 2 {
			failures = append(failures, fmt.Sprintf("%s/%s: fewer than two periodic process samples", descriptor.Mode, descriptor.Profile))
		}
		if summary.TouchSamples == 0 {
			failures = append(failures, fmt.Sprintf("%s/%s: missing touch-latency samples", descriptor.Mode, descriptor.Profile))
		}
		if summary.FrameSamples < 2 {
			failures = append(failures, fmt.Sprintf("%s/%s: missing frame-responsiveness samples", descriptor.Mode, descriptor.Profile))
		}
		if summary.FrameFailures > 0 || summary.StallsOver50MS > 0 || summary.Hangs > 0 || summary.NewCrashLines > 0 {
			failures = append(failures, fmt.Sprintf("%s/%s: touch stall, hang, or new crash", descriptor.Mode, descriptor.Profile))
		}
		if summary.FrameMaxCommandMS != nil && *summary.FrameMaxCommandMS > 5000 {
			failures = append(failures, fmt.Sprintf("%s/%s: frame capture command exceeded 5000 ms", descriptor.Mode, descriptor.Profile))
		}
		if summary.MemoryGrowthRatio != nil && *summary.MemoryGrowthRatio > 0.20 {
			failures = append(failures, fmt.Sprintf("%s/%s: process memory grew more than 20 percent", descriptor.Mode, descriptor.Profile))
		}
	}
	for _, profile := range profiles {
		modes := grouped[profile]
		enabled := modes["enabled"]
		disabled := modes["disabled"]
		if enabled == nil || disabled == nil {
			failures = append(failures, profile+": missing matched enabled/disabled run")
			continue
		}
		if enabled.CPUMedianPercent == nil || disabled.CPUMedianPercent == nil {
			failures = append(failures, profile+": missing CPU samples")
			continue
		}
		cpuDelta := *enabled.CPUMedianPercent - *disabled.CPUMedianPercent
		enabled.MatchedCPUDeltaPercent = &cpuDelta
		if math.Abs(cpuDelta) > 2 {
			failures = append(failures, profile+": matched median CPU delta exceeded 2 percentage points")
		}
		if enabled.TouchMedianDelayMS == nil || disabled.TouchMedianDelayMS == nil {
			failures = append(failures, profile+": missing matched touch samples")
			continue
		}
		touchDelta := *enabled.TouchMedianDelayMS - *disabled.TouchMedianDelayMS
		enabled.MatchedTouchDeltaMS = &touchDelta
		if math.Abs(touchDelta) > 50 {
			failures = append(failures, profile+": matched touch latency delta exceeded 50 ms")
		}
	}
	report := performanceReport{Suite: suiteDirectory, Runs: runs, Failures: failures, Passed: len(failures) == 0}
	contents, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		return nil, false, err
	}
	return append(contents, '\n'), report.Passed, nil
}

func analyzePerformanceCommand(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: analyze-performance SUITE_DIRECTORY")
	}
	contents, passed, err := performanceAnalysis(args[0])
	if err != nil {
		return err
	}
	if _, err := os.Stdout.Write(contents); err != nil {
		return err
	}
	if !passed {
		return errors.New("performance suite did not pass")
	}
	return nil
}

func generateScreenshotStrip(root string) error {
	type screenshot struct {
		filename string
		label    string
	}
	screenshots := []screenshot{
		{filename: "settings.png", label: "Custom settings"},
		{filename: "long-form-menu.png", label: "Long-form controls"},
		{filename: "shorts-menu.png", label: "Shorts controls"},
	}
	const canvasWidth = 1500
	const canvasHeight = 930
	const bodyWidth = 410
	const bodyHeight = 850
	const bodyY = 20
	const screenXOffset = 22
	const screenYOffset = 75
	const screenWidth = 366
	const screenHeight = 651
	positions := []int{25, 545, 1065}
	definitions := []string{
		`<linearGradient id="body" x1="0" y1="0" x2="1" y2="1">`,
		`<stop offset="0" stop-color="#555b65"/>`,
		`<stop offset="0.1" stop-color="#242932"/>`,
		`<stop offset="0.5" stop-color="#0d0f13"/>`,
		`<stop offset="0.9" stop-color="#252a32"/>`,
		`<stop offset="1" stop-color="#626873"/>`,
		`</linearGradient>`,
		`<filter id="shadow" x="-25%" y="-15%" width="150%" height="145%">`,
		`<feDropShadow dx="0" dy="14" stdDeviation="12" flood-color="#000000" flood-opacity="0.28"/>`,
		`</filter>`,
	}
	for index, _ := range screenshots {
		x := positions[index]
		screenX := x + screenXOffset
		screenY := bodyY + screenYOffset
		definitions = append(definitions, fmt.Sprintf(`<clipPath id="screen-%d"><rect x="%d" y="%d" width="%d" height="%d" rx="18"/></clipPath>`, index, screenX, screenY, screenWidth, screenHeight))
	}
	parts := []string{
		fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" role="img" aria-labelledby="title description">`, canvasWidth, canvasHeight, canvasWidth, canvasHeight),
		`<title id="title">Gonerino screenshots</title>`,
		`<desc id="description">Gonerino custom settings, long-form blocking actions, and Shorts blocking actions shown in second-generation iPhone SE frames.</desc>`,
		"<defs>",
	}
	parts = append(parts, definitions...)
	parts = append(parts, "</defs>")
	for index, item := range screenshots {
		encoded, err := os.ReadFile(filepath.Join(root, "assets", item.filename))
		if err != nil {
			return err
		}
		x := positions[index]
		screenX := x + screenXOffset
		screenY := bodyY + screenYOffset
		bodyRight := x + bodyWidth
		leftButtonX := x - 7
		parts = append(parts,
			`<g filter="url(#shadow)">`,
			fmt.Sprintf(`<rect x="%d" y="%d" width="%d" height="%d" rx="52" fill="url(#body)" stroke="#747a84" stroke-width="2"/>`, x, bodyY, bodyWidth, bodyHeight),
			fmt.Sprintf(`<rect x="%d" y="%d" width="%d" height="%d" rx="46" fill="none" stroke="#050608" stroke-opacity="0.75" stroke-width="3"/>`, x+7, bodyY+7, bodyWidth-14, bodyHeight-14),
			fmt.Sprintf(`<rect x="%d" y="%d" width="%d" height="%d" rx="20" fill="#050608" stroke="#6b7079" stroke-opacity="0.35" stroke-width="2"/>`, screenX-2, screenY-2, screenWidth+4, screenHeight+4),
			fmt.Sprintf(`<image x="%d" y="%d" width="%d" height="%d" preserveAspectRatio="none" clip-path="url(#screen-%d)" href="data:image/png;base64,%s"/>`, screenX, screenY, screenWidth, screenHeight, index, base64.StdEncoding.EncodeToString(encoded)),
			fmt.Sprintf(`<rect x="%d" y="%d" width="%d" height="%d" rx="18" fill="none" stroke="#000000" stroke-opacity="0.55" stroke-width="2"/>`, screenX, screenY, screenWidth, screenHeight),
			fmt.Sprintf(`<rect x="%d" y="%d" width="86" height="8" rx="4" fill="#08090b"/>`, x+162, bodyY+35),
			fmt.Sprintf(`<circle cx="%d" cy="%d" r="5" fill="#08090b" stroke="#696f78" stroke-opacity="0.4"/>`, x+273, bodyY+39),
			fmt.Sprintf(`<circle cx="%d" cy="%d" r="2" fill="#30343b"/>`, x+291, bodyY+39),
			fmt.Sprintf(`<rect x="%d" y="%d" width="7" height="32" rx="3.5" fill="#20242a" stroke="#626872" stroke-width="1"/>`, leftButtonX, bodyY+150),
			fmt.Sprintf(`<rect x="%d" y="%d" width="7" height="66" rx="3.5" fill="#20242a" stroke="#626872" stroke-width="1"/>`, leftButtonX, bodyY+205),
			fmt.Sprintf(`<rect x="%d" y="%d" width="7" height="66" rx="3.5" fill="#20242a" stroke="#626872" stroke-width="1"/>`, leftButtonX, bodyY+286),
			fmt.Sprintf(`<rect x="%d" y="%d" width="7" height="96" rx="3.5" fill="#20242a" stroke="#626872" stroke-width="1"/>`, bodyRight, bodyY+214),
			fmt.Sprintf(`<circle cx="%d" cy="%d" r="34" fill="#090b0e" stroke="#666c76" stroke-width="2"/>`, x+bodyWidth/2, bodyY+774),
			fmt.Sprintf(`<circle cx="%d" cy="%d" r="27" fill="none" stroke="#20242a" stroke-width="2"/>`, x+bodyWidth/2, bodyY+774),
			`</g>`,
			fmt.Sprintf(`<text x="%d" y="%d" text-anchor="middle" fill="#3f4753" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="20" font-weight="600">%s</text>`, x+bodyWidth/2, bodyY+bodyHeight+40, html.EscapeString(item.label)),
		)
	}
	parts = append(parts, "</svg>")
	return writeText(filepath.Join(root, "assets", "screenshots.svg"), strings.Join(parts, "\n")+"\n")
}

func statusCode(err error) int {
	if err == nil {
		return 0
	}
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		return exitError.ExitCode()
	}
	return 1
}

func setPlistBool(path, key string, value bool) error {
	valueText := strconv.FormatBool(value)
	command := exec.Command("/usr/bin/plutil", "-replace", key, "-bool", valueText, path)
	if err := command.Run(); err == nil {
		return nil
	}
	return exec.Command("/usr/bin/plutil", "-insert", key, "-bool", valueText, path).Run()
}

func plistRaw(path, key string) (string, error) {
	output, err := exec.Command("/usr/bin/plutil", "-extract", key, "raw", "-o", "-", path).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}

func preferencePathFromJSON(path string) string {
	return firstNonEmptyLine(commandOutput(path))
}

func runPerformance(args []string) (string, error) {
	if len(args) < 3 || len(args) > 5 {
		return "", errors.New("usage: performance DEVICE enabled|disabled home|subscriptions|search|long-form|shorts [duration_ms] [output_dir]")
	}
	deviceID := args[0]
	mode := args[1]
	profile := args[2]
	if mode != "enabled" && mode != "disabled" {
		return "", errors.New("mode must be enabled or disabled")
	}
	validProfiles := map[string]bool{"home": true, "subscriptions": true, "search": true, "long-form": true, "shorts": true}
	if !validProfiles[profile] {
		return "", errors.New("profile must be home, subscriptions, search, long-form, or shorts")
	}
	durationMS := int64(60000)
	if value := os.Getenv("GONERINO_PERFORMANCE_DURATION_MS"); value != "" {
		parsed, err := strconv.ParseInt(value, 10, 64)
		if err != nil {
			return "", err
		}
		durationMS = parsed
	}
	if len(args) >= 4 && args[3] != "" {
		parsed, err := strconv.ParseInt(args[3], 10, 64)
		if err != nil {
			return "", err
		}
		durationMS = parsed
	}
	outputRoot := os.Getenv("GONERINO_PERFORMANCE_OUTPUT")
	if outputRoot == "" {
		outputRoot = "/tmp/gonerino-performance"
	}
	if len(args) == 5 && args[4] != "" {
		outputRoot = args[4]
	}
	if _, err := os.Stat("/usr/bin/plutil"); err != nil {
		return "", errors.New("macOS plutil is required for preference control")
	}
	runDirectory := filepath.Join(outputRoot, mode+"-"+profile+"-"+runID())
	if err := os.MkdirAll(runDirectory, 0755); err != nil {
		return "", err
	}
	preferencePath := ""
	preferenceOriginalFile := ""
	preferenceDeviceTemp := ""
	finished := false
	restorePreferences := func() {
		if preferencePath == "" || preferenceOriginalFile == "" {
			return
		}
		_ = cliToFile(filepath.Join(runDirectory, "preference-restore-force-quit.json"), deviceID, "shell_exec", "--command", "killall -9 YouTube >/dev/null 2>&1 || true")
		if err := cliToFile(filepath.Join(runDirectory, "preference-restore-upload.json"), deviceID, "file_transfer", "--direction", "upload", "--source", preferenceOriginalFile, "--destination", preferenceDeviceTemp); err == nil {
			_ = cliToFile(filepath.Join(runDirectory, "preference-restore-ownership.json"), deviceID, "shell_exec", "--command", "chown mobile:mobile '"+preferenceDeviceTemp+"' && chmod 600 '"+preferenceDeviceTemp+"' && mv '"+preferenceDeviceTemp+"' '"+preferencePath+"' && killall -9 cfprefsd >/dev/null 2>&1 || true")
		}
	}
	finish := func() {
		if finished {
			return
		}
		finished = true
		restorePreferences()
		_ = cliToFile(filepath.Join(runDirectory, "screen-off.json"), deviceID, "ui_action", "--action", "screen_off")
	}
	defer finish()
	if err := cliToFileWithoutDevice(filepath.Join(runDirectory, "device-list.json"), "device_list"); err != nil {
		return "", err
	}
	statusPath := filepath.Join(runDirectory, "device-status.json")
	if err := cliToFile(statusPath, deviceID, "device_status"); err != nil {
		return "", err
	}
	if err := checkDeviceStatus(statusPath, deviceID); err != nil {
		return "", err
	}
	preferenceValue := mode == "enabled"
	if err := cliToFile(filepath.Join(runDirectory, "screen-on.json"), deviceID, "ui_action", "--action", "screen_on"); err != nil {
		return "", err
	}
	if err := cliToFile(filepath.Join(runDirectory, "unlock.json"), deviceID, "ui_action", "--action", "button", "--button", "unlock"); err != nil {
		return "", err
	}
	if err := cliToFile(filepath.Join(runDirectory, "force-quit.json"), deviceID, "shell_exec", "--command", "killall -9 YouTube >/dev/null 2>&1 || true"); err != nil {
		return "", err
	}
	sleepMillis(2000)
	preferencePathJSON := filepath.Join(runDirectory, "preference-path.json")
	findCommand := "find /var/mobile/Containers/Data/Application -path '*/Library/Preferences/com.google.ios.youtube.plist' -type f -print 2>/dev/null | head -1"
	if err := cliToFile(preferencePathJSON, deviceID, "shell_exec", "--command", findCommand); err != nil {
		return "", err
	}
	preferencePath = preferencePathFromJSON(preferencePathJSON)
	if !strings.HasPrefix(preferencePath, "/var/mobile/Containers/Data/Application/") || !strings.HasSuffix(preferencePath, "/Library/Preferences/com.google.ios.youtube.plist") {
		return "", errors.New("could not locate YouTube's app-container preferences")
	}
	preferenceDeviceTemp = "/tmp/gonerino-" + runID() + "-youtube.plist"
	preferenceFile := filepath.Join(runDirectory, "youtube-preferences.plist")
	preferenceOriginalFile = filepath.Join(runDirectory, "youtube-preferences-original.plist")
	preferenceCopyJSON := filepath.Join(runDirectory, "preference-copy.json")
	if err := cliToFile(preferenceCopyJSON, deviceID, "shell_exec", "--command", "cp '"+preferencePath+"' '"+preferenceDeviceTemp+"'"); err != nil {
		return "", err
	}
	copyContents, err := os.ReadFile(preferenceCopyJSON)
	if err != nil {
		return "", err
	}
	if !strings.Contains(string(copyContents), "\"exitCode\":0") && !strings.Contains(string(copyContents), "\"exitCode\": 0") {
		return "", errors.New("could not stage YouTube's preferences")
	}
	if err := cliToFile(filepath.Join(runDirectory, "preference-download-original.json"), deviceID, "file_transfer", "--direction", "download", "--source", preferenceDeviceTemp, "--destination", preferenceOriginalFile); err != nil {
		return "", err
	}
	if err := cliToFile(filepath.Join(runDirectory, "preference-download.json"), deviceID, "file_transfer", "--direction", "download", "--source", preferenceDeviceTemp, "--destination", preferenceFile); err != nil {
		return "", err
	}
	if err := setPlistBool(preferenceFile, "GonerinoEnabled", preferenceValue); err != nil {
		return "", err
	}
	preferenceRead, err := plistRaw(preferenceFile, "GonerinoEnabled")
	if err != nil {
		return "", err
	}
	if err := writeText(filepath.Join(runDirectory, "preference-read.txt"), preferenceRead+"\n"); err != nil {
		return "", err
	}
	if err := cliToFile(filepath.Join(runDirectory, "preference-upload.json"), deviceID, "file_transfer", "--direction", "upload", "--source", preferenceFile, "--destination", preferenceDeviceTemp); err != nil {
		return "", err
	}
	if err := cliToFile(filepath.Join(runDirectory, "preference-ownership.json"), deviceID, "shell_exec", "--command", "chown mobile:mobile '"+preferenceDeviceTemp+"' && chmod 600 '"+preferenceDeviceTemp+"' && mv '"+preferenceDeviceTemp+"' '"+preferencePath+"' && killall -9 cfprefsd >/dev/null 2>&1 || true"); err != nil {
		return "", err
	}
	youtubeID := os.Getenv("YOUTUBE_BUNDLE_ID")
	if youtubeID == "" {
		youtubeID = youtubeBundleID
	}
	if err := cliToFile(filepath.Join(runDirectory, "launch.json"), deviceID, "app_manage", "--action", "launch", "--bundleId", youtubeID); err != nil {
		return "", err
	}
	sleepMillis(3000)
	if err := cliToFile(filepath.Join(runDirectory, "start-screen.json"), deviceID, "screen_capture"); err != nil {
		return "", err
	}
	if err := cliToFile(filepath.Join(runDirectory, "crashes-before.json"), deviceID, "crash_manage", "--action", "list", "--process", "YouTube"); err != nil {
		return "", err
	}
	if err := cliToFile(filepath.Join(runDirectory, "processes-before.json"), deviceID, "process_manage", "--action", "list"); err != nil {
		return "", err
	}
	profileAction := ""
	profileX, profileY := 0, 0
	searchQuery := ""
	switch profile {
	case "home":
		profileAction, profileX, profileY = "tap-home", 40, 635
	case "subscriptions":
		profileAction, profileX, profileY = "tap-subscriptions", 260, 635
	case "search":
		profileAction, profileX, profileY, searchQuery = "tap-search", 345, 48, "cats"
	case "long-form":
		profileAction, profileX, profileY, searchQuery = "tap-search", 345, 48, "documentary"
	case "shorts":
		profileAction, profileX, profileY = "tap-shorts", 112, 635
	}
	profileStart := nowMillis()
	if err := cliToFile(filepath.Join(runDirectory, "profile-navigation.json"), deviceID, "ui_action", "--action", "tap", "--x", strconv.Itoa(profileX), "--y", strconv.Itoa(profileY), "--deadlineMs", "10000"); err != nil {
		return "", err
	}
	profileEnd := nowMillis()
	if err := writeText(filepath.Join(runDirectory, "profile-navigation.txt"), fmt.Sprintf("start_ms=%d\nend_ms=%d\nelapsed_ms=%d\naction=%s\nquery=%s\n", profileStart, profileEnd, profileEnd-profileStart, profileAction, searchQuery)); err != nil {
		return "", err
	}
	sleepMillis(2000)
	if searchQuery != "" {
		searchTextPath := filepath.Join(runDirectory, "search-text.json")
		if err := cliToFile(searchTextPath, deviceID, "ui_action", "--action", "text", "--text", searchQuery, "--deadlineMs", "10000"); err != nil {
			_ = writeText(filepath.Join(runDirectory, "search-status.txt"), "search text injection failed; repair jb-p1lot text input before using search profiles\n")
			return "", err
		}
		if err := cliToFile(filepath.Join(runDirectory, "search-submit.json"), deviceID, "ui_action", "--action", "tap", "--x", "338", "--y", "620", "--deadlineMs", "10000"); err != nil {
			return "", err
		}
		sleepMillis(3000)
	}
	startX, startY, endX, endY := 188, 585, 188, 185
	scrollCount := 12
	if profile == "shorts" {
		startY, endY = 600, 90
	}
	if err := writeText(filepath.Join(runDirectory, "touch-latency.tsv"), "index\tstarted_ms\tended_ms\tcommand_ms\tdevice_action_ms\tgesture_ms\ttouch_overhead_ms\tstall_over_50ms\thang\tstatus\n"); err != nil {
		return "", err
	}
	if err := writeText(filepath.Join(runDirectory, "frame-responsiveness.tsv"), "sample\tstarted_ms\tended_ms\tcommand_ms\tscreen_status\tsnapshot_status\n"); err != nil {
		return "", err
	}
	calibrationStart := nowMillis()
	calibrationPath := filepath.Join(runDirectory, "touch-calibration.json")
	calibrationErr := cliToFile(calibrationPath, deviceID, "ui_action", "--action", "tap", "--x", "1", "--y", "1", "--deadlineMs", "10000")
	calibrationEnd := nowMillis()
	if calibrationErr != nil {
		return "", errors.New("touch calibration failed")
	}
	calibrationAction, err := jsonNumber(calibrationPath, "actionDurationMs")
	if err != nil {
		return "", errors.New("touch calibration did not return device-side action timing")
	}
	if err := writeText(filepath.Join(runDirectory, "touch-calibration.txt"), fmt.Sprintf("started_ms=%d\nended_ms=%d\ncommand_ms=%d\ndevice_action_ms=%.0f\nstatus=0\n", calibrationStart, calibrationEnd, calibrationEnd-calibrationStart, calibrationAction)); err != nil {
		return "", err
	}
	calibrationSwipePath := filepath.Join(runDirectory, "touch-calibration-swipe.json")
	points := fmt.Sprintf("[[%d,%d],[%d,%d]]", startX, startY, endX, endY)
	calibrationSwipeErr := cliToFile(calibrationSwipePath, deviceID, "ui_action", "--action", "swipe", "--x", strconv.Itoa(startX), "--y", strconv.Itoa(startY), "--points", points, "--durationMs", "450", "--deadlineMs", "10000")
	calibrationSwipeAction, swipeTimingErr := jsonNumber(calibrationSwipePath, "actionDurationMs")
	if calibrationSwipeErr != nil || swipeTimingErr != nil {
		return "", errors.New("swipe calibration failed")
	}
	if err := writeText(filepath.Join(runDirectory, "touch-calibration-swipe.txt"), fmt.Sprintf("device_action_ms=%.0f\nstatus=0\n", calibrationSwipeAction)); err != nil {
		return "", err
	}
	appendFrame := func(label string) error {
		started := nowMillis()
		screenStatus, snapshotStatus := 0, 0
		if err := cliToFile(filepath.Join(runDirectory, "frame-"+label+"-screen.json"), deviceID, "screen_capture"); err != nil {
			screenStatus = statusCode(err)
		}
		if err := cliToFile(filepath.Join(runDirectory, "frame-"+label+"-snapshot.json"), deviceID, "ui_snapshot", "--application", "YouTube"); err != nil {
			snapshotStatus = statusCode(err)
		}
		ended := nowMillis()
		return appendText(filepath.Join(runDirectory, "frame-responsiveness.tsv"), fmt.Sprintf("%s\t%d\t%d\t%d\t%d\t%d\n", label, started, ended, ended-started, screenStatus, snapshotStatus))
	}
	collectMetrics := func(label string) error {
		return cliToFile(filepath.Join(runDirectory, "metrics-"+label+".json"), deviceID, "metrics_stream", "--process", "YouTube", "--durationMs", "5000", "--intervalMs", "250")
	}
	if err := collectMetrics("before"); err != nil {
		return "", err
	}
	startedRun := time.Now()
	index := 0
	for index == 0 || time.Since(startedRun) < time.Duration(durationMS)*time.Millisecond {
		started := nowMillis()
		swipePath := filepath.Join(runDirectory, fmt.Sprintf("swipe-%d.json", index))
		swipeErr := cliToFile(swipePath, deviceID, "ui_action", "--action", "swipe", "--x", strconv.Itoa(startX), "--y", strconv.Itoa(startY), "--points", points, "--durationMs", "450", "--deadlineMs", "10000")
		ended := nowMillis()
		deviceAction, actionErr := jsonNumber(swipePath, "actionDurationMs")
		if actionErr != nil {
			return "", fmt.Errorf("swipe %d did not return device-side action timing", index)
		}
		overhead := deviceAction - calibrationSwipeAction
		if overhead < 0 {
			overhead = 0
		}
		stall := 0
		if overhead > 50 {
			stall = 1
		}
		hang := 0
		if swipeErr != nil || ended-started > 5000 {
			hang = 1
		}
		if err := appendText(filepath.Join(runDirectory, "touch-latency.tsv"), fmt.Sprintf("%d\t%d\t%d\t%d\t%.0f\t450\t%.0f\t%d\t%d\t%d\n", index, started, ended, ended-started, deviceAction, overhead, stall, hang, statusCode(swipeErr))); err != nil {
			return "", err
		}
		if index%3 == 0 {
			if err := appendFrame(strconv.Itoa(index)); err != nil {
				return "", err
			}
			if err := collectMetrics("sample-" + strconv.Itoa(index)); err != nil {
				return "", err
			}
		}
		index++
		sleepMillis(1000)
	}
	if err := collectMetrics("after"); err != nil {
		return "", err
	}
	if err := appendFrame("end"); err != nil {
		return "", err
	}
	if err := cliToFile(filepath.Join(runDirectory, "processes-after.json"), deviceID, "process_manage", "--action", "list"); err != nil {
		return "", err
	}
	if err := cliToFile(filepath.Join(runDirectory, "crashes-after.json"), deviceID, "crash_manage", "--action", "list", "--process", "YouTube"); err != nil {
		return "", err
	}
	runText := fmt.Sprintf("mode=%s\nprofile=%s\nduration_ms=%d\nscroll_count=%d\ndevice=%s\nproduct_type=iPhone12,8\nyoutube_bundle_id=%s\n", mode, profile, durationMS, scrollCount, deviceID, youtubeID)
	if err := writeText(filepath.Join(runDirectory, "run.txt"), runText); err != nil {
		return "", err
	}
	return runDirectory, nil
}

func appendText(path, contents string) error {
	if err := ensureParent(path); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0644)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = file.WriteString(contents)
	return err
}

func cliToFileWithoutDevice(outputPath, action string, args ...string) error {
	parameters := append([]string{action, "--json"}, args...)
	return runToFile("", outputPath, cliPath(), parameters...)
}

func performanceSuite(args []string) error {
	deviceID := os.Getenv("GONERINO_DEVICE_ID")
	if deviceID == "" {
		deviceID = pinnedDeviceID
	}
	durationMS := os.Getenv("GONERINO_PERFORMANCE_DURATION_MS")
	if durationMS == "" {
		durationMS = "60000"
	}
	if _, err := strconv.ParseInt(durationMS, 10, 64); err != nil {
		return fmt.Errorf("invalid GONERINO_PERFORMANCE_DURATION_MS: %w", err)
	}
	outputRoot := os.Getenv("GONERINO_PERFORMANCE_OUTPUT")
	if outputRoot == "" {
		outputRoot = "/tmp/gonerino-performance-suite"
	}
	profiles := append([]string(nil), args...)
	if len(profiles) == 0 {
		profiles = strings.Fields("home subscriptions search long-form shorts")
	}
	if err := os.MkdirAll(outputRoot, 0755); err != nil {
		return err
	}
	defer func() {
		_ = cliToFile(filepath.Join(outputRoot, "screen-off.json"), deviceID, "ui_action", "--action", "screen_off")
	}()
	if err := cliToFileWithoutDevice(filepath.Join(outputRoot, "device-list.json"), "device_list"); err != nil {
		return err
	}
	statusPath := filepath.Join(outputRoot, "device-status.json")
	if err := cliToFile(statusPath, deviceID, "device_status"); err != nil {
		return err
	}
	if err := checkDeviceStatus(statusPath, deviceID); err != nil {
		return err
	}
	backupDirectory := filepath.Join(outputRoot, "blocklist-backup")
	backupPath, err := backupBlocklists(deviceID, backupDirectory)
	if err != nil {
		return err
	}
	if err := writeText(filepath.Join(outputRoot, "blocklist-backup-path.txt"), backupPath+"\n"); err != nil {
		return err
	}
	if packagePath := os.Getenv("GONERINO_PACKAGE"); packagePath != "" {
		if err := cliToFile(filepath.Join(outputRoot, "deployment.json"), deviceID, "tweak_deploy", "--package", packagePath, "--processes", "YouTube", "--reload", "none"); err != nil {
			return err
		}
		if err := cliToFile(filepath.Join(outputRoot, "deployment-force-quit.json"), deviceID, "shell_exec", "--command", "killall -9 YouTube >/dev/null 2>&1 || true"); err != nil {
			return err
		}
		sleepMillis(2000)
		if err := cliToFile(filepath.Join(outputRoot, "deployment-launch.json"), deviceID, "app_manage", "--action", "launch", "--bundleId", youtubeBundleID); err != nil {
			return err
		}
		sleepMillis(3000)
	}
	if err := writeText(filepath.Join(outputRoot, "runs.tsv"), "profile\tmode\tpath\n"); err != nil {
		return err
	}
	for _, profile := range profiles {
		enabledPath, err := runPerformance([]string{deviceID, "enabled", profile, durationMS, outputRoot})
		if err != nil {
			return err
		}
		if err := appendText(filepath.Join(outputRoot, "runs.tsv"), fmt.Sprintf("%s\tenabled\t%s\n", profile, enabledPath)); err != nil {
			return err
		}
		disabledPath, err := runPerformance([]string{deviceID, "disabled", profile, durationMS, outputRoot})
		if err != nil {
			return err
		}
		if err := appendText(filepath.Join(outputRoot, "runs.tsv"), fmt.Sprintf("%s\tdisabled\t%s\n", profile, disabledPath)); err != nil {
			return err
		}
	}
	if err := writeText(filepath.Join(outputRoot, "suite.txt"), fmt.Sprintf("device=%s\nproduct_type=iPhone12,8\nduration_ms=%s\nprofiles=%s\n", deviceID, durationMS, strings.Join(profiles, " "))); err != nil {
		return err
	}
	analysis, passed, err := performanceAnalysis(outputRoot)
	if err != nil {
		return err
	}
	if err := writeText(filepath.Join(outputRoot, "analysis.json"), string(analysis)); err != nil {
		return err
	}
	if !passed {
		return errors.New("performance suite did not pass")
	}
	fmt.Println(outputRoot)
	return nil
}

func settingsRegression(args []string) error {
	root, err := repoRoot()
	if err != nil {
		return err
	}
	deviceID := pinnedDeviceID
	if len(args) > 0 && args[0] != "" {
		deviceID = args[0]
	}
	outputDirectory := ""
	if len(args) > 1 {
		outputDirectory = args[1]
	}
	openCount := 20
	if len(args) > 2 && args[2] != "" {
		openCount, err = strconv.Atoi(args[2])
		if err != nil || openCount < 1 {
			return errors.New("open count must be a positive integer")
		}
	}
	if outputDirectory == "" {
		if err := os.MkdirAll(filepath.Join(root, ".theos"), 0755); err != nil {
			return err
		}
		outputDirectory, err = os.MkdirTemp(filepath.Join(root, ".theos"), "gonerino-settings.")
		if err != nil {
			return err
		}
	}
	if err := os.MkdirAll(outputDirectory, 0755); err != nil {
		return err
	}
	pmd3 := os.Getenv("PYMOBILEDEVICE3_BIN")
	if pmd3 == "" {
		if value, lookupErr := exec.LookPath("pymobiledevice3"); lookupErr == nil {
			pmd3 = value
		} else {
			pmd3 = "pymobiledevice3"
		}
	}
	captureText := func(name string) error {
		imagePath := filepath.Join(outputDirectory, name+".png")
		if err := runDiscard(pmd3, "developer", "dvt", "screenshot", "--userspace", "--udid", deviceID, imagePath); err != nil {
			return err
		}
		textBase := filepath.Join(outputDirectory, name)
		command := exec.Command("tesseract", imagePath, textBase)
		command.Stdout = nil
		command.Stderr = nil
		_ = command.Run()
		return nil
	}
	assertCustomPage := func(name string) error {
		contents, err := os.ReadFile(filepath.Join(outputDirectory, name+".txt"))
		if err != nil {
			return err
		}
		text := strings.ToLower(string(contents))
		if !strings.Contains(text, "donate on ko-fi") && !strings.Contains(text, "support") {
			return fmt.Errorf("%s did not render the custom Gonerino page; artifacts: %s", name, outputDirectory)
		}
		return nil
	}
	for index := 1; index <= openCount; index++ {
		if err := cliToFile(filepath.Join(outputDirectory, fmt.Sprintf("open-%d.json", index)), deviceID, "ui_action", "--action", "tap", "--x", "180", "--y", "97", "--deadlineMs", "10000"); err != nil {
			return err
		}
		sleepMillis(50)
		first := fmt.Sprintf("open-%d-first", index)
		if err := captureText(first); err != nil {
			return err
		}
		if err := assertCustomPage(first); err != nil {
			return err
		}
		sleepMillis(750)
		settled := fmt.Sprintf("open-%d-settled", index)
		if err := captureText(settled); err != nil {
			return err
		}
		if err := assertCustomPage(settled); err != nil {
			return err
		}
		if index < openCount {
			if err := cliToFile(filepath.Join(outputDirectory, fmt.Sprintf("back-%d.json", index)), deviceID, "ui_action", "--action", "tap", "--x", "20", "--y", "42", "--deadlineMs", "10000"); err != nil {
				return err
			}
			sleepMillis(250)
		}
	}
	fmt.Println(outputDirectory)
	return nil
}

func testFeedAdapterSimulator(args []string) error {
	root, err := repoRoot()
	if err != nil {
		return err
	}
	simulatorID := os.Getenv("GONERINO_SIMULATOR_ID")
	if simulatorID == "" {
		simulatorID = "booted"
	}
	if err := os.MkdirAll(filepath.Join(root, ".theos"), 0755); err != nil {
		return err
	}
	buildDirectory, err := os.MkdirTemp(filepath.Join(root, ".theos"), "gonerino-adapter-harness.")
	if err != nil {
		return err
	}
	defer os.RemoveAll(buildDirectory)
	sdk, err := runOutput("", "xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
	if err != nil {
		return err
	}
	sdkPath := strings.TrimSpace(string(sdk))
	if _, err := runOutput("", "xcrun", "simctl", "bootstatus", simulatorID, "-b"); err != nil {
		return err
	}
	binaryPath := filepath.Join(buildDirectory, "GonerinoAdapterHarness")
	clangArgs := []string{
		"-arch", "arm64",
		"-isysroot", sdkPath,
		"-mios-simulator-version-min=15.0",
		"-fobjc-arc",
		"-fblocks",
		"-Wno-incomplete-implementation",
		"-I" + filepath.Join(root, "headers"),
		filepath.Join(root, "tests", "feed-data-source-adapter-harness.m"),
		filepath.Join(root, "sources", "FeedDataSourceAdapter.m"),
		"-framework", "UIKit",
		"-framework", "CoreGraphics",
		"-o", binaryPath,
	}
	if _, err := runOutput("", "xcrun", append([]string{"clang"}, clangArgs...)...); err != nil {
		return err
	}
	appDirectory := filepath.Join(buildDirectory, "GonerinoAdapterHarness.app")
	if err := os.MkdirAll(appDirectory, 0755); err != nil {
		return err
	}
	if err := copyFile(binaryPath, filepath.Join(appDirectory, "GonerinoAdapterHarness")); err != nil {
		return err
	}
	if err := copyFile(filepath.Join(root, "tests", "feed-data-source-adapter-harness-Info.plist"), filepath.Join(appDirectory, "Info.plist")); err != nil {
		return err
	}
	if _, err := runOutput("", "xcrun", "simctl", "install", simulatorID, appDirectory); err != nil {
		return err
	}
	if _, err := runOutput("", "xcrun", "simctl", "launch", simulatorID, "dev.adrian.gonerino.adapter-harness"); err != nil {
		return err
	}
	for attempt := 0; attempt < 20; attempt++ {
		output, _ := runOutput("", "xcrun", "simctl", "spawn", simulatorID, "log", "show", "--last", "5s", "--style", "compact", "--predicate", `process == "GonerinoAdapterHarness"`)
		if strings.Contains(string(output), "PASS: adapter snapshot") {
			fmt.Println("feed data-source adapter simulator checks passed")
			return nil
		}
		sleepMillis(250)
	}
	output, _ := runOutput("", "xcrun", "simctl", "spawn", simulatorID, "log", "show", "--last", "30s", "--style", "compact", "--predicate", `process == "GonerinoAdapterHarness"`)
	return fmt.Errorf("feed data-source adapter simulator checks did not report a pass:\n%s", output)
}

func copyFile(source, destination string) error {
	contents, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	if err := ensureParent(destination); err != nil {
		return err
	}
	if err := os.WriteFile(destination, contents, 0755); err != nil {
		return err
	}
	return nil
}

func requireFileContains(root, relativePath, value string) error {
	contents, err := os.ReadFile(filepath.Join(root, relativePath))
	if err != nil {
		return err
	}
	if !strings.Contains(string(contents), value) {
		return fmt.Errorf("%s does not contain %q", relativePath, value)
	}
	return nil
}

func requireFileExcludes(root, relativePath string, values []string) error {
	contents, err := os.ReadFile(filepath.Join(root, relativePath))
	if err != nil {
		return err
	}
	text := string(contents)
	for _, value := range values {
		if strings.Contains(text, value) {
			return fmt.Errorf("%s contains forbidden %q", relativePath, value)
		}
	}
	return nil
}

func verifyArchitecture(root string) error {
	legacySymbols := []string{
		"layoutSubviews",
		"didMoveToWindow",
		"scheduleFiltering",
		"FilterVisible",
		"GapCollapse",
		"filterScheduled",
		"lastFilterTime",
		"MetadataNodeForView",
		"CollectTextNodeValues",
		"CollectElementTreeMetadata",
		"CollectObject",
		"VideoNodeFromView",
		"ActionMetadataNodeFromObject",
		"VisibleFeedCellForVideoID",
		"AsyncCollectionViewInView",
		"deleteItemsAtIndexPaths",
		"scrollToItemAtIndexPath",
		"setContentOffset",
		"reelContentViewRequestsAdvanceToNextVideo",
		"%hook YTInlinePlaybackPlayerNode",
		"%hook YTElementsInlineMutedPlaybackView",
		"setAsdPlayableEntry:",
	}
	for _, relativePath := range []string{"sources/Util.m", "sources/Tweak.x", "sources/FeedDataSourceAdapter.m"} {
		if err := requireFileExcludes(root, relativePath, legacySymbols); err != nil {
			return errors.New("legacy UI-driven filtering symbols are still present: " + err.Error())
		}
	}
	if err := requireFileExcludes(root, "sources/Util.m", []string{"subviews", "accessibilityElements"}); err != nil {
		return errors.New("recursive UI-tree metadata extraction is still present: " + err.Error())
	}
	if err := requireFileContains(root, "sources/Tweak.x", "- (void)setAsyncDataSource:"); err != nil {
		return errors.New("async data-source setter hook is missing")
	}
	if err := requireFileContains(root, "sources/Tweak.x", "UpdateNavigationButton"); err != nil {
		return errors.New("navigation button state updater is missing")
	}
	if err := requireFileExcludes(root, "sources/Tweak.x", []string{"QueueShortsContentMetadata", "ShortsMetadataForContentView", "ShortsMetadataCaptureStateKey"}); err != nil {
		return errors.New("repeated Shorts lifecycle metadata capture is still present")
	}
	if err := requireFileExcludes(root, "sources/Settings.x", []string{"SettingsCategoryPending", "CurrentSettingsManager", "YTCollectionViewController", "setTitle:"}); err != nil {
		return errors.New("legacy settings lifecycle or title redirect state is still present")
	}
	required := map[string][]string{
		"headers/Util.h":                  {"FeedMetadataRecord"},
		"sources/Util.m":                  {"AdaptLongFormVideoNode", "AdaptElementsFeedNode", "AdaptShortsNode"},
		"sources/Tweak.x":                 {"setAsyncDataSource", "presentFromView", "shouldDismissOnAction = YES", "FeedFilterStateDidChangeNotification"},
		"sources/FeedDataSourceAdapter.m": {"nodeForItemAtIndexPath", "sourceItemsBySection", "EmptyFeedNode", "calculateSizeThatFits", "FeedEmptyCellNode", "snapshotForCountRequestWithRetryCount"},
		"sources/Settings.x":              {"pushViewController", "expectedCategory", "SettingsNavigationTransactionKey"},
	}
	for relativePath, values := range required {
		for _, value := range values {
			if err := requireFileContains(root, relativePath, value); err != nil {
				return err
			}
		}
	}
	adapter, err := os.ReadFile(filepath.Join(root, "sources", "FeedDataSourceAdapter.m"))
	if err != nil {
		return err
	}
	adapterText := string(adapter)
	if strings.Contains(adapterText, "return [self snapshotForCountRequest];") {
		return errors.New("snapshot construction still has unbounded recursive retry")
	}
	if strings.Contains(adapterText, "SourcePathForRelatedNode") && strings.Contains(adapterText, "metadataForNode:") {
		return errors.New("normal feed metadata lookup still walks related objects")
	}
	for _, entry := range []string{
		"scripts/gonerino-tools.go",
		"tests/metadata-fixtures.json",
	} {
		if _, err := os.Stat(filepath.Join(root, entry)); err != nil {
			return err
		}
	}
	for _, relativePath := range []string{"scripts"} {
		entries, err := os.ReadDir(filepath.Join(root, relativePath))
		if err != nil {
			return err
		}
		for _, entry := range entries {
			if strings.HasSuffix(entry.Name(), ".py") || strings.HasSuffix(entry.Name(), ".sh") {
				return fmt.Errorf("legacy script remains: %s", entry.Name())
			}
		}
		break
	}
	if err := testMetadataFixtures(root); err != nil {
		return err
	}
	if err := testBlocklistRestore(root); err != nil {
		return err
	}
	fmt.Println("Gonerino architecture checks passed")
	return nil
}

func printUsage() {
	fmt.Fprintln(os.Stderr, "usage: gonerino-tools COMMAND [ARGS]")
	fmt.Fprintln(os.Stderr, "commands: analyze-performance, generate-screenshot-strip, merge-blocklists, test-blocklist-restore, test-metadata-fixtures, blocklist-backup, blocklist-restore, performance, performance-suite, settings-regression, test-feed-data-source-adapter-simulator, verify-architecture")
}

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(2)
	}
	commandName := os.Args[1]
	args := os.Args[2:]
	var err error
	switch commandName {
	case "analyze-performance":
		err = analyzePerformanceCommand(args)
	case "generate-screenshot-strip":
		var root string
		root, err = repoRoot()
		if err == nil {
			if len(args) != 0 {
				err = errors.New("usage: generate-screenshot-strip")
			} else {
				err = generateScreenshotStrip(root)
			}
		}
	case "merge-blocklists":
		if len(args) != 3 {
			err = errors.New("usage: merge-blocklists CURRENT_PLIST BACKUP_JSON OUTPUT_PLIST")
		} else {
			err = mergeBlocklists(args[0], args[1], args[2])
		}
	case "test-blocklist-restore":
		var root string
		root, err = repoRoot()
		if err == nil && len(args) == 0 {
			err = testBlocklistRestore(root)
		} else if err == nil {
			err = errors.New("usage: test-blocklist-restore")
		}
	case "test-metadata-fixtures":
		var root string
		root, err = repoRoot()
		if err == nil && len(args) == 0 {
			err = testMetadataFixtures(root)
		} else if err == nil {
			err = errors.New("usage: test-metadata-fixtures")
		}
	case "blocklist-backup":
		deviceID := pinnedDeviceID
		outputDirectory := "/tmp/gonerino-blocklist-backup"
		if len(args) > 0 && args[0] != "" {
			deviceID = args[0]
		}
		if len(args) > 1 && args[1] != "" {
			outputDirectory = args[1]
		}
		if len(args) > 2 {
			err = errors.New("usage: blocklist-backup [DEVICE] [OUTPUT_DIRECTORY]")
		} else {
			_, err = backupBlocklists(deviceID, outputDirectory)
			if err == nil {
				fmt.Println(outputDirectory)
			}
		}
	case "blocklist-restore":
		deviceID := pinnedDeviceID
		backupDirectory := "/tmp/gonerino-blocklist-backup"
		outputDirectory := ""
		if len(args) > 0 && args[0] != "" {
			deviceID = args[0]
		}
		if len(args) > 1 && args[1] != "" {
			backupDirectory = args[1]
		}
		if len(args) > 2 && args[2] != "" {
			outputDirectory = args[2]
		}
		if len(args) > 3 {
			err = errors.New("usage: blocklist-restore [DEVICE] [BACKUP_DIRECTORY] [OUTPUT_DIRECTORY]")
		} else {
			if outputDirectory == "" {
				outputDirectory = filepath.Join(backupDirectory, "restore-"+runID())
			}
			_, err = restoreBlocklists(deviceID, backupDirectory, outputDirectory)
			if err == nil {
				fmt.Println(outputDirectory)
			}
		}
	case "performance":
		var output string
		output, err = runPerformance(args)
		if err == nil {
			fmt.Println(output)
		}
	case "performance-suite":
		err = performanceSuite(args)
	case "settings-regression":
		if len(args) > 3 {
			err = errors.New("usage: settings-regression [DEVICE] [OUTPUT_DIRECTORY] [OPEN_COUNT]")
		} else {
			err = settingsRegression(args)
		}
	case "test-feed-data-source-adapter-simulator":
		if len(args) != 0 {
			err = errors.New("usage: test-feed-data-source-adapter-simulator")
		} else {
			err = testFeedAdapterSimulator(args)
		}
	case "verify-architecture":
		var root string
		root, err = repoRoot()
		if err == nil && len(args) == 0 {
			err = verifyArchitecture(root)
		} else if err == nil {
			err = errors.New("usage: verify-architecture")
		}
	default:
		printUsage()
		err = fmt.Errorf("unknown command %q", commandName)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
