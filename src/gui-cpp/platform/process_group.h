#ifndef TELAR_GUI_PROCESS_GROUP_H
#define TELAR_GUI_PROCESS_GROUP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void telarSignalProcessGroup(int64_t process, int force);

#ifdef __cplusplus
}
#endif

#endif
