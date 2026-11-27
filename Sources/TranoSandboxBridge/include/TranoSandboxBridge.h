#ifndef TRANO_SANDBOX_BRIDGE_H
#define TRANO_SANDBOX_BRIDGE_H
#include <stdint.h>
#include <sys/types.h>
typedef struct {
    int32_t result;
    int32_t error;
} TranoTwinSandboxWriteResult;
TranoTwinSandboxWriteResult trano_twin_sandbox_check_write(pid_t pid, const char *path);
#endif
