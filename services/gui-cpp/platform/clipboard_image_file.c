#include "clipboard_image_file.h"
#include <fcntl.h>

int telarGuiOpenClipboardImageFile(const char *path) {
  return open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
}
