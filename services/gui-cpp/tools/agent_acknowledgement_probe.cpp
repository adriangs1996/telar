#include "application/agent_acknowledgement.hpp"
#include "probe_io.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <optional>
#include <stdexcept>

namespace {

using namespace telar;
using namespace telar::gui;

struct Candidate {
  std::uint64_t pane_id;
  std::uint64_t pane_generation;
  AgentStatus status;
};

std::optional<AcknowledgeAgent> sample(AgentAcknowledgement &acknowledgement) {
  const auto present = probe::read<std::uint8_t>() != 0;
  const auto pane_id = probe::read<std::uint64_t>();
  const auto generation = probe::read<std::uint64_t>();
  const auto status = static_cast<AgentStatus>(probe::read<std::uint8_t>());
  const Candidate candidate{.pane_id = pane_id, .pane_generation = generation, .status = status};

  return acknowledgement.take(present ? &candidate : nullptr);
}

}

int main() try {
  AgentAcknowledgement acknowledgement;
  while (true) {
    const auto operation = std::getchar();
    if (operation == EOF) {
      return 0;
    }

    std::optional<AcknowledgeAgent> request;
    if (operation == 0) {
      acknowledgement = {};
    } else if (operation == 1) {
      request = sample(acknowledgement);
    } else {
      throw std::invalid_argument{"UnknownAgentAcknowledgementOperation"};
    }

    probe::write(static_cast<std::uint8_t>(request.has_value()));
    probe::write(request ? request->pane_id : 0);
    probe::write(request ? request->pane_generation : 0);
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
