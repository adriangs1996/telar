// Each module's names, macros included, reach an importer that includes no system header.
import telar.sys.posix;
import telar.sys.process;
import telar.sys.socket;
#if defined(__APPLE__)
import telar.sys.apple;
#else
import telar.sys.linux_api;
#endif

namespace {

  int failures = 0;

  void expect(bool condition, const char* what) {
    if (!condition) {
      ++failures;
      ::write(STDERR_FILENO, what, ::strnlen(what, 128));
      ::write(STDERR_FILENO, "\n", 1);
    }
  }

  bool same(const char* left, const char* right) {
    while (*left != 0 && *left == *right) {
      ++left;
      ++right;
    }

    return *left == *right;
  }

  void ignore(int) {}

}

int main() {
  int descriptors[2];

  expect(::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) == 0, "socketpair");

  const char byte = 't';
  char received = 0;

  expect(::write(descriptors[0], &byte, 1) == 1, "write");
  expect(::read(descriptors[1], &received, 1) == 1 && received == byte, "read");

  pollfd readable{.fd = descriptors[1], .events = POLLIN, .revents = 0};

  expect(::write(descriptors[0], &byte, 1) == 1 && ::poll(&readable, 1, 0) == 1 && (readable.revents & POLLIN) != 0, "poll");

  ::close(descriptors[0]);
  ::close(descriptors[1]);

  // Constants, and a function macro whose result sizes an array.
  const int directory = ::open(".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  struct stat status{};

  expect(directory >= 0 && ::fstat(directory, &status) == 0 && S_ISDIR(status.st_mode) && !S_ISREG(status.st_mode), "S_ISDIR");
  expect(::fcntl(directory, F_GETFD) == FD_CLOEXEC, "O_CLOEXEC");
  ::close(directory);

  unsigned char control[CMSG_SPACE(sizeof(int))];

  expect(sizeof(control) >= CMSG_LEN(sizeof(int)) && PATH_MAX >= 256, "CMSG_SPACE");

  pid_t self = ::getpid();
  pollfd idle{.fd = -1, .events = 0, .revents = 0};

  expect(self > 0, "getpid");
  expect(::poll(&idle, 1, 0) == 0, "poll");
  expect(::kill(self, 0) == 0, "kill");

  sigset_t pending;

  expect(::sigpending(&pending) == 0, "sigpending");

  // Wait statuses: a normal exit with code 3, and a SIGKILL.
  expect(WIFEXITED(3 << 8) && WEXITSTATUS(3 << 8) == 3, "WEXITSTATUS");
  expect(!WIFEXITED(SIGKILL) && WTERMSIG(SIGKILL) == SIGKILL, "WTERMSIG");

  struct sigaction action{};

  telar::sys::signalHandler(action) = ignore;
  expect(sigemptyset(&action.sa_mask) == 0 && sigaddset(&action.sa_mask, SIGTERM) == 0 && sigismember(&action.sa_mask, SIGTERM) == 1, "sigaddset");
  expect(SIG_IGN != SIG_DFL && SIG_ERR != SIG_IGN, "SIG_IGN");

  // Byte order and address classes.
  in6_addr link_local{};

  telar::sys::addressBytes(link_local)[0] = 0xfe;
  telar::sys::addressBytes(link_local)[1] = 0x80;
  expect(htons(0x1234) == 0x3412 && ntohl(htonl(0x01020304)) == 0x01020304, "htons");
  expect(IN6_IS_ADDR_LINKLOCAL(&link_local) && !IN6_IS_ADDR_MULTICAST(&link_local), "IN6_IS_ADDR_LINKLOCAL");
  expect(IN_MULTICAST(0xe0000001u) && !IN_MULTICAST(INADDR_LOOPBACK), "IN_MULTICAST");

  ifreq request{};

  telar::sys::interfaceName(request)[0] = 'l';
  telar::sys::interfaceFlags(request) = IFF_UP;
  expect(telar::sys::interfaceName(request)[0] == 'l' && telar::sys::interfaceFlags(request) == IFF_UP, "ifreq");
  expect(stderr != nullptr && stdout != nullptr && stdin != nullptr, "stdio");

#if defined(__APPLE__)
  unsigned long long thread = 0;

  expect(::pthread_threadid_np(nullptr, &thread) == 0 && thread != 0, "pthread_threadid_np");
  expect(mach_task_self() != 0, "mach_task_self");

  const int queue = ::kqueue();
  struct kevent change{};

  EV_SET(&change, 0, EVFILT_READ, EV_ADD | EV_DISABLE, 0, 0, nullptr);
  expect(queue >= 0 && change.filter == EVFILT_READ && change.flags == (EV_ADD | EV_DISABLE), "EV_SET");
  ::close(queue);
#else
  unsigned char random[8];

  expect(::getrandom(random, sizeof(random), 0) == sizeof(random), "getrandom");

  const int queue = ::epoll_create1(EPOLL_CLOEXEC);

  expect(queue >= 0 && ::fcntl(queue, F_GETFD) == FD_CLOEXEC, "EPOLL_CLOEXEC");
  ::close(queue);
#endif

  telar::sys::setLastError(EAGAIN);
  expect(telar::sys::lastError() == EAGAIN, "lastError");

  // The errno names scripts read after `error: `: one for denied access, the fallback for anything else.
  expect(same(telar::sys::errorName(EACCES), "AccessDenied") && same(telar::sys::errorName(EPERM), "AccessDenied"), "errorName access");
  expect(same(telar::sys::errorName(EIO), "InputOutput") && same(telar::sys::errorName(EEXIST), "PathAlreadyExists"), "errorName files");
  expect(same(telar::sys::errorName(ENOSPC), "NoSpaceLeft") && same(telar::sys::errorName(EINVAL), "InvalidArgument"), "errorName space");
  expect(same(telar::sys::errorName(ENOMEM), "SystemResources") && same(telar::sys::errorName(EBADF), "InvalidDescriptor"), "errorName resources");
  expect(same(telar::sys::errorName(EISDIR), "Unexpected") && same(telar::sys::errorName(EISDIR, "Spawn"), "Spawn"), "errorName fallback");

  return failures == 0 ? 0 : 1;
}
