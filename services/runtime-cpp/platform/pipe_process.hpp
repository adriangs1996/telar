#pragma once

#include "pty_process.hpp"
#include <array>

namespace telar::runtime {

enum class ProcessInput { pipe,
                          buffered_socket };

class PipeProcess {
public:
  explicit PipeProcess(const SpawnSpec &specification, ProcessInput input = ProcessInput::pipe);
  ~PipeProcess();
  PipeProcess(const PipeProcess &) = delete;
  PipeProcess &operator=(const PipeProcess &) = delete;

  int input() const noexcept {
    return input_.get();
  }

  int output() const noexcept {
    return output_.get();
  }

  int error() const noexcept {
    return error_.get();
  }

  pid_t processId() const noexcept {
    return process_id_;
  }

  void closeInput() noexcept {
    input_.reset();
  }

  void closeOutput() noexcept {
    output_.reset();
  }

  void closeError() noexcept {
    error_.reset();
  }

  void signal(int number) const noexcept;
  std::optional<int> reap() noexcept;

private:
  FileDescriptor input_;
  FileDescriptor output_;
  FileDescriptor error_;
  pid_t process_id_ = -1;
  std::optional<int> exit_status_;
};

}
