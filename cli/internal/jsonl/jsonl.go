// Package jsonl reads append-only transcript files incrementally by byte offset.
package jsonl

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

// Delta is the result of one incremental read.
type Delta struct {
	// Lines holds each complete line at or past the start offset, without its newline. A line
	// that is not valid UTF-8 is skipped but still consumed.
	Lines [][]byte
	// NewOffset is the position after the last complete line. A trailing partial line is not
	// consumed, so the next read sees it again in full.
	NewOffset uint64
	// LastModified is the file's mtime at this read. Persist it with NewOffset.
	LastModified time.Time
}

// ReadDelta reads from startOffset to the end of the file. A file whose mtime went backwards or
// that is now shorter than the offset was truncated or replaced, so it is read from the start.
func ReadDelta(path string, startOffset uint64, previousModified *time.Time) (Delta, error) {
	info, err := os.Stat(path)
	if err != nil {
		return Delta{}, err
	}
	start := startOffset
	// A persisted mtime is a Foundation double, coarser than the filesystem's nanoseconds, so
	// compare at that precision or an unchanged file reads as replaced.
	if previousModified != nil && domain.RefSeconds(info.ModTime()) < domain.RefSeconds(*previousModified) {
		start = 0
	}
	if start > uint64(info.Size()) {
		start = 0
	}
	f, err := os.Open(path)
	if err != nil {
		return Delta{}, err
	}
	defer f.Close()
	if _, err := f.Seek(int64(start), io.SeekStart); err != nil {
		return Delta{}, err
	}
	data, err := io.ReadAll(f)
	if err != nil {
		return Delta{}, err
	}
	var lines [][]byte
	consumed := uint64(0)
	for {
		i := bytes.IndexByte(data, '\n')
		if i < 0 {
			break
		}
		if utf8.Valid(data[:i]) {
			lines = append(lines, data[:i])
		}
		consumed += uint64(i) + 1
		data = data[i+1:]
	}
	return Delta{Lines: lines, NewOffset: start + consumed, LastModified: info.ModTime()}, nil
}

// FileURL is Foundation's URL(fileURLWithPath:).absoluteString, the key of every stored cursor.
// A different encoding would miss the cursor and count the whole file again.
func FileURL(path string) string {
	const allowed = "-._~!$&'()*+,;=:@/"
	var b strings.Builder
	b.WriteString("file://")
	for i := 0; i < len(path); i++ {
		c := path[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', strings.IndexByte(allowed, c) >= 0:
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

// ScanRoots returns `*.jsonl` regular files under roots, with symlinks resolved so cache keys
// are canonical. Hidden files and directories are skipped. A non-nil since keeps only files
// modified after it. Missing roots are skipped.
func ScanRoots(roots []string, since *time.Time) []string {
	var results []string
	for _, root := range roots {
		resolved, err := filepath.EvalSymlinks(root)
		if err != nil {
			continue
		}
		_ = filepath.WalkDir(resolved, func(path string, d os.DirEntry, err error) error {
			if err != nil {
				if d != nil && d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			hidden := strings.HasPrefix(d.Name(), ".") && path != resolved
			if d.IsDir() {
				if hidden {
					return filepath.SkipDir
				}
				return nil
			}
			if hidden || filepath.Ext(path) != ".jsonl" {
				return nil
			}
			info, err := os.Stat(path)
			if err != nil || !info.Mode().IsRegular() {
				return nil
			}
			if since != nil && !info.ModTime().After(*since) {
				return nil
			}
			if real, err := filepath.EvalSymlinks(path); err == nil {
				results = append(results, real)
			}
			return nil
		})
	}
	return results
}
