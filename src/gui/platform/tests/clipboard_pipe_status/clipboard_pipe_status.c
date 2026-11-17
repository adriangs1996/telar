#include "clipboard_pipe_status.h"
#include <fcntl.h>

int telarGuiTestClipboardPipeHasReceiveFlags(int descriptor) {
  const int mode = fcntl(descriptor, F_GETFL);
  const int flags = fcntl(descriptor, F_GETFD);

  return mode >= 0 && flags >= 0 && ((unsigned)mode & (unsigned)O_NONBLOCK) != 0 && ((unsigned)flags & (unsigned)FD_CLOEXEC) != 0;
}

int telarGuiTestClipboardDescriptorOpen(int descriptor) {
  return fcntl(descriptor, F_GETFD) >= 0;
}
