//go:build !darwin

package provider

func osProcesses() []RunningProcess { return procProcesses("/proc") }
