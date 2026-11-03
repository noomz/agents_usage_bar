package jsonl

import (
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
