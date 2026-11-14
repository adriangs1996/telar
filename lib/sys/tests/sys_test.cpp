#include <errno.h>

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

  bool same(const char* left, const char* right) {
    while (*left != 0 && *left == *right) {
      ++left;
      ++right;
    }

    return *left == *right;
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

  errno = EAGAIN;
  expect(telar::sys::lastError() == EAGAIN, "lastError");

  // The errno names scripts read after `error: `: one for denied access, the fallback for anything else.
  expect(same(telar::sys::errorName(EACCES), "AccessDenied") && same(telar::sys::errorName(EPERM), "AccessDenied"), "errorName access");
  expect(same(telar::sys::errorName(EIO), "InputOutput") && same(telar::sys::errorName(EEXIST), "PathAlreadyExists"), "errorName files");
  expect(same(telar::sys::errorName(ENOSPC), "NoSpaceLeft") && same(telar::sys::errorName(EINVAL), "InvalidArgument"), "errorName space");
  expect(same(telar::sys::errorName(ENOMEM), "SystemResources") && same(telar::sys::errorName(EBADF), "InvalidDescriptor"), "errorName resources");
  expect(same(telar::sys::errorName(EDOM), "Unexpected") && same(telar::sys::errorName(EDOM, "Spawn"), "Spawn"), "errorName fallback");

  return failures == 0 ? 0 : 1;
}
