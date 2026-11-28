#pragma once

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*TelarTestPromiseDoneCallback)(void* context, const char* failure_utf8);

#ifdef __cplusplus
[[tbc::raw]]
#endif
const char* telarTestPromisedName(const void* native_writers, size_t row);

#ifdef __cplusplus
[[tbc::raw]]
#endif
bool telarTestAskPromisedFile(
    const void* native_writers,
    size_t row,
    const char* path_utf8,
    TelarTestPromiseDoneCallback callback,
    void* context
);

#ifdef __cplusplus
}
#endif
