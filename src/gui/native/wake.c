#include "telar_gui.h"
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>

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
        if (count > 0 || (count < 0 && errno == EINTR)) continue;
        return;
    }
}
void telar_gui_close_pipe(int *fds) {
  close(fds[0]);
  close(fds[1]);
}

void telar_gui_local_time(uint16_t *output) {
    time_t now = time(NULL);
    struct tm value;
    if (localtime_r(&now, &value) == NULL) {
        for (int i = 0; i < 7; i++) output[i] = 0;
        return;
    }
    output[0] = (uint16_t)(value.tm_year + 1900);
    output[1] = (uint16_t)(value.tm_mon + 1);
    output[2] = (uint16_t)value.tm_mday;
    output[3] = (uint16_t)value.tm_hour;
    output[4] = (uint16_t)value.tm_min;
    output[5] = (uint16_t)value.tm_sec;
    output[6] = (uint16_t)value.tm_wday;
}
