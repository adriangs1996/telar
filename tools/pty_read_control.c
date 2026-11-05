#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

typedef struct {
  int descriptor;
  const unsigned char *bytes;
  size_t length;
} Output;

static void *produce(void *context) {
  const Output *output = context;
  size_t sent = 0;
  while (sent < output->length) {
    const ssize_t count = write(output->descriptor, output->bytes + sent, output->length - sent);
    assert(count > 0);
    sent += (size_t)count;
  }

  return NULL;
}

int main(int argc, char **argv) {
  int master, slave;
  struct termios settings;
  assert(openpty(&master, &slave, NULL, NULL, NULL) == 0);
  assert(tcgetattr(slave, &settings) == 0);
  cfmakeraw(&settings);
  assert(tcsetattr(slave, TCSANOW, &settings) == 0);
  assert(fcntl(master, F_SETFL, O_NONBLOCK) == 0);
  unsigned char expected[3000], actual[16384];
  for (size_t index = 0; index < sizeof(expected); ++index) {
    expected[index] = (unsigned char)(index % 251);
  }

  Output output = {.descriptor = slave, .bytes = expected, .length = sizeof(expected)};
  pthread_t writer;
  assert(pthread_create(&writer, NULL, produce, &output) == 0);
  size_t received = 0;
  while (received < sizeof(expected)) {
    struct pollfd pending = {.fd = master, .events = POLLIN};
    assert(poll(&pending, 1, 2000) == 1);
    errno = E2BIG;
    const ssize_t count = read(master, actual, sizeof(actual));
    assert(count > 0 && errno == E2BIG);
    assert((size_t)count <= sizeof(expected) - received);
    assert(memcmp(actual, expected + received, (size_t)count) == 0);
    received += (size_t)count;
  }

  assert(pthread_join(writer, NULL) == 0);
  assert(read(master, actual, sizeof(actual)) == -1 && errno == EAGAIN);
  assert(pthread_create(&writer, NULL, produce, &output) == 0);
  received = 0;
  while (received < sizeof(expected)) {
    struct pollfd pending = {.fd = master, .events = POLLIN};
    assert(poll(&pending, 1, 2000) == 1);
    struct iovec vectors[] = {
        {.iov_base = actual, .iov_len = 31},
        {.iov_base = actual + 31, .iov_len = sizeof(actual) - 31},
    };
    errno = E2BIG;
    const ssize_t count = readv(master, vectors, 2);
    assert(count > 0 && errno == E2BIG);
    assert((size_t)count <= sizeof(expected) - received);
    assert(memcmp(actual, expected + received, (size_t)count) == 0);
    received += (size_t)count;
  }

  assert(pthread_join(writer, NULL) == 0);
  struct iovec empty = {.iov_base = actual, .iov_len = sizeof(actual)};
  assert(readv(master, &empty, 1) == -1 && errno == EAGAIN);
  assert(readv(master, (const struct iovec *)1, 1) == -1 && errno == EFAULT);
  int pipe_descriptors[2];
  assert(pipe(pipe_descriptors) == 0);
  assert(write(pipe_descriptors[1], "pipe", 4) == 4);
  assert(read(pipe_descriptors[0], actual, sizeof(actual)) == 4);
  close(pipe_descriptors[0]);
  close(pipe_descriptors[1]);

  const pid_t child = fork();
  assert(child >= 0);
  if (child == 0) {
    assert(write(slave, "child", 5) == 5);
    assert(read(master, actual, sizeof(actual)) == 5);
    exit(0);
  }

  int status;
  assert(waitpid(child, &status, 0) == child && status == 0);
  if (argc == 2 && strcmp(argv[1], "overflow") == 0) {
    for (unsigned index = 0; index < 16385; ++index) {
      assert(write(slave, "x", 1) == 1);
      assert(read(master, actual, sizeof(actual)) == 1);
    }
  }

  close(master);
  close(slave);
  printf("%d\n", getpid());
  return 0;
}
