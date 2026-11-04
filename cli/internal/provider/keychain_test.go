package provider

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func stubBinary(t *testing.T, body string) (bin, counter string) {
	t.Helper()
	dir := t.TempDir()
	counter = filepath.Join(dir, "calls")
	bin = filepath.Join(dir, "security")
	script := "#!/bin/sh\necho x >> '" + counter + "'\n" + body + "\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin, counter
}

func calls(t *testing.T, counter string) int {
	t.Helper()
	data, _ := os.ReadFile(counter)
	return strings.Count(string(data), "x")
}

func TestKeychainReadGivesUpAtTheDeadlineAndReadsOnce(t *testing.T) {
	bin, counter := stubBinary(t, "exec sleep 30")
	read := keychainReader(bin, time.Second)
	start := time.Now()
	if _, err := read("svc"); err == nil {
		t.Fatal("a hung read must fail")
	}
	if _, err := read("svc"); err == nil {
		t.Fatal("second read must repeat the failure")
	}
	if elapsed := time.Since(start); elapsed > 4*time.Second {
		t.Fatalf("took %v", elapsed)
	}
	if n := calls(t, counter); n != 1 {
		t.Fatalf("%d reads, want 1", n)
	}
}

func TestKeychainReadReturnsTheItemOnce(t *testing.T) {
	bin, counter := stubBinary(t, "echo secret-value")
	read := keychainReader(bin, time.Second)
	for range 3 {
		data, err := read("svc")
		if err != nil || string(data) != "secret-value" {
			t.Fatalf("%q %v", data, err)
		}
	}
	if n := calls(t, counter); n != 1 {
		t.Fatalf("%d reads, want 1", n)
	}
}
