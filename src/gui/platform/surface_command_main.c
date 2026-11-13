#include <fcntl.h>
#include <stddef.h>
#include <stdlib.h>
#include <sys/errno.h>
#include <unistd.h>

#ifndef TEMP_FAILURE_RETRY
#include <errno.h>
#endif

enum SurfaceCommandBounds {
  maximum_arguments = 32,
  maximum_argument_bytes = 4096,
  maximum_payload_bytes = 1 + maximum_argument_bytes + maximum_arguments,
  invalid_request = 125,
  unavailable_program = 127,
};

static size_t readPayload(char *payload) {
  size_t used = 0;
  while (used < maximum_payload_bytes + 1) {
#ifdef TEMP_FAILURE_RETRY
    const ssize_t count = TEMP_FAILURE_RETRY(read(STDIN_FILENO, payload + used, maximum_payload_bytes + 1 - used));
#else
    const ssize_t count = read(STDIN_FILENO, payload + used, maximum_payload_bytes + 1 - used);
    if (count < 0 && errno == EINTR) {
      continue;
    }
#endif

    if (count < 0) {
      return 0;
    }

    if (count == 0) {
      break;
    }

    used += (size_t)count;
  }

  return used;
}

static int parseArguments(char *payload, size_t used, char **arguments) {
  if (used == 0 || used > maximum_payload_bytes) {
    return 0;
  }

  const size_t count = (unsigned char)payload[0];
  if (count == 0 || count > maximum_arguments || used < 1 + count || used - count - 1 > maximum_argument_bytes) {
    return 0;
  }

  size_t offset = 1;
  for (size_t index = 0; index < count; ++index) {
    arguments[index] = payload + offset;
    while (offset < used && payload[offset] != '\0') {
      ++offset;
    }

    if (offset == used || (index == 0 && payload[1] == '\0')) {
      return 0;
    }

    ++offset;
  }

  return offset == used;
}

int main(void) {
  char payload[maximum_payload_bytes + 1];
  char *arguments[maximum_arguments + 1] = {0};
  const size_t used = readPayload(payload);
  if (!parseArguments(payload, used, arguments) || arguments[0] == NULL) {
    return invalid_request;
  }

  const int input = open("/dev/null", O_RDONLY);
  if (input < 0 || dup2(input, STDIN_FILENO) < 0) {
    if (input >= 0) {
      close(input);
    }

    return invalid_request;
  }

  if (input != STDIN_FILENO) {
    close(input);
  }

  execvp(arguments[0], arguments);

  return unavailable_program;
}
