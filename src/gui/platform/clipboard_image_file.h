#pragma once

#ifdef __cplusplus
#include "tbc/annotations.hpp"
#define TELAR_GUI_CLIPBOARD_RAW TBC_RAW
#else
#define TELAR_GUI_CLIPBOARD_RAW
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TelarGuiClipboardImagePipe {
  int read_descriptor;
  int write_descriptor;
} TelarGuiClipboardImagePipe;

int telarGuiOpenClipboardImagePipe(TelarGuiClipboardImagePipe* pipe);
TELAR_GUI_CLIPBOARD_RAW int telarGuiOpenClipboardImageFile(const char* path);

#ifdef __cplusplus
}
#endif

#undef TELAR_GUI_CLIPBOARD_RAW
