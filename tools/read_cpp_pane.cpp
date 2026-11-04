#include "protocol_peer.hpp"
#include <charconv>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string_view>

namespace {

std::uint64_t number(std::string_view text) {
  std::uint64_t value = 0;
  const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value);
  if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size() || value == 0) {
    throw std::invalid_argument{"Expected a positive integer"};
  }

  return value;
}

}

int main(int argc, char **argv) {
  try {
    if (argc != 5) {
      throw std::invalid_argument{"Usage: read-cpp-pane SOCKET PANE GENERATION ROWS"};
    }

    const auto pane = number(argv[2]);
    const auto generation = number(argv[3]);
    const auto rows = number(argv[4]);
    if (rows > 2000) {
      throw std::invalid_argument{"At most 2000 rows may be read"};
    }

    ProtocolPeer peer{argv[1]};
    const auto reply = peer.exchange<telar::PaneText>(telar::ReadPane{.request_id = 1, .pane_id = pane, .pane_generation = generation, .rows = static_cast<std::uint16_t>(rows), .source = telar::PaneTextSource::screen});
    if (reply.pane_id != pane || reply.truncated || reply.exit_code) {
      throw std::runtime_error{"Wrong, truncated or exited pane reply"};
    }

    std::cout.write(reply.text.data(), static_cast<std::streamsize>(reply.text.size()));
    return std::cout.good() ? 0 : 1;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
