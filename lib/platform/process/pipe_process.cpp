module telar.platform.process;

import std;
import telar.sys.posix;
import telar.sys.process;
import telar.sys.socket;
import telar.platform.error;
import telar.base.ds;
#ifdef __APPLE__
import telar.sys.apple;
#else
// Linux suppresses SIGPIPE on the input pipe the way it does on sockets.
import telar.platform.net;
#endif

namespace telar::runtime {
  namespace {

    ds::Array<FileDescriptor, 2> makePipe(ProcessInput input = ProcessInput::pipe) {
      ds::Array<int, 2> raw{};
      const auto result = input == ProcessInput::pipe ? ::pipe(raw.dataMut()) : ::socketpair(AF_UNIX, SOCK_STREAM, 0, raw.dataMut());
      if (result != 0) {
        throw SystemError{"Create process pipe"};
      }

      ds::Array<FileDescriptor, 2> ends{FileDescriptor{raw[0]}, FileDescriptor{raw[1]}};

      if (input == ProcessInput::buffered_socket) {
        constexpr int capacity = 256 * 1024;
        if (::setsockopt(ends[0].get(), SOL_SOCKET, SO_RCVBUF, &capacity, sizeof(capacity)) != 0 || ::setsockopt(ends[1].get(), SOL_SOCKET, SO_SNDBUF, &capacity, sizeof(capacity)) != 0) {
          throw SystemError{"Size worker input buffers"};
        }
      }

      for (auto& end : ends.viewMut()) {
        if (end.get() <= STDERR_FILENO) {
          const int relocated = ::fcntl(end.get(), F_DUPFD_CLOEXEC, STDERR_FILENO + 1); // NOLINT(cppcoreguidelines-pro-type-vararg): fcntl's C signature is variadic
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

  PipeProcess::PipeProcess(const SpawnSpec& specification, ProcessInput input_kind) {
    auto input = makePipe(input_kind);
    auto output = makePipe();
    auto error = makePipe();

    setNonblocking(input[1].get());
#ifdef __APPLE__
    if (::fcntl(input[1].get(), F_SETNOSIGPIPE, 1) < 0) { // NOLINT(cppcoreguidelines-pro-type-vararg): fcntl's C signature is variadic
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

    input_ = std::move(input.atMut(1));
    output_ = std::move(output.atMut(0));
    error_ = std::move(error.atMut(0));
  }

  PipeProcess::~PipeProcess() {
    if (process_id_ > 0 && !exit_status_) {
      ::kill(-process_id_, SIGKILL);
      ::kill(process_id_, SIGKILL);
      int status = 0;

      while (::waitpid(process_id_, &status, 0) < 0 && sys::lastError() == EINTR) {
      }
    }
  }

  int PipeProcess::input() const noexcept {
    return input_.get();
  }

  int PipeProcess::output() const noexcept {
    return output_.get();
  }

  int PipeProcess::error() const noexcept {
    return error_.get();
  }

  pid_t PipeProcess::processId() const noexcept {
    return process_id_;
  }

  void PipeProcess::closeInput() noexcept {
    input_.reset();
  }

  void PipeProcess::closeOutput() noexcept {
    output_.reset();
  }

  void PipeProcess::closeError() noexcept {
    error_.reset();
  }

  void PipeProcess::signal(int number) const noexcept {
    if (process_id_ > 0 && !exit_status_) {
      ::kill(-process_id_, number);
      ::kill(process_id_, number);
    }
  }

  ds::Option<int> PipeProcess::reap() noexcept {
    if (!exit_status_) {
      int status = 0;
      if (::waitpid(process_id_, &status, WNOHANG) == process_id_) {
        exit_status_ = status;
      }
    }

    return exit_status_;
  }

}
