#include "telar_platform/pipe_process.hpp"
#include "telar_platform/error.hpp"
#include "telar_platform/socket_signals.hpp"
#include "telar_platform/spawn_options.hpp"
#include <csignal>
#include <fcntl.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/wait.h>

namespace telar::runtime {
namespace {

std::array<FileDescriptor, 2> makePipe(ProcessInput input = ProcessInput::pipe) {
  std::array<int, 2> raw{};
  const auto result = input == ProcessInput::pipe ? ::pipe(raw.data()) : ::socketpair(AF_UNIX, SOCK_STREAM, 0, raw.data());
  if (result != 0) {
    throw SystemError{"Create process pipe"};
  }

  std::array<FileDescriptor, 2> ends{FileDescriptor{raw[0]}, FileDescriptor{raw[1]}};
  if (input == ProcessInput::buffered_socket) {
    constexpr int capacity = 256 * 1024;
    if (::setsockopt(ends[0].get(), SOL_SOCKET, SO_RCVBUF, &capacity, sizeof(capacity)) != 0 || ::setsockopt(ends[1].get(), SOL_SOCKET, SO_SNDBUF, &capacity, sizeof(capacity)) != 0) {
      throw SystemError{"Size worker input buffers"};
    }
  }
  for (auto &end : ends) {
    if (end.get() <= STDERR_FILENO) {
      const int relocated = ::fcntl(end.get(), F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
      if (relocated < 0) {
        throw SystemError{"Relocate process pipe"};
      }

      end.reset(relocated);
    } else {
      setCloseOnExec(end.get());
    }
  }

  return ends;
}

}

PipeProcess::PipeProcess(const SpawnSpec &specification, ProcessInput input_kind) {
  auto input = makePipe(input_kind);
  auto output = makePipe();
  auto error = makePipe();
  setNonblocking(input[1].get());
#if defined(F_SETNOSIGPIPE)
  if (::fcntl(input[1].get(), F_SETNOSIGPIPE, 1) < 0) {
    throw SystemError{"Suppress pipe signals"};
  }
#else
  suppressSocketSignals(input[1].get());
#endif
  setNonblocking(output[0].get());
  setNonblocking(error[0].get());

  SpawnOptions options{POSIX_SPAWN_SETPGROUP};
  options.changeDirectory(specification.cwd);
  options.redirect(input[0].get(), STDIN_FILENO);
  options.redirect(output[1].get(), STDOUT_FILENO);
  options.redirect(error[1].get(), STDERR_FILENO);
  options.closeOthers();
  checkSpawn(posix_spawn(&process_id_, specification.executable, &options.actions, &options.attributes, specification.arguments, specification.environment));

  input_ = std::move(input[1]);
  output_ = std::move(output[0]);
  error_ = std::move(error[0]);
}

PipeProcess::~PipeProcess() {
  if (process_id_ > 0 && !exit_status_) {
    ::kill(-process_id_, SIGKILL);
    ::kill(process_id_, SIGKILL);
    int status;
    while (::waitpid(process_id_, &status, 0) < 0 && errno == EINTR) {
    }
  }
}

void PipeProcess::signal(int number) const noexcept {
  if (process_id_ > 0 && !exit_status_) {
    ::kill(-process_id_, number);
    ::kill(process_id_, number);
  }
}

std::optional<int> PipeProcess::reap() noexcept {
  if (!exit_status_) {
    int status;
    if (::waitpid(process_id_, &status, WNOHANG) == process_id_) {
      exit_status_ = status;
    }
  }

  return exit_status_;
}

}
