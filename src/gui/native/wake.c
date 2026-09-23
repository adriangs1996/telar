#include "telar_gui.h"
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

int telar_gui_pipe(int *fds) {
  if (pipe(fds) != 0)
    return -1;
  for (int i = 0; i < 2; i++) {
    if (fcntl(fds[i], F_SETFD, FD_CLOEXEC) == -1 ||
        fcntl(fds[i], F_SETFL, O_NONBLOCK) == -1) {
      close(fds[0]);
      close(fds[1]);
      return -1;
    }
  }
  return 0;
}

void telar_gui_wake(int fd) {
  char byte = 1;
  while (write(fd, &byte, 1) == -1 && errno == EINTR) {
  }
}

void telar_gui_drain(int fd) {
  char bytes[64];
  for (;;) {
    ssize_t count = read(fd, bytes, sizeof bytes);
    if (count > 0 || (count < 0 && errno == EINTR))
      continue;
    return;
  }
}
void telar_gui_close_pipe(int *fds) {
  close(fds[0]);
  close(fds[1]);
}
