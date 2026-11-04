package cache

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

func holdLock(t *testing.T, path string) (release func()) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	file, err := os.OpenFile(path+".lock", os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { file.Close() })
	return func() { file.Close() }
}

func lockIsHeld(t *testing.T, path string) bool {
	t.Helper()
	file, err := os.Open(path + ".lock")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	return errors.Is(syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB), syscall.EWOULDBLOCK)
}

func skipIfRoot(t *testing.T) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("root ignores file modes")
	}
}

func TestStuckHolderFailsWithoutTouchingTheStore(t *testing.T) {
	s, path := newStore(t)
	s.lockWait = 100 * time.Millisecond
	holdLock(t, path)

	start := time.Now()
	err := s.WithCursors(func(Cursors) { t.Error("body ran without the lock") })
	if !errors.Is(err, errLockTimeout) {
		t.Fatalf("WithCursors: %v", err)
	}
	if took := time.Since(start); took < s.lockWait || took > 5*time.Second {
		t.Fatalf("waited %v", took)
	}
	if err := s.MaintainBaseline(domain.OpenRouter, day1, 10); !errors.Is(err, errLockTimeout) {
		t.Fatalf("MaintainBaseline: %v", err)
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("store written: %v", err)
	}
}

func TestSiblingsDoNotEachWaitTheDeadline(t *testing.T) {
	s, path := newStore(t)
	s.lockWait = 300 * time.Millisecond
	holdLock(t, path)
	if s.WithCursors(func(Cursors) {}) == nil {
		t.Fatal("first wait must time out")
	}
	start := time.Now()
	if s.WithCursors(func(Cursors) {}) == nil {
		t.Fatal("second wait must fail")
	}
	if took := time.Since(start); took >= s.lockWait {
		t.Fatalf("second caller waited %v", took)
	}
}

func TestHolderReleasingInTimeLetsTheWaiterRun(t *testing.T) {
	s, path := newStore(t)
	release := holdLock(t, path)
	time.AfterFunc(100*time.Millisecond, release)
	ran := false
	if err := s.WithCursors(func(Cursors) { ran = true }); err != nil || !ran {
		t.Fatalf("ran %v, err %v", ran, err)
	}
}

func TestReadOnlyLockFileStillExcludes(t *testing.T) {
	skipIfRoot(t)
	s, path := newStore(t)
	write(t, path+".lock", "")
	if err := os.Chmod(path+".lock", 0o444); err != nil {
		t.Fatal(err)
	}
	ran := false
	err := s.WithCursors(func(Cursors) {
		ran = true
		if !lockIsHeld(t, path) {
			t.Error("body ran unlocked")
		}
	})
	if err != nil || !ran {
		t.Fatalf("ran %v, err %v", ran, err)
	}
}

func TestLockFileThatCannotBeOpenedFails(t *testing.T) {
	skipIfRoot(t)
	s, path := newStore(t)
	write(t, path+".lock", "")
	if err := os.Chmod(path+".lock", 0o000); err != nil {
		t.Fatal(err)
	}
	if err := s.WithCursors(func(Cursors) { t.Error("body ran without the lock") }); err == nil {
		t.Fatal("no error")
	}
	if s.MaintainBaseline(domain.OpenRouter, day1, 10) == nil {
		t.Fatal("no error")
	}
}

func TestReadOnlyDirectoryRunsAndWritesNothing(t *testing.T) {
	skipIfRoot(t)
	s, path := newStore(t)
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o755) })
	ran := false
	if err := s.WithCursors(func(Cursors) { ran = true }); err != nil || !ran {
		t.Fatalf("ran %v, err %v", ran, err)
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("store written: %v", err)
	}
}
