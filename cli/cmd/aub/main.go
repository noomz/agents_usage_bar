// Command aub prints AI agent usage: today's spend, tokens, quota, and history.
package main

import (
	"os"
	"runtime/debug"

	"github.com/noomz/agents_usage_bar/cli/internal/cli"
)

// version is set at build time with `-ldflags "-X main.version=1.2.3"`.
var version string

func main() {
	info, _ := debug.ReadBuildInfo()
	os.Exit(cli.NewApp(cli.ResolveVersion(version, info)).Run(os.Args[1:]))
}
