#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TelarGuiClipboardImagePipe {
  int read_descriptor;
  int write_descriptor;
} TelarGuiClipboardImagePipe;

#ifdef __cplusplus
[[tbc::raw]]
#endif
int telarGuiOpenClipboardImagePipe(TelarGuiClipboardImagePipe* pipe);

#ifdef __cplusplus
[[tbc::raw]]
#endif
int telarGuiOpenClipboardImageFile(const char* path);

#ifdef __cplusplus
}
#endif
