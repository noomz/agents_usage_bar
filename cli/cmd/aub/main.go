// Command aub prints AI agent usage: today's spend, tokens, quota, and history.
package main

import (
	"os"

	"github.com/noomz/agents_usage_bar/cli/internal/cli"
)

// version is set at build time with `-ldflags "-X main.version=1.2.3"`.
var version = "dev"

func main() {
	os.Exit(cli.NewApp(version).Run(os.Args[1:]))
}
