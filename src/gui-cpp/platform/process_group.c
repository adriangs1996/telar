#include "process_group.h"
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <sys/signal.h>
#include <sys/types.h>

void telarSignalProcessGroup(int64_t process, int force) {
  if (process <= 1 || process > INT_MAX) {
    return;
  }

  (void)kill(-(pid_t)process, force ? SIGKILL : SIGTERM);
}
