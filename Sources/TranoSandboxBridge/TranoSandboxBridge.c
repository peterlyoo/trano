#include "TranoSandboxBridge.h"
#include <errno.h>
#include <string.h>
#if defined(__APPLE__)
#include <dlfcn.h>
#endif

TranoTwinSandboxWriteResult trano_twin_sandbox_check_write(pid_t pid, const char *path) {
    if (pid <= 1 || path == NULL || path[0] != '/' || strnlen(path, 4097) > 4096) {
        return (TranoTwinSandboxWriteResult){-1, EINVAL};
    }
#if defined(__APPLE__)
    void *library = dlopen("/usr/lib/libsandbox.1.dylib", RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) { return (TranoTwinSandboxWriteResult){-1, ENOSYS}; }
    typedef int (*SandboxCheck)(pid_t, const char *, int, ...);
    SandboxCheck check = (SandboxCheck)dlsym(library, "sandbox_check");
    const int *no_report = (const int *)dlsym(library, "SANDBOX_CHECK_NO_REPORT");
    if (check == NULL || no_report == NULL || *no_report <= 0 || (*no_report & 0xff) != 0) {
        dlclose(library);
        return (TranoTwinSandboxWriteResult){-1, ENOSYS};
    }
    errno = 0;
    // C preserves the arm64 variadic ABI required by the system sandbox SPI.
    int result = check(pid, "file-write-data", 1 | *no_report, path);
    int error = errno;
    dlclose(library);
    if (error != 0) { return (TranoTwinSandboxWriteResult){-1, error}; }
    if (result != 0 && result != 1) { return (TranoTwinSandboxWriteResult){-1, EPROTO}; }
    return (TranoTwinSandboxWriteResult){result, 0};
#else
    return (TranoTwinSandboxWriteResult){-1, ENOSYS};
#endif
}
