package provider

import (
	"context"
	"errors"
	"os/exec"
	"sync"
	"time"
)

const (
	securityBinary  = "/usr/bin/security"
	keychainTimeout = 3 * time.Second
)

// KeychainFor returns the generic-password reader for an operating system, nil where there is no
// Keychain. It runs /usr/bin/security instead of calling SecItem: Claude Code creates its item
// with the security CLI, so the item's ACL trusts that binary and never prompts, while a direct
// read would check this binary's identity and prompt after every build. Read-only by design.
func KeychainFor(goos string) func(service string) ([]byte, error) {
	if goos != "darwin" {
		return nil
	}
	return keychainReader(securityBinary, keychainTimeout)
}

// keychainReader runs the binary at most once per service for the life of the process, and gives
// up after timeout, so a locked keychain waiting on a dialog costs one bounded delay per run.
func keychainReader(binary string, timeout time.Duration) func(service string) ([]byte, error) {
	type result struct {
		data []byte
		err  error
	}
	var mu sync.Mutex
	seen := map[string]result{}
	return func(service string) ([]byte, error) {
		mu.Lock()
		defer mu.Unlock()
		if r, ok := seen[service]; ok {
			return r.data, r.err
		}
		data, err := readKeychain(binary, timeout, service)
		seen[service] = result{data, err}
		return data, err
	}
}

func readKeychain(binary string, timeout time.Duration, service string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, "find-generic-password", "-s", service, "-w")
	// A killed child can leave grandchildren holding the pipe open.
	cmd.WaitDelay = time.Second
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	if n := len(out); n > 0 && out[n-1] == '\n' {
		out = out[:n-1]
	}
	if len(out) == 0 {
		return nil, errors.New("empty keychain item")
	}
	return out, nil
}
