#include "telar_client/codecs/telar_handshake.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_handshake.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <span>
#include <stdexcept>
#include <string_view>
#include <vector>

namespace {

using namespace telar;

bool readExact(std::span<Byte> bytes) {
  return std::fread(bytes.data(), 1, bytes.size(), stdin) == bytes.size();
}

std::vector<Byte> readFrame() {
  std::array<Byte, frame_prefix_size> prefix{};
  if (!readExact(prefix)) {
    return {};
  }

  std::span<const Byte> input{prefix};
  const auto length = u32::decode(input);
  if (length > max_payload_size) {
    throw std::length_error{"SSH fixture input frame exceeds capacity"};
  }

  std::vector<Byte> payload(length);
  if (!readExact(payload)) {
    throw std::runtime_error{"Truncated SSH fixture input"};
  }

  return payload;
}

void writeFrame(std::span<const Byte> payload) {
  std::array<Byte, frame_prefix_size> prefix{};
  std::span<Byte> output{prefix};
  u32::encode(static_cast<std::uint32_t>(payload.size()), output);
  if (std::fwrite(prefix.data(), 1, prefix.size(), stdout) != prefix.size() || std::fwrite(payload.data(), 1, payload.size(), stdout) != payload.size() || std::fflush(stdout) != 0) {
    throw std::runtime_error{"Write SSH fixture frame"};
  }
}

int sshFixture(std::span<char *> arguments) {
  const std::string_view destination{arguments[arguments.size() - 2]};
  if (destination == "denied") {
    static_cast<void>(std::fputs("Permission denied (publickey).", stderr));
    constexpr int ssh_failed = 255;

    return ssh_failed;
  }

  const std::string_view command{arguments.back()};
  if (!command.starts_with("exec ")) {
    const auto schema = textView(std::span{handshake::schema_id});
    static_cast<void>(std::fputs("/home/remote\n/bin/sh\n/run/remote/runtime.sock\n", stdout));
    static_cast<void>(std::fwrite(schema.data(), 1, schema.size(), stdout));
    static_cast<void>(std::fputc('\n', stdout));

    return 0;
  }

  const auto hello = readFrame();
  static_cast<void>(HandshakeCodec::decode<ClientHello>(hello));
  writeFrame(HandshakeCodec::encode(ServerAccept{handshake::schema_id}));
  for (;;) {
    const auto payload = readFrame();
    if (payload.empty()) {
      return 0;
    }

    writeFrame(payload);
  }
}

}

int main(int argc, char **argv) {
  constexpr int first_option = 1;
  if (argc > first_option && std::string_view{argv[first_option]} == "-T") {
    try {
      return sshFixture(std::span{argv, static_cast<std::size_t>(argc)});
    } catch (const std::exception &) {
      return 1;
    }
  }

  return 1;
}
