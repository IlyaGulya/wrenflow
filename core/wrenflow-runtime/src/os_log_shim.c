#include <os/log.h>
#include <stdint.h>

// Rust passes an already redacted, bounded JSON record. Marking that record
// public is intentional: Console.app remains useful while private product data
// never crosses this ABI in the first place.
void wrenflow_os_log_write(
    const char *subsystem,
    const char *category,
    uint8_t level,
    const char *message
) {
    os_log_type_t type = OS_LOG_TYPE_DEFAULT;
    switch (level) {
        case 0: type = OS_LOG_TYPE_DEBUG; break;
        case 1: type = OS_LOG_TYPE_INFO; break;
        case 2: type = OS_LOG_TYPE_DEFAULT; break;
        case 3: type = OS_LOG_TYPE_ERROR; break;
        case 4: type = OS_LOG_TYPE_FAULT; break;
        default: type = OS_LOG_TYPE_DEFAULT; break;
    }

    os_log_t logger = os_log_create(subsystem, category);
    os_log_with_type(logger, type, "%{public}s", message);
    os_release(logger);
}
