#pragma once

#include "file_descriptor.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <optional>
#include <sys/types.h>

namespace telar::runtime {

struct SpawnSpec {
  const char *executable;
  const char *cwd;
  char *const *arguments;
  char *const *environment;
  TerminalSize size;
};

class PtyProcess {
public:
  explicit PtyProcess(const SpawnSpec &specification);
  ~PtyProcess();
  PtyProcess(const PtyProcess &) = delete;
  PtyProcess &operator=(const PtyProcess &) = delete;

  int descriptor() const noexcept {
    return master_.get();
  }

  pid_t processId() const noexcept {
    return process_id_;
  }

  void resize(TerminalSize size);
  std::optional<pid_t> foregroundProcessGroup() const noexcept;
  void signal(int signal_number) const noexcept;
  void shutdown() const noexcept;
  std::optional<int> reap() noexcept;

private:
  FileDescriptor master_;
  pid_t process_id_ = -1;
  std::optional<int> exit_status_;
};

}
