#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include "clipboard_image_file.h"
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

int telarGuiOpenClipboardImageFile(const char *path) {
  return open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
}

int telarGuiOpenClipboardImagePipe(TelarGuiClipboardImagePipe *pipe_result) {
  enum { read_end, write_end, descriptor_count };
  int descriptors[descriptor_count];
  pipe_result->read_descriptor = -1;
  pipe_result->write_descriptor = -1;
#ifdef __linux__
  if (pipe2(descriptors, O_CLOEXEC) != 0) {
    return -1;
  }
#else
  if (pipe(descriptors) != 0) {
    return -1;
  }

  if (fcntl(descriptors[read_end], F_SETFD, FD_CLOEXEC) != 0 || fcntl(descriptors[write_end], F_SETFD, FD_CLOEXEC) != 0) {
    const int failure = errno;
    close(descriptors[read_end]);
    close(descriptors[write_end]);
    errno = failure;

    return -1;
  }
#endif

  if (fcntl(descriptors[read_end], F_SETFL, O_NONBLOCK) != 0) {
    const int failure = errno;
    close(descriptors[read_end]);
    close(descriptors[write_end]);
    errno = failure;

    return -1;
  }

  pipe_result->read_descriptor = descriptors[read_end];
  pipe_result->write_descriptor = descriptors[write_end];

  return 0;
}
