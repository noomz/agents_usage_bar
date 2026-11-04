// Package applog is the app logger. The CLI's stdout and stderr belong to its output, so
// nothing is printed. In the Swift app these lines go to the unified log, which `aub` never
// shows either.
package applog

import "log/slog"

// Logger discards records. Log only paths and status codes: never a query, header, or body.
var Logger = slog.New(slog.DiscardHandler)
