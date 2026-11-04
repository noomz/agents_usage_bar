package jsonl

import (
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReadDeltaResumesAndKeepsPartialLine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a.jsonl")
	if err := os.WriteFile(path, []byte("one\ntwo\npart"), 0o600); err != nil {
		t.Fatal(err)
	}
	d, err := ReadDelta(path, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(d.Lines) != 2 || string(d.Lines[1]) != "two" || d.NewOffset != 8 {
		t.Fatalf("%+v", d)
	}
	f, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	_, _ = f.WriteString("ial\nnext\n")
	f.Close()
	d, err = ReadDelta(path, d.NewOffset, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(d.Lines) != 2 || string(d.Lines[0]) != "partial" || d.NewOffset != 21 {
		t.Fatalf("%+v", d)
	}
}

func TestReadDeltaRestartsWhenMtimeRegresses(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a.jsonl")
	if err := os.WriteFile(path, []byte("one\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	later := time.Now().Add(time.Hour)
	d, err := ReadDelta(path, 4, &later)
	if err != nil {
		t.Fatal(err)
	}
	if len(d.Lines) != 1 || d.NewOffset != 4 {
		t.Fatalf("%+v", d)
	}
}

func TestInvalidUTF8IsConsumedAndSkipped(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a.jsonl")
	if err := os.WriteFile(path, []byte("ok\n\xff\xfe\nok2\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	d, err := ReadDelta(path, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(d.Lines) != 2 || d.NewOffset != 10 {
		t.Fatalf("%+v", d)
	}
}

func TestMissingFileErrors(t *testing.T) {
	if _, err := ReadDelta(filepath.Join(t.TempDir(), "x"), 0, nil); err == nil {
		t.Fatal("expected error")
	}
}

func TestScanRoots(t *testing.T) {
	root := t.TempDir()
	write := func(rel string, mtime time.Time) {
		path := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("x\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(path, mtime, mtime); err != nil {
			t.Fatal(err)
		}
	}
	old := time.Now().Add(-48 * time.Hour)
	fresh := time.Now()
	write("p/old.jsonl", old)
	write("p/new.jsonl", fresh)
	write("p/skip.txt", fresh)
	write(".hidden/h.jsonl", fresh)
	write("p/.h.jsonl", fresh)

	all := ScanRoots([]string{root, filepath.Join(root, "missing")}, nil)
	if len(all) != 2 {
		t.Fatalf("%v", all)
	}
	cut := time.Now().Add(-time.Hour)
	recent := ScanRoots([]string{root}, &cut)
	if len(recent) != 1 || !strings.HasSuffix(recent[0], "new.jsonl") {
		t.Fatalf("%v", recent)
	}
}

func TestFileURLMatchesFoundation(t *testing.T) {
	got := FileURL("/tmp/a b/c[d]+&=@:,;!$'()*~#?%.jsonl")
	want := "file:///tmp/a%20b/c%5Bd%5D+&=@:,;!$'()*~%23%3F%25.jsonl"
	if got != want {
		t.Fatalf("got %s", got)
	}
}

// A cursor round-trips through the Double Foundation stores, which can land after the true mtime.
func TestReadDeltaResumesWhenStoredMtimeRoundsUp(t *testing.T) {
	path := filepath.Join(t.TempDir(), "s.jsonl")
	if err := os.WriteFile(path, []byte("one\ntwo\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	base := time.Date(2026, 11, 3, 10, 0, 0, 0, time.UTC)
	restarts := 0
	for nanos := 0; nanos < 300; nanos++ {
		mtime := base.Add(time.Duration(nanos))
		if err := os.Chtimes(path, mtime, mtime); err != nil {
			t.Fatal(err)
		}
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		stored := domain.RefDate(domain.RefSeconds(info.ModTime()))
		delta, err := ReadDelta(path, 4, &stored)
		if err != nil {
			t.Fatal(err)
		}
		if len(delta.Lines) != 1 || string(delta.Lines[0]) != "two" {
			restarts++
		}
	}
	if restarts != 0 {
		t.Fatalf("%d of 300 cursors restarted an unchanged file", restarts)
	}
}

func TestReadDeltaRestartsWhenMtimeGoesBack(t *testing.T) {
	path := filepath.Join(t.TempDir(), "s.jsonl")
	if err := os.WriteFile(path, []byte("one\ntwo\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	later := info.ModTime().Add(time.Second)
	delta, err := ReadDelta(path, 4, &later)
	if err != nil {
		t.Fatal(err)
	}
	if len(delta.Lines) != 2 {
		t.Fatalf("replaced file must restart: %q", delta.Lines)
	}
}

func TestReplacedFileShorterThanTheCursorIsReadFromTheStart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a.jsonl")
	if err := os.WriteFile(path, []byte("first-long-line\nsecond-long-line\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	first, err := ReadDelta(path, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("new\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	newer := first.LastModified.Add(time.Hour)
	if err := os.Chtimes(path, newer, newer); err != nil {
		t.Fatal(err)
	}
	second, err := ReadDelta(path, first.NewOffset, &first.LastModified)
	if err != nil {
		t.Fatal(err)
	}
	if len(second.Lines) != 1 || string(second.Lines[0]) != "new" || second.NewOffset != 4 {
		t.Fatalf("%+v", second)
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString("next\n"); err != nil {
		t.Fatal(err)
	}
	f.Close()
	third, err := ReadDelta(path, second.NewOffset, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(third.Lines) != 1 || string(third.Lines[0]) != "next" {
		t.Fatalf("the cursor must keep moving after a reset: %+v", third)
	}
}
