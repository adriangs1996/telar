// Each module's names reach an importer that includes no system header.
import telar.sys.posix;
import telar.sys.process;
import telar.sys.socket;
#if defined(__APPLE__)
import telar.sys.apple;
#else
import telar.sys.linux;
#endif

namespace {

  int failures = 0;

  void expect(bool condition, const char* what) {
    if (!condition) {
      ++failures;
      ::write(2, what, ::strnlen(what, 128));
      ::write(2, "\n", 1);
    }
  }

}

int main() {
  int descriptors[2];

  // AF_UNIX and SOCK_STREAM: the modules export no macros yet.
  expect(::socketpair(1, 1, 0, descriptors) == 0, "socketpair");

  const char byte = 't';
  char received = 0;

  expect(::write(descriptors[0], &byte, 1) == 1, "write");
  expect(::read(descriptors[1], &received, 1) == 1 && received == byte, "read");

  ::close(descriptors[0]);
  ::close(descriptors[1]);

  pid_t self = ::getpid();
  pollfd idle{.fd = -1, .events = 0, .revents = 0};

  expect(self > 0, "getpid");
  expect(::poll(&idle, 1, 0) == 0, "poll");
  expect(::kill(self, 0) == 0, "kill");

  sigset_t pending;

  expect(::sigpending(&pending) == 0, "sigpending");

#if defined(__APPLE__)
  unsigned long long thread = 0;

  expect(::pthread_threadid_np(nullptr, &thread) == 0 && thread != 0, "pthread_threadid_np");
#else
  unsigned char random[8];

  expect(::getrandom(random, sizeof(random), 0) == sizeof(random), "getrandom");
#endif

  return failures == 0 ? 0 : 1;
}
