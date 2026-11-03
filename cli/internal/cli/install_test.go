package cli

import (
	"errors"
	"strings"
	"testing"
)

type fakeFS struct {
	exe, pathEnv string
	dirs         map[string]bool
	writable     map[string]bool
	files        map[string]string
	scripts      []string
	deny         bool
}

func newFakeFS() *fakeFS {
	return &fakeFS{exe: "/opt/aub/aub", pathEnv: "/usr/bin", dirs: map[string]bool{}, writable: map[string]bool{}, files: map[string]string{}}
}

func (f *fakeFS) HomeDirectory() string             { return "/home/test" }
func (f *fakeFS) ExecutablePath() string            { return f.exe }
func (f *fakeFS) PathEnvironment() string           { return f.pathEnv }
func (f *fakeFS) DirectoryExists(p string) bool     { return f.dirs[p] }
func (f *fakeFS) IsWritableDirectory(p string) bool { return f.writable[p] }
func (f *fakeFS) FileExists(p string) bool          { _, ok := f.files[p]; return ok }
func (f *fakeFS) IsSymlink(p string) bool           { return f.files[p] != "" }
func (f *fakeFS) SymlinkDestination(p string) (string, error) {
	if f.files[p] == "" {
		return "", errors.New("not a symlink")
	}
	return f.files[p], nil
}
func (f *fakeFS) CreateDirectory(p string) error  { f.dirs[p], f.writable[p] = true, true; return nil }
func (f *fakeFS) CreateSymlink(p, d string) error { f.files[p] = d; return nil }
func (f *fakeFS) RemoveItem(p string) error       { delete(f.files, p); return nil }
func (f *fakeFS) RunPrivileged(s string) error {
	if f.deny {
		return errAuthorizationCancelled
	}
	f.scripts = append(f.scripts, s)
	return nil
}

const homeBin = "/home/test/.local/bin"

func TestInstallDefaultsToLocalBin(t *testing.T) {
	fs := newFakeFS()
	fs.dirs["/opt/homebrew/bin"], fs.writable["/opt/homebrew/bin"] = true, true
	path, err := (&Installer{fs}).Install(nil)
	if err != nil || path != homeBin+"/aub" || fs.files[path] != fs.exe || !fs.dirs[homeBin] {
		t.Errorf("%s %v %v", path, err, fs.files)
	}
	if _, ok := fs.files["/opt/homebrew/bin/aub"]; ok {
		t.Error("wrote Homebrew")
	}
}

func TestInstallRefusesRegularFile(t *testing.T) {
	fs := newFakeFS()
	fs.dirs[homeBin], fs.writable[homeBin] = true, true
	fs.files[homeBin+"/aub"] = ""
	_, err := (&Installer{fs}).Install(nil)
	if err == nil || err.Error() != "refusing to clobber regular file: "+homeBin+"/aub" {
		t.Errorf("%v", err)
	}
}

func TestInstallReplacesExistingSymlink(t *testing.T) {
	fs := newFakeFS()
	fs.dirs[homeBin], fs.writable[homeBin] = true, true
	fs.files[homeBin+"/aub"] = "/old/aub"
	path, err := (&Installer{fs}).Install(nil)
	if err != nil || fs.files[path] != fs.exe {
		t.Errorf("%v %v", err, fs.files)
	}
}

func TestInstallPrefix(t *testing.T) {
	fs := newFakeFS()
	prefix := "/custom/bin"
	path, err := (&Installer{fs}).Install(&prefix)
	if err != nil || path != "/custom/bin/aub" || !fs.dirs[prefix] {
		t.Errorf("%s %v", path, err)
	}
}

func TestUninstallRemovesOnlyOurLinks(t *testing.T) {
	fs := newFakeFS()
	fs.files["/opt/homebrew/bin/aub"] = fs.exe
	fs.files["/usr/local/bin/aub"] = "/someone/else"
	if err := (&Installer{fs}).Uninstall(); err != nil {
		t.Fatal(err)
	}
	if _, ok := fs.files["/opt/homebrew/bin/aub"]; ok {
		t.Error("ours stayed")
	}
	if fs.files["/usr/local/bin/aub"] != "/someone/else" {
		t.Error("theirs was removed")
	}
}

func TestAdminFallback(t *testing.T) {
	fs := newFakeFS()
	fs.dirs["/usr/local/bin"] = true
	prefix := "/usr/local/bin"
	if _, err := (&Installer{fs}).Install(&prefix); err != nil {
		t.Fatal(err)
	}
	if len(fs.scripts) != 1 || !strings.Contains(fs.scripts[0], "/usr/local/bin") || !strings.Contains(fs.scripts[0], "ln -sf") {
		t.Errorf("%v", fs.scripts)
	}
	fs.deny = true
	_, err := (&Installer{fs}).Install(&prefix)
	if !errors.Is(err, errAuthorizationCancelled) || err.Error() != "administrator authorization cancelled" {
		t.Errorf("%v", err)
	}
}

func TestPathHint(t *testing.T) {
	fs := newFakeFS()
	fs.pathEnv = "/usr/bin:/bin"
	in := &Installer{fs}
	if h := in.PathHint(homeBin); h == nil || !strings.Contains(*h, "fish_add_path") {
		t.Errorf("%v", h)
	}
	if h := in.PathHint("/usr/bin"); h != nil {
		t.Errorf("%s", *h)
	}
	if h := in.PathHint("/opt/homebrew/bin"); h == nil || !strings.Contains(*h, "brew shellenv") {
		t.Errorf("%v", h)
	}
	if h := in.PathHint("/x"); h == nil || *h != "Not on PATH. Add /x to PATH in your shell profile." {
		t.Errorf("%v", h)
	}
}
