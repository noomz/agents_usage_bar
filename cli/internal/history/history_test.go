package history

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func dayJSON(key string) string {
	return `{"schemaVersion":1,"date":"` + key + `","timeZone":"UTC","records":[],"events":[],"backfillChecked":[]}`
}

func TestMissingDirectoryIsEmptyAndNotCreated(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "history")
	keys, err := Reader{dir}.DayKeys()
	if err != nil || len(keys) != 0 {
		t.Errorf("%v %v", keys, err)
	}
	if _, err := os.Stat(dir); err == nil {
		t.Error("created")
	}
}

func TestListsDayFilesOldestFirst(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{
		"2026-10-22.json": dayJSON("2026-10-22"), "2026-10-20.json": dayJSON("2026-10-20"),
		".account-salt": "salt", "notes.txt": "x", "2026-10.json": "{}", "2026-10-21.json.tmp": "{}",
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	keys, err := Reader{dir}.DayKeys()
	if err != nil || strings.Join(keys, ",") != "2026-10-20,2026-10-22" {
		t.Errorf("%v %v", keys, err)
	}
}

func TestSkipsNewerUnknownUnreadableAndMisnamedFiles(t *testing.T) {
	dir := t.TempDir()
	files := map[string]string{
		"2026-10-01.json": dayJSON("2026-10-01"),
		"2026-10-02.json": `{"schemaVersion":2}`,
		"2026-10-03.json": "garbage",
		"2026-10-04.json": dayJSON("2026-10-09"),
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	days, err := Reader{dir}.Days("2026-01-01", "2026-12-31")
	if err != nil || len(days) != 1 || days[0].Date != "2026-10-01" {
		t.Errorf("%+v %v", days, err)
	}
	for name, body := range files {
		got, _ := os.ReadFile(filepath.Join(dir, name))
		if string(got) != body {
			t.Errorf("%s changed", name)
		}
	}
}

func TestDaysHonoursRange(t *testing.T) {
	dir := t.TempDir()
	for _, key := range []string{"2026-10-01", "2026-10-02", "2026-10-03"} {
		if err := os.WriteFile(filepath.Join(dir, key+".json"), []byte(dayJSON(key)), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	days, err := Reader{dir}.Days("2026-10-02", "2026-10-03")
	if err != nil || len(days) != 2 || days[0].Date != "2026-10-02" {
		t.Errorf("%+v %v", days, err)
	}
}

func TestUnlistableDirectoryErrors(t *testing.T) {
	file := filepath.Join(t.TempDir(), "history")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := Reader{file}.DayKeys()
	if err == nil || err.Error() != "The file “history” couldn’t be opened." {
		t.Errorf("%v", err)
	}
}
