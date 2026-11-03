#pragma once

#include "process_inspector.hpp"
#include "telar_platform/trace.hpp"
#include <concepts>

namespace telar::runtime {

struct DescentCheck {
  std::uint64_t client = 0;
  std::uint64_t client_generation = 0;
  std::uint64_t pane = 0;
  std::uint64_t pane_generation = 0;
  std::uint64_t request_id = 0;
  ProcessIdentity peer;
  pid_t root = 0;
};

template <typename Inspector>
concept LineageInspector = requires(const Inspector &inspector, ProcessIdentity process, pid_t root) {
  { inspector.lineage(process, root) } noexcept -> std::same_as<ProcessLineage>;
};

template <LineageInspector Inspector>
class DescentProbe {
public:
  struct Request {
    std::array<DescentCheck, 32> checks;
    std::size_t count = 0;
  };

  struct Completion {
    DescentCheck check;
    ProcessLineage lineage;
  };

  struct Result {
    std::array<Completion, 32> checks;
    std::size_t count = 0;
  };

  explicit DescentProbe(const Inspector &inspector) noexcept
      : inspector_(inspector) {}

  Result observe(const Request &request) noexcept {
    TELAR_TRACE("agents.verifyDescent");
    Result result;
    for (const auto &check : std::span{request.checks}.first(request.count)) {
      result.checks[result.count++] = {check, inspector_.lineage(check.peer, check.root)};
    }
    return result;
  }

  void stop() noexcept {}

private:
  const Inspector &inspector_;
};

}
