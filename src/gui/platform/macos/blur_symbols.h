#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef __cplusplus
using TelarGuiBlurConnection = void *(*)();
#else
typedef void *(*TelarGuiBlurConnection)(void);
#endif
typedef int32_t (*TelarGuiBlurSetRadius)(void *, size_t, int);

typedef struct {
  TelarGuiBlurConnection connection;
  TelarGuiBlurSetRadius set_radius;
} TelarGuiBlurSymbols;

TelarGuiBlurSymbols telarGuiBlurSymbols(void);

#ifdef __cplusplus
}
#endif
