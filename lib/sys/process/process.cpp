module;
#include <sys/wait.h>

module telar.sys.process;

// The parentheses keep each name from expanding as the macro the body calls.
bool(WIFEXITED)(int status) noexcept {
  return WIFEXITED(status);
}

int(WEXITSTATUS)(int status) noexcept {
  return WEXITSTATUS(status);
}

int(WTERMSIG)(int status) noexcept {
  return WTERMSIG(status);
}
