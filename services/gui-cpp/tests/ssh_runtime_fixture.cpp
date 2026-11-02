#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_handshake.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_handshake.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
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

template <typename Message>
void sendMessage(const Message &message) {
  std::vector<Byte> storage(Codec::encodedSize(message));
  writeFrame(Codec::encode(message, storage));
}

void windowMessage(std::span<const Byte> payload, bool named_launch) {
  constexpr TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};
  constexpr std::uint64_t pane_id = 1;
  constexpr std::size_t decode_capacity = 4096;
  std::array<Byte, decode_capacity> scratch{};
  DecodeStorage decode{scratch};
  switch (static_cast<ClientTag>(payload.front())) {
  case ClientTag::request_runtime_state:
    sendMessage(ClientLayoutSnapshot{});
    break;
  case ClientTag::open_pane: {
    const auto request = Codec::decode<OpenPane>(payload, decode);
    const std::array<std::string_view, 3> expected{"/bin/sh", "-l", "-i"};
    const std::array<std::string_view, 2> named{"/bin/echo", "REMOTE_NAMED"};
    const auto arguments = named_launch ? std::span<const std::string_view>{named} : std::span<const std::string_view>{expected};
    if (!request.launch || request.launch->cwd != "/home/remote" || !std::ranges::equal(request.launch->arguments, arguments)) {
      throw std::runtime_error{"Remote launch did not adopt discovered home and shell"};
    }

    sendMessage(PaneOpened{.request_id = request.request_id, .pane_id = pane_id, .location = location, .created = true, .pane_generation = 1});
    break;
  }
  case ClientTag::request_tab_snapshot: {
    const auto request = Codec::decode<RequestTabSnapshot>(payload, decode);
    const std::array panes{PaneDescriptor{.pane_id = pane_id, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};
    sendMessage(TabSnapshot{.request_id = request.request_id, .location = location, .panes = panes});
    break;
  }
  case ClientTag::request_workspace_snapshot: {
    const auto request = Codec::decode<RequestWorkspaceSnapshot>(payload, decode);
    const std::array tabs{TabDescriptor{.tab_id = location.tab_id, .pane_count = 1}};
    sendMessage(WorkspaceSnapshot{.request_id = request.request_id, .workspace = location.workspace, .name = "remote", .tabs = tabs});
    break;
  }
  default:
    break;
  }
}

int sshFixture(std::span<char *> arguments) {
  const std::string_view destination{arguments[arguments.size() - 2]};
  if (destination == "missing") {
    constexpr int command_missing = 127;

    return command_missing;
  }

  if (destination == "denied") {
    static_cast<void>(std::fputs("Permission denied (publickey).", stderr));
    constexpr int ssh_failed = 255;

    return ssh_failed;
  }

  constexpr SchemaId legacy_schema{'8', '7', '6', 'b', '4', '8', '0', 'd'};
  const auto &selected_schema = destination == "legacy" ? legacy_schema : handshake::schema_id;
  const std::string_view command{arguments.back()};
  if (!command.starts_with("exec ")) {
    const auto schema = textView(std::span{selected_schema});
    static_cast<void>(std::fputs("/home/remote\n/bin/sh\n/run/remote/runtime.sock\n", stdout));
    static_cast<void>(std::fwrite(schema.data(), 1, schema.size(), stdout));
    static_cast<void>(std::fputc('\n', stdout));

    return 0;
  }

  const auto hello = readFrame();
  if (HandshakeCodec::decode<ClientHello>(hello).schema != selected_schema) {
    throw std::runtime_error{"SSH client requested the wrong discovered schema"};
  }

  writeFrame(HandshakeCodec::encode(ServerAccept{selected_schema}));
  for (;;) {
    const auto payload = readFrame();
    if (payload.empty()) {
      return 0;
    }

    if (destination.starts_with("window")) {
      windowMessage(payload, destination == "window-command@fixture");
    } else {
      writeFrame(payload);
    }
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
