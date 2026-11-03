// Package history is the read-only view of `history/`. It never creates the directory,
// writes, prunes, migrates, or reads `.account-salt`. The app renames whole files into place,
// so a read sees an old file or a new one, never a partial one.
package history

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

var dayFileName = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}\.json$`)

// Reader reads one history directory.
type Reader struct {
	Dir string
}

// ListError is a directory that exists but cannot be listed. Its text is the app's message.
type ListError struct {
	message string
}

func (e ListError) Error() string { return e.message }

// DayKeys lists day keys with a file on disk, oldest first. A missing directory is empty.
func (r Reader) DayKeys() ([]string, error) {
	entries, err := os.ReadDir(r.Dir)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil
		}
		name := filepath.Base(r.Dir)
		if errors.Is(err, fs.ErrPermission) {
			return nil, ListError{"The file “" + name + "” couldn’t be opened because you don’t have permission to view it."}
		}
		return nil, ListError{"The file “" + name + "” couldn’t be opened."}
	}
	var keys []string
	for _, e := range entries {
		if dayFileName.MatchString(e.Name()) {
			keys = append(keys, strings.TrimSuffix(e.Name(), ".json"))
		}
	}
	sort.Strings(keys)
	return keys, nil
}

// Days returns every readable day file with first <= key <= last, oldest first. Files that
// are newer, unknown, or unreadable are skipped and left untouched.
func (r Reader) Days(first, last string) ([]domain.DayFile, error) {
	keys, err := r.DayKeys()
	if err != nil {
		return nil, err
	}
	var days []domain.DayFile
	for _, key := range keys {
		if key < first || key > last {
			continue
		}
		if day := r.Day(key); day != nil {
			days = append(days, *day)
		}
	}
	return days, nil
}

// Day returns the file for a key, nil when it is missing or skipped.
func (r Reader) Day(key string) *domain.DayFile {
	data, err := os.ReadFile(filepath.Join(r.Dir, key+".json"))
	if err != nil {
		return nil
	}
	result := domain.DecodeDayFile(data)
	if result.File == nil || result.File.Date != key {
		return nil
	}
	return result.File
}
