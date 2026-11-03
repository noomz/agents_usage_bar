package cli

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
)

const binaryName = "aub"

// InstallError is a failed install. It exits with code 1.
type InstallError string

func (e InstallError) Error() string { return string(e) }

const (
	errAuthorizationCancelled InstallError = "administrator authorization cancelled"
	errNoWritableDestination  InstallError = "no writable bin directory found"
)

// FileSystem is the installer's seam.
type FileSystem interface {
	HomeDirectory() string
	ExecutablePath() string
	PathEnvironment() string
	DirectoryExists(path string) bool
	IsWritableDirectory(path string) bool
	FileExists(path string) bool
	IsSymlink(path string) bool
	SymlinkDestination(path string) (string, error)
	CreateDirectory(path string) error
	CreateSymlink(path, destination string) error
	RemoveItem(path string) error
	RunPrivileged(script string) error
}

// Installer symlinks this executable into a bin directory.
type Installer struct {
	FS FileSystem
}

func (i *Installer) defaultDirectory() string {
	return filepath.Join(i.FS.HomeDirectory(), ".local", "bin")
}

const homebrewDirectory = "/opt/homebrew/bin"

// candidateDirectories are the known bin directories this tool may have written.
func (i *Installer) candidateDirectories() []string {
	return []string{i.defaultDirectory(), homebrewDirectory, "/usr/local/bin"}
}

func (i *Installer) isOnPath(directory string) bool {
	for _, dir := range strings.Split(i.FS.PathEnvironment(), ":") {
		if dir == directory {
			return true
		}
	}
	return false
}

// PathHint is a shell snippet when directory is missing from PATH.
func (i *Installer) PathHint(directory string) *string {
	if i.isOnPath(directory) {
		return nil
	}
	var hint string
	switch directory {
	case i.defaultDirectory():
		hint = `Not on PATH. fish: fish_add_path ~/.local/bin   zsh/bash: export PATH="$HOME/.local/bin:$PATH"`
	case homebrewDirectory:
		hint = `Not on PATH. Add Homebrew to your shell: eval "$(/opt/homebrew/bin/brew shellenv)"`
	default:
		hint = "Not on PATH. Add " + directory + " to PATH in your shell profile."
	}
	return &hint
}

// InstallResult is where the link went. Replaced is the old target of a symlink that pointed at
// something other than this executable, nil when nothing foreign was replaced.
type InstallResult struct {
	Link     string
	Replaced *string
}

// foreignTarget is the link's target when the link exists and points somewhere else.
func (i *Installer) foreignTarget(link, exe string) *string {
	if !i.FS.IsSymlink(link) {
		return nil
	}
	dest, err := i.FS.SymlinkDestination(link)
	if err != nil || filepath.Clean(absoluteFrom(filepath.Dir(link), dest)) == filepath.Clean(exe) {
		return nil
	}
	return &dest
}

func absoluteFrom(dir, dest string) string {
	if filepath.IsAbs(dest) {
		return dest
	}
	return filepath.Join(dir, dest)
}

// Install links into prefix, or the default directory, replacing any symlink there. A regular
// file stops a direct install. The administrator path uses `ln -sf`, which replaces one, as Swift
// does.
func (i *Installer) Install(prefix *string) (InstallResult, error) {
	exe := i.FS.ExecutablePath()
	dir := i.defaultDirectory()
	if prefix != nil {
		dir = *prefix
	}
	if err := i.Uninstall(); err != nil {
		return InstallResult{}, err
	}
	link := filepath.Join(dir, binaryName)
	result := InstallResult{Link: link, Replaced: i.foreignTarget(link, exe)}
	if !i.FS.DirectoryExists(dir) {
		if err := i.FS.CreateDirectory(dir); err != nil {
			return result, i.installPrivileged(dir, exe)
		}
	}
	if !i.FS.IsWritableDirectory(dir) {
		return result, i.installPrivileged(dir, exe)
	}
	if i.FS.FileExists(link) || i.FS.IsSymlink(link) {
		if !i.FS.IsSymlink(link) {
			return InstallResult{}, InstallError("refusing to clobber regular file: " + link)
		}
		if err := i.FS.RemoveItem(link); err != nil {
			return InstallResult{}, err
		}
	}
	return result, i.FS.CreateSymlink(link, exe)
}

// Uninstall removes links in the known directories that point at this executable.
func (i *Installer) Uninstall() error {
	exe := i.FS.ExecutablePath()
	for _, dir := range i.candidateDirectories() {
		link := filepath.Join(dir, binaryName)
		if !i.FS.IsSymlink(link) {
			continue
		}
		dest, err := i.FS.SymlinkDestination(link)
		if err != nil {
			continue
		}
		if filepath.Clean(absoluteFrom(dir, dest)) == filepath.Clean(exe) {
			if err := i.FS.RemoveItem(link); err != nil {
				return err
			}
		}
	}
	return nil
}

func (i *Installer) installPrivileged(directory, destination string) error {
	script := strings.Join([]string{
		"set -eu",
		"/bin/mkdir -p " + shellEscape(directory),
		"/bin/ln -sf " + shellEscape(destination) + " " + shellEscape(filepath.Join(directory, binaryName)),
	}, "\n")
	return i.FS.RunPrivileged(script)
}

func shellEscape(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func dirOf(path string) string { return filepath.Dir(path) }

// SystemFS is the real file system.
type SystemFS struct{}

func (SystemFS) HomeDirectory() string {
	home, _ := os.UserHomeDir()
	return home
}

// ExecutablePath is this binary with symlinks resolved.
func (SystemFS) ExecutablePath() string {
	exe, err := os.Executable()
	if err != nil {
		return os.Args[0]
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		return resolved
	}
	return exe
}

func (SystemFS) PathEnvironment() string { return os.Getenv("PATH") }

func (SystemFS) DirectoryExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func (SystemFS) IsWritableDirectory(path string) bool {
	return syscall.Access(path, 2) == nil
}

// A dangling symlink does not exist.
func (SystemFS) FileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func (SystemFS) IsSymlink(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && info.Mode()&os.ModeSymlink != 0
}

func (SystemFS) SymlinkDestination(path string) (string, error) { return os.Readlink(path) }

func (SystemFS) CreateDirectory(path string) error { return os.MkdirAll(path, 0o700) }

func (SystemFS) CreateSymlink(path, destination string) error { return os.Symlink(destination, path) }

func (SystemFS) RemoveItem(path string) error { return os.Remove(path) }

// RunPrivileged is an administrator prompt on macOS. Elsewhere there is no
// system prompt to use, so the caller is told to pick a writable --prefix.
func (SystemFS) RunPrivileged(script string) error {
	if runtime.GOOS != "darwin" {
		return errNoWritableDestination
	}
	escaped := strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(script)
	cmd := exec.Command("/usr/bin/osascript", "-e", `do shell script "`+escaped+`" with administrator privileges`)
	var exitErr *exec.ExitError
	if err := cmd.Run(); errors.As(err, &exitErr) {
		return errAuthorizationCancelled
	} else if err != nil {
		return err
	}
	return nil
}
