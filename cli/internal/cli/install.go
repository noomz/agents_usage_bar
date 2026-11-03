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

// The install failures.
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

// Install links into prefix, or the default directory, replacing links this tool owns.
func (i *Installer) Install(prefix *string) (string, error) {
	exe := i.FS.ExecutablePath()
	dir := i.defaultDirectory()
	if prefix != nil {
		dir = *prefix
	}
	if err := i.Uninstall(); err != nil {
		return "", err
	}
	link := filepath.Join(dir, binaryName)
	if !i.FS.DirectoryExists(dir) {
		if err := i.FS.CreateDirectory(dir); err != nil {
			return link, i.installPrivileged(dir, exe)
		}
	}
	if !i.FS.IsWritableDirectory(dir) {
		return link, i.installPrivileged(dir, exe)
	}
	if i.FS.FileExists(link) || i.FS.IsSymlink(link) {
		if !i.FS.IsSymlink(link) {
			return "", InstallError("refusing to clobber regular file: " + link)
		}
		if err := i.FS.RemoveItem(link); err != nil {
			return "", err
		}
	}
	return link, i.FS.CreateSymlink(link, exe)
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
		if !filepath.IsAbs(dest) {
			dest = filepath.Join(dir, dest)
		}
		if filepath.Clean(dest) == filepath.Clean(exe) {
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

// HomeDirectory implements FileSystem.
func (SystemFS) HomeDirectory() string {
	home, _ := os.UserHomeDir()
	return home
}

// ExecutablePath implements FileSystem: this binary with symlinks resolved.
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

// PathEnvironment implements FileSystem.
func (SystemFS) PathEnvironment() string { return os.Getenv("PATH") }

// DirectoryExists implements FileSystem.
func (SystemFS) DirectoryExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

// IsWritableDirectory implements FileSystem.
func (SystemFS) IsWritableDirectory(path string) bool {
	return syscall.Access(path, 2) == nil
}

// FileExists implements FileSystem. A dangling symlink does not exist.
func (SystemFS) FileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// IsSymlink implements FileSystem.
func (SystemFS) IsSymlink(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && info.Mode()&os.ModeSymlink != 0
}

// SymlinkDestination implements FileSystem.
func (SystemFS) SymlinkDestination(path string) (string, error) { return os.Readlink(path) }

// CreateDirectory implements FileSystem.
func (SystemFS) CreateDirectory(path string) error { return os.MkdirAll(path, 0o700) }

// CreateSymlink implements FileSystem.
func (SystemFS) CreateSymlink(path, destination string) error { return os.Symlink(destination, path) }

// RemoveItem implements FileSystem.
func (SystemFS) RemoveItem(path string) error { return os.Remove(path) }

// RunPrivileged implements FileSystem: an administrator prompt on macOS. Elsewhere there is no
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
