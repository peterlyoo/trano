package main

import (
	"os"
	"path/filepath"
	"strings"
)

func (r *Runtime) shellIntegration(shell string) ([]string, []string, error) {
	if r.helper == "" {
		return nil, []string{"-l"}, nil
	}
	dir, bin := filepath.Join(r.root, "shell"), filepath.Join(r.root, "bin")
	for _, path := range []string{dir, bin} {
		if err := ownedDirectory(path); err != nil {
			return nil, nil, err
		}
	}
	for _, provider := range []string{"claude", "codex"} {
		path := filepath.Join(bin, provider)
		if err := atomicWrite(path, []byte("#!/bin/sh\nexec \"$TRANO_REMOTE_HELPER\" agent "+provider+" \"$@\"\n")); err != nil {
			return nil, nil, err
		}
		if err := os.Chmod(path, 0700); err != nil {
			return nil, nil, err
		}
	}
	env := []string{"TRANO_REMOTE_HELPER=" + r.helper, "TRANO_SHIM_DIR=" + bin, "PATH=" + bin + ":" + os.Getenv("PATH")}
	switch filepath.Base(shell) {
	case "zsh":
		for _, name := range []string{".zshenv", ".zprofile", ".zshrc", ".zlogin"} {
			text := "if [[ \"$TRANO_ZDOTDIR_PRESENT\" == 1 ]]; then export ZDOTDIR=\"$TRANO_ZDOTDIR_VALUE\"; else unset ZDOTDIR; fi\n[[ -r \"${ZDOTDIR:-$HOME}/" + name + "\" ]] && source \"${ZDOTDIR:-$HOME}/" + name + "\"\n"
			if name != ".zlogin" {
				text += "if (( ${+ZDOTDIR} )); then export TRANO_ZDOTDIR_PRESENT=1 TRANO_ZDOTDIR_VALUE=\"$ZDOTDIR\"; else export TRANO_ZDOTDIR_PRESENT=0 TRANO_ZDOTDIR_VALUE=''; fi\nexport ZDOTDIR=\"$TRANO_SHELL_DIR\"\n"
			}
			if name == ".zshrc" || name == ".zlogin" {
				text += "export PATH=\"$TRANO_SHIM_DIR:$PATH\"\n"
			}
			if name == ".zshrc" {
				text += "_trano_cwd() { if [[ \"$PWD\" != \"${TRANO_LAST_CWD:-}\" ]]; then \"$TRANO_REMOTE_HELPER\" cwd \"$TRANO_SESSION\" \"$PWD\" >/dev/null 2>&1; TRANO_LAST_CWD=\"$PWD\"; fi }\nautoload -Uz add-zsh-hook\nadd-zsh-hook precmd _trano_cwd\n"
			}
			if err := atomicWrite(filepath.Join(dir, name), []byte(text)); err != nil {
				return nil, nil, err
			}
		}
		original, present := os.LookupEnv("ZDOTDIR")
		flag := "0"
		if present {
			flag = "1"
		}
		env = append(env, "ZDOTDIR="+dir, "TRANO_SHELL_DIR="+dir, "TRANO_ZDOTDIR_PRESENT="+flag, "TRANO_ZDOTDIR_VALUE="+original)
		return env, []string{"-l"}, nil
	case "bash":
		text := "if [ -r /etc/profile ]; then . /etc/profile; fi\nfor p in \"$HOME/.bash_profile\" \"$HOME/.bash_login\" \"$HOME/.profile\"; do if [ -r \"$p\" ]; then . \"$p\"; break; fi; done\n[ ! -r \"$HOME/.bashrc\" ] || . \"$HOME/.bashrc\"\nexport PATH=\"$TRANO_SHIM_DIR:$PATH\"\n_trano_cwd() { if [ \"$PWD\" != \"${TRANO_LAST_CWD:-}\" ]; then \"$TRANO_REMOTE_HELPER\" cwd \"$TRANO_SESSION\" \"$PWD\" >/dev/null 2>&1; TRANO_LAST_CWD=\"$PWD\"; fi; }\nif [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then PROMPT_COMMAND+=(_trano_cwd); else PROMPT_COMMAND=\"${PROMPT_COMMAND:+$PROMPT_COMMAND;} _trano_cwd\"; fi\n"
		path := filepath.Join(dir, "bashrc")
		if err := atomicWrite(path, []byte(text)); err != nil {
			return nil, nil, err
		}
		return env, []string{"--rcfile", path, "-i"}, nil
	default:
		path := filepath.Join(dir, "shrc")
		text := "[ -z \"$TRANO_ORIGINAL_ENV\" ] || [ ! -r \"$TRANO_ORIGINAL_ENV\" ] || . \"$TRANO_ORIGINAL_ENV\"\nexport PATH=\"$TRANO_SHIM_DIR:$PATH\"\n"
		if err := atomicWrite(path, []byte(text)); err != nil {
			return nil, nil, err
		}
		env = append(env, "ENV="+path, "TRANO_ORIGINAL_ENV="+os.Getenv("ENV"))
		return env, []string{"-l"}, nil
	}
}
func withoutShimPath(path, shim string) string {
	result := []string{}
	for _, part := range filepath.SplitList(path) {
		if filepath.Clean(part) != filepath.Clean(shim) {
			result = append(result, part)
		}
	}
	return strings.Join(result, string(os.PathListSeparator))
}
