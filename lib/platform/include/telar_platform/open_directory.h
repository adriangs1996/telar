#ifndef TELAR_RUNTIME_OPEN_DIRECTORY_H
#define TELAR_RUNTIME_OPEN_DIRECTORY_H

#ifdef __cplusplus
#include "tbc/annotations.hpp"

extern "C" {
#endif

#ifdef __cplusplus
TBC_RAW
#endif
int telarOpenDirectoryNoFollow(const char* path);

#ifdef __cplusplus
}
#endif

#endif
