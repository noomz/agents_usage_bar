//go:build darwin

package provider

import (
	"bytes"
	"syscall"
	"unsafe"
)

// xnu's proc_info and sysctl numbers, called directly because the binary builds without cgo.
const (
	procInfoCallListPIDs = 1
	procInfoCallPIDInfo  = 2
	procAllPIDs          = 1
	procPIDPathInfo      = 11
	procPathMax          = 4096
	ctlKern              = 1
	kernProcArgs2        = 49
)

func osProcesses() []RunningProcess {
	var out []RunningProcess
	for _, pid := range listPIDs() {
		path := pidPath(pid)
		if path == "" {
			continue
		}
		out = append(out, RunningProcess{PID: int(pid), ExecutablePath: path, Arguments: parseProcArgs(procArgs(pid))})
	}
	return out
}

func procInfo(call, pid, flavor uintptr, buf unsafe.Pointer, size int) int {
	n, _, errno := syscall.Syscall6(syscall.SYS_PROC_INFO, call, pid, flavor, 0, uintptr(buf), uintptr(size))
	if errno != 0 {
		return 0
	}
	return int(n)
}

func listPIDs() []int32 {
	estimate := procInfo(procInfoCallListPIDs, procAllPIDs, 0, nil, 0)
	if estimate <= 0 {
		return nil
	}
	// Room for processes started between the two calls.
	pids := make([]int32, estimate/4+64)
	filled := procInfo(procInfoCallListPIDs, procAllPIDs, 0, unsafe.Pointer(&pids[0]), len(pids)*4)
	var out []int32
	for _, pid := range pids[:filled/4] {
		if pid > 0 {
			out = append(out, pid)
		}
	}
	return out
}

func pidPath(pid int32) string {
	buf := make([]byte, procPathMax)
	procInfo(procInfoCallPIDInfo, uintptr(pid), procPIDPathInfo, unsafe.Pointer(&buf[0]), len(buf))
	return string(buf[:max(bytes.IndexByte(buf, 0), 0)])
}

// procArgs is empty on a permission miss.
func procArgs(pid int32) []byte {
	mib := [3]int32{ctlKern, kernProcArgs2, pid}
	sysctl := func(buf unsafe.Pointer, size *uintptr) bool {
		_, _, errno := syscall.Syscall6(syscall.SYS___SYSCTL, uintptr(unsafe.Pointer(&mib[0])), 3, uintptr(buf), uintptr(unsafe.Pointer(size)), 0, 0)
		return errno == 0
	}
	var size uintptr
	if !sysctl(nil, &size) || size == 0 {
		return nil
	}
	buf := make([]byte, size)
	if !sysctl(unsafe.Pointer(&buf[0]), &size) {
		return nil
	}
	return buf[:size]
}
