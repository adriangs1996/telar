#include "pty_process.hpp"
#include "child_descriptors.hpp"
#include "error.hpp"
#include <algorithm>
#include <cerrno>
#include <csignal>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

namespace telar::runtime {

static winsize windowSize(TerminalSize size) noexcept {
  return winsize{
      .ws_row = size.rows,
      .ws_col = size.cols,
      .ws_xpixel = static_cast<unsigned short>(std::min<unsigned>(UINT16_MAX, size.cols * size.cell_width_px)),
      .ws_ypixel = static_cast<unsigned short>(std::min<unsigned>(UINT16_MAX, size.rows * size.cell_height_px)),
  };
}

static void moveAboveStandardStreams(FileDescriptor &descriptor) {
  if (descriptor.get() > STDERR_FILENO) {
    return;
  }

  const int duplicated = ::fcntl(descriptor.get(), F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
  if (duplicated < 0) {
    throw SystemError{"reserve child descriptor"};
  }
  descriptor.reset(duplicated);
}

[[noreturn]] static void reportSpawnFailure(int descriptor) noexcept {
  const int failure = errno;
  const auto *bytes = reinterpret_cast<const char *>(&failure);
  std::size_t written = 0;

  while (written < sizeof(failure)) {
    const auto count = ::write(descriptor, bytes + written, sizeof(failure) - written);
    if (count < 0 && errno == EINTR) {
      continue;
    }

    if (count <= 0) {
      break;
    }

    written += static_cast<std::size_t>(count);
  }

  _exit(127);
}

PtyProcess::PtyProcess(const SpawnSpec &specification) {
  FileDescriptor directory{::open(specification.cwd, O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
  if (!directory) {
    throw SystemError{"open pane working directory"};
  }

  moveAboveStandardStreams(directory);
  int pipe_descriptors[2];
  if (::pipe(pipe_descriptors) < 0) {
    throw SystemError{"create spawn status pipe"};
  }

  FileDescriptor status_reader{pipe_descriptors[0]};
  FileDescriptor status_writer{pipe_descriptors[1]};
  moveAboveStandardStreams(status_reader);
  moveAboveStandardStreams(status_writer);
  setCloseOnExec(status_reader.get());
  setCloseOnExec(status_writer.get());

  int master = -1;
  int slave = -1;
  auto dimensions = windowSize(specification.size);
  if (::openpty(&master, &slave, nullptr, nullptr, &dimensions) < 0) {
    throw SystemError{"open pseudoterminal"};
  }

  master_.reset(master);
  FileDescriptor slave_descriptor{slave};
  moveAboveStandardStreams(master_);
  moveAboveStandardStreams(slave_descriptor);
  master = master_.get();
  slave = slave_descriptor.get();
  setCloseOnExec(master);
  setCloseOnExec(slave);
  setNonblocking(master);
  const int descriptor_limit = getdtablesize();

  process_id_ = ::fork();
  if (process_id_ < 0) {
    throw SystemError{"fork pane process"};
  }

  if (process_id_ == 0) {
    if (::setsid() < 0 || ::ioctl(slave, TIOCSCTTY, 0) < 0 || ::fchdir(directory.get()) < 0) {
      reportSpawnFailure(status_writer.get());
    }

    for (int descriptor = STDIN_FILENO; descriptor <= STDERR_FILENO; ++descriptor) {
      if (::dup2(slave, descriptor) < 0) {
        reportSpawnFailure(status_writer.get());
      }
    }

    closeChildDescriptors(status_writer.get(), descriptor_limit);

    sigset_t signals;
    sigemptyset(&signals);
    sigprocmask(SIG_SETMASK, &signals, nullptr);
    for (int signal_number = 1; signal_number < NSIG; ++signal_number) {
      ::signal(signal_number, SIG_DFL);
    }

    ::execve(specification.executable, specification.arguments, specification.environment);
    reportSpawnFailure(status_writer.get());
  }

  slave_descriptor.reset();
  status_writer.reset();
  int failure = 0;
  std::size_t received = 0;

  while (received < sizeof(failure)) {
    const auto count = ::read(status_reader.get(), reinterpret_cast<char *>(&failure) + received, sizeof(failure) - received);
    if (count < 0 && errno == EINTR) {
      continue;
    }

    if (count == 0) {
      break;
    }

    if (count < 0) {
      failure = errno;
      received = sizeof(failure);
      break;
    }

    received += static_cast<std::size_t>(count);
  }

  if (received != 0) {
    ::kill(process_id_, SIGKILL);
    while (::waitpid(process_id_, nullptr, 0) < 0 && errno == EINTR) {
    }
    process_id_ = -1;
    throw SystemError{"execute pane command", received == sizeof(failure) ? failure : EIO};
  }
}

PtyProcess::~PtyProcess() {
  if (process_id_ <= 0 || exit_status_) {
    return;
  }

  shutdown();
  master_.reset();

  while (::waitpid(process_id_, nullptr, 0) < 0 && errno == EINTR) {
  }
}

void PtyProcess::resize(TerminalSize size) {
  auto dimensions = windowSize(size);
  if (::ioctl(master_.get(), TIOCSWINSZ, &dimensions) < 0) {
    throw SystemError{"resize pseudoterminal"};
  }
}

std::optional<pid_t> PtyProcess::foregroundProcessGroup() const noexcept {
  pid_t foreground = 0;
  if (::ioctl(master_.get(), TIOCGPGRP, &foreground) < 0 || foreground <= 0) {
    return std::nullopt;
  }

  return foreground;
}

void PtyProcess::signal(int signal_number) const noexcept {
  if (process_id_ > 0 && !exit_status_) {
    ::kill(-process_id_, signal_number);
  }
}

void PtyProcess::shutdown() const noexcept {
  if (process_id_ <= 0 || exit_status_) {
    return;
  }

  if (const auto foreground = foregroundProcessGroup(); foreground && *foreground != ::getpgrp()) {
    ::kill(-*foreground, SIGKILL);
  }
  ::kill(process_id_, SIGKILL);

  // Darwin can retain a dying session leader while unread terminal output drains.
  ::tcflush(master_.get(), TCIOFLUSH);
}

std::optional<int> PtyProcess::reap() noexcept {
  if (!exit_status_ && process_id_ > 0) {
    int status = 0;
    if (::waitpid(process_id_, &status, WNOHANG) == process_id_) {
      exit_status_ = status;
    }
  }

  return exit_status_;
}

}
