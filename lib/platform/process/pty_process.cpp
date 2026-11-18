module telar.platform.process;

import std;
import telar.sys.posix;
import telar.sys.process;
import telar.platform.error;
import telar.base.ds;
#if defined(__APPLE__)
import telar.sys.apple;
#endif
#if defined(__linux__)
import telar.sys.linux_api;
#endif

namespace telar::runtime {

  static winsize windowSize(TerminalSize size) noexcept {
    return winsize{
        .ws_row = size.rows,
        .ws_col = size.cols,
        .ws_xpixel = static_cast<unsigned short>(std::min<unsigned>(std::numeric_limits<std::uint16_t>::max(), size.cols * size.cell_width_px)),
        .ws_ypixel = static_cast<unsigned short>(std::min<unsigned>(std::numeric_limits<std::uint16_t>::max(), size.rows * size.cell_height_px)),
    };
  }

  static void moveAboveStandardStreams(FileDescriptor& descriptor) {
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
    const int failure = sys::lastError();
    const auto* bytes = reinterpret_cast<const char*>(&failure);
    std::size_t written = 0;

    while (written < sizeof(failure)) {
      const auto count = ::write(descriptor, bytes + written, sizeof(failure) - written);
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count <= 0) {
        break;
      }

      written += static_cast<std::size_t>(count);
    }

    _exit(127);
  }

  void closeChildDescriptors(int retained, int descriptor_limit) noexcept {
#if defined(__APPLE__)
    // Only the forked child enumerates descriptors, so no other thread can open
    // one during the scan. proc_pidinfo copies kernel data into this stack buffer.
    ds::Array<proc_fdinfo, 1024> descriptors;
    const int bytes = ::proc_pidinfo(::getpid(), PROC_PIDLISTFDS, 0, descriptors.dataMut(), sizeof(descriptors));

    if (bytes > 0 && bytes < static_cast<int>(sizeof(descriptors)) && bytes % sizeof(proc_fdinfo) == 0) {
      const auto count = static_cast<std::size_t>(bytes) / sizeof(proc_fdinfo);

      for (std::size_t index = 0; index < count; ++index) {
        const int descriptor = descriptors[index].proc_fd;
        if (descriptor > STDERR_FILENO && descriptor != retained) {
          ::close(descriptor);
        }
      }

      return;
    }
#else
    const auto first = static_cast<unsigned>(STDERR_FILENO + 1);
    const bool lower_closed = retained <= static_cast<int>(first) || ::syscall(SYS_close_range, first, static_cast<unsigned>(retained - 1), 0) == 0;
    const bool upper_closed = ::syscall(SYS_close_range, static_cast<unsigned>(retained + 1), std::numeric_limits<unsigned>::max(), 0) == 0;
    if (lower_closed && upper_closed) {
      return;
    }
#endif

    for (int descriptor = STDERR_FILENO + 1; descriptor < descriptor_limit; ++descriptor) {
      if (descriptor != retained) {
        ::close(descriptor);
      }
    }
  }

  PtyProcess::PtyProcess(const SpawnSpec& specification) {
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
      const auto count = ::read(status_reader.get(), reinterpret_cast<char*>(&failure) + received, sizeof(failure) - received);
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count == 0) {
        break;
      }

      if (count < 0) {
        failure = sys::lastError();
        received = sizeof(failure);
        break;
      }

      received += static_cast<std::size_t>(count);
    }

    if (received != 0) {
      ::kill(process_id_, SIGKILL);
      while (::waitpid(process_id_, nullptr, 0) < 0 && sys::lastError() == EINTR) {
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

    while (::waitpid(process_id_, nullptr, 0) < 0 && sys::lastError() == EINTR) {
    }
  }

  int PtyProcess::descriptor() const noexcept {
    return master_.get();
  }

  pid_t PtyProcess::processId() const noexcept {
    return process_id_;
  }

  void PtyProcess::resize(TerminalSize size) {
    auto dimensions = windowSize(size);
    if (::ioctl(master_.get(), TIOCSWINSZ, &dimensions) < 0) {
      throw SystemError{"resize pseudoterminal"};
    }
  }

  ds::Option<pid_t> PtyProcess::foregroundProcessGroup() const noexcept {
    pid_t foreground = 0;
    if (::ioctl(master_.get(), TIOCGPGRP, &foreground) < 0 || foreground <= 0) {
      return ds::none;
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

  ds::Option<int> PtyProcess::reap() noexcept {
    if (!exit_status_ && process_id_ > 0) {
      int status = 0;
      if (::waitpid(process_id_, &status, WNOHANG) == process_id_) {
        exit_status_ = status;
      }
    }

    return exit_status_;
  }

}
