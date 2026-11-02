#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TelarGuiClipboardImagePipe {
  int read_descriptor;
  int write_descriptor;
} TelarGuiClipboardImagePipe;

int telarGuiOpenClipboardImagePipe(TelarGuiClipboardImagePipe *pipe);
int telarGuiOpenClipboardImageFile(const char *path);

#ifdef __cplusplus
}
#endif
