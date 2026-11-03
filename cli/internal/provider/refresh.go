package provider

// RefreshPolicy says whether this process may spend a stored OAuth refresh token. Spending one
// can invalidate it, and the owning CLI (Claude Code, gemini-cli) still holds the old copy, so a
// lost race or a failed write-back logs the user out. The zero value forbids.
type RefreshPolicy int

// The policies.
const (
	RefreshForbidden RefreshPolicy = iota
	RefreshAllowed
)

// RefreshPolicyFor is the one place the rule lives. macOS keeps the app's behavior. Elsewhere the
// credential file is the CLI's only login, so tokens wait for that CLI to refresh them, at the
// cost of no quota bars on an idle host.
func RefreshPolicyFor(goos string) RefreshPolicy {
	if goos == "darwin" {
		return RefreshAllowed
	}
	return RefreshForbidden
}
