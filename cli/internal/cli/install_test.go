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
	result, err := (&Installer{fs}).Install(nil)
	if err != nil || result.Link != homeBin+"/aub" || fs.files[result.Link] != fs.exe || !fs.dirs[homeBin] {
		t.Errorf("%s %v %v", result.Link, err, fs.files)
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
	result, err := (&Installer{fs}).Install(nil)
	if err != nil || fs.files[result.Link] != fs.exe {
		t.Errorf("%v %v", err, fs.files)
	}
	if result.Replaced == nil || *result.Replaced != "/old/aub" {
		t.Errorf("replaced %v", result.Replaced)
	}
}

func TestInstallReportsNothingWhenTheLinkIsAlreadyOurs(t *testing.T) {
	fs := newFakeFS()
	prefix := "/custom/bin"
	fs.dirs[prefix], fs.writable[prefix] = true, true
	for name, dest := range map[string]string{"absolute": fs.exe, "relative": "../../opt/aub/aub"} {
		fs.files[prefix+"/aub"] = dest
		result, err := (&Installer{fs}).Install(&prefix)
		if err != nil || result.Replaced != nil {
			t.Errorf("%s: %v %v", name, err, result.Replaced)
		}
	}
}

func TestInstallPrintsTheReplacedTarget(t *testing.T) {
	h := newHarness(t)
	fs := h.Installer.FS.(*fakeFS)
	fs.dirs[homeBin], fs.writable[homeBin] = true, true
	fs.pathEnv = homeBin
	fs.files[homeBin+"/aub"] = "/Applications/AgentsUsageBar.app/Contents/MacOS/AgentsUsageBar"
	out, _, code := h.run("install")
	want := "Replaced aub → /Applications/AgentsUsageBar.app/Contents/MacOS/AgentsUsageBar\nInstalled aub → " + homeBin + "/aub\n"
	if code != 0 || out != want {
		t.Errorf("code=%d %q", code, out)
	}
	if out, _, _ = h.run("install"); out != "Installed aub → "+homeBin+"/aub\n" {
		t.Errorf("reinstall %q", out)
	}
}

func TestInstallReportsAReplacedLinkOnTheAdministratorPath(t *testing.T) {
	fs := newFakeFS()
	prefix := "/usr/local/bin"
	fs.dirs[prefix] = true
	fs.files[prefix+"/aub"] = "/old/aub"
	result, err := (&Installer{fs}).Install(&prefix)
	if err != nil || result.Replaced == nil || *result.Replaced != "/old/aub" || len(fs.scripts) != 1 {
		t.Errorf("%v %v %v", err, result.Replaced, fs.scripts)
	}
}

func TestInstallPrefix(t *testing.T) {
	fs := newFakeFS()
	prefix := "/custom/bin"
	result, err := (&Installer{fs}).Install(&prefix)
	if err != nil || result.Link != "/custom/bin/aub" || !fs.dirs[prefix] {
		t.Errorf("%s %v", result.Link, err)
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

func TestUninstallFollowsRelativeLinks(t *testing.T) {
	fs := newFakeFS()
	fs.files[homeBin+"/aub"] = "../../../../opt/aub/aub"
	fs.files["/usr/local/bin/aub"] = "aub-other"
	if err := (&Installer{fs}).Uninstall(); err != nil {
		t.Fatal(err)
	}
	if _, ok := fs.files[homeBin+"/aub"]; ok {
		t.Error("a relative link to this executable stayed")
	}
	if _, ok := fs.files["/usr/local/bin/aub"]; !ok {
		t.Error("a relative link elsewhere was removed")
	}
}

func TestInstallNeedsNoAppBundle(t *testing.T) {
	fs := newFakeFS()
	fs.exe = "/home/test/go/bin/aub"
	result, err := (&Installer{fs}).Install(nil)
	if err != nil || result.Link != homeBin+"/aub" || fs.files[result.Link] != fs.exe {
		t.Errorf("%s %v", result.Link, err)
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
