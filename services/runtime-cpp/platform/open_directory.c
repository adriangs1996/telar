#include "open_directory.h"
#include <fcntl.h>

int telarOpenDirectoryNoFollow(const char *path) {
  return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
}
