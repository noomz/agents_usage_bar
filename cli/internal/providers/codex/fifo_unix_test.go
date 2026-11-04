//go:build unix

package codex

import (
	"context"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestFifoRolloutDoesNotHangTheRun(t *testing.T) {
	h := newHome(t)
	good := h.rollout("2026-10-07", "r.jsonl", tokenLine("2026-10-07T02:00:00.000Z", 1, "")+"\n")
	if err := syscall.Mkfifo(filepath.Join(filepath.Dir(good), "pipe.jsonl"), 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, _, err := h.build().Fetch(context.Background(), testNow)
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("fetch hung on a FIFO named like a rollout")
	}
	if len(h.c.offsets) != 1 {
		t.Fatalf("only the regular file is tracked: %v", h.c.offsets)
	}
}
