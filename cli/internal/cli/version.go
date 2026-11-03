package cli

import "runtime/debug"

// ResolveVersion is the -ldflags value, then the module version `go install` records, then dev.
func ResolveVersion(ldflags string, info *debug.BuildInfo) string {
	if ldflags != "" {
		return ldflags
	}
	if info != nil && info.Main.Version != "" && info.Main.Version != "(devel)" {
		return info.Main.Version
	}
	return "dev"
}
