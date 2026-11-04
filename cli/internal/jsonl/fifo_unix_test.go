//go:build unix

package jsonl

import (
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestReadDeltaRefusesAFifo(t *testing.T) {
	path := filepath.Join(t.TempDir(), "p.jsonl")
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := ReadDelta(path, 0, nil)
		done <- err
	}()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("a FIFO is not a transcript")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("ReadDelta hung on a FIFO")
	}
}
