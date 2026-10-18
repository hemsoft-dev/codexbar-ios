#include "ProClockSupport.h"
#include <sys/mman.h>

// Swift cannot call Darwin's variadic shm_open directly. Preserve its C ABI here.
int codexbar_pro_shm_open(const char *name, int flags, mode_t mode) {
    return shm_open(name, flags, mode);
}
