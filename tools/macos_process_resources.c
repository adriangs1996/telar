#include "macos_process_resources_json.h"
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

enum ExitCode {
  usage_error = 2,
  resource_error = 3
};

int main(int argc, char **argv) {
  if (argc != 2) {
    return usage_error;
  }

  errno = 0;
  char *end = NULL;
  long pid = strtol(argv[1], &end, 10);
  if (errno || end == argv[1] || *end || pid <= 0 || pid > INT_MAX) {
    return usage_error;
  }

  ProcessResources snapshot = process_resources((pid_t)pid);
  if (snapshot.result || snapshot.timebase_result != KERN_SUCCESS ||
      snapshot.timebase.numer == 0 || snapshot.timebase.denom == 0) {
    if (snapshot.error == ENOTSUP) {
      fprintf(stderr, "Resource snapshots require a native-architecture helper; translated execution has an incompatible Mach timebase\n");
    }

    return resource_error;
  }

  return process_resources_write(stdout, &snapshot) ? 0 : resource_error;
}
