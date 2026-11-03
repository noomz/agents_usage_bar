package provider

import (
	"errors"
	"os/exec"
)

// KeychainFor returns the generic-password reader for an operating system, nil where there is no
// Keychain. It runs /usr/bin/security instead of calling SecItem: Claude Code creates its item
// with the security CLI, so the item's ACL trusts that binary and never prompts, while a direct
// read would check this binary's identity and prompt after every build. Read-only by design.
func KeychainFor(goos string) func(service string) ([]byte, error) {
	if goos != "darwin" {
		return nil
	}
	return func(service string) ([]byte, error) {
		out, err := exec.Command("/usr/bin/security", "find-generic-password", "-s", service, "-w").Output()
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
}
