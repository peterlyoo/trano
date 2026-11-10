package main

import (
	"errors"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"unsafe"
)

func normalAgentExit(err error) bool {
	if err == nil {
		return true
	}
	var exit *exec.ExitError
	if !errors.As(err, &exit) {
		return false
	}
	status, ok := exit.Sys().(syscall.WaitStatus)
	return ok && (status.Signaled() && status.Signal() == syscall.SIGINT || status.Exited() && status.ExitStatus() == 128+int(syscall.SIGINT))
}

func terminalGroup(fd uintptr) (int, error) {
	var group int32
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCGPGRP, uintptr(unsafe.Pointer(&group)))
	if errno != 0 {
		return 0, errno
	}
	return int(group), nil
}

func setTerminalGroup(fd uintptr, group int) error {
	pgrp := int32(group)
	// The waiting wrapper is in the background when it reclaims the terminal.
	ignored := signal.Ignored(syscall.SIGTTOU)
	signal.Ignore(syscall.SIGTTOU)
	defer func() {
		if !ignored {
			signal.Reset(syscall.SIGTTOU)
		}
	}()
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCSPGRP, uintptr(unsafe.Pointer(&pgrp)))
	if errno != 0 {
		return errno
	}
	return nil
}

func handoffAgentTerminal(input *os.File, providerPID int) (func() error, error) {
	noop := func() error { return nil }
	group, err := terminalGroup(input.Fd())
	if errors.Is(err, syscall.ENOTTY) || errors.Is(err, syscall.ENODEV) {
		return noop, nil
	}
	if err != nil {
		return noop, err
	}
	if group != syscall.Getpgrp() {
		return noop, nil
	}
	if err := setTerminalGroup(input.Fd(), providerPID); err != nil {
		return noop, err
	}
	return func() error { return setTerminalGroup(input.Fd(), group) }, nil
}
