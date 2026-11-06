#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <concepts>
#include "assertions.hpp"
#include "telar_client/codecs/telar_cells.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_serializer.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <ranges>
#include <span>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#pragma once


import telar.gui.application.host_effects;

namespace telar::gui::test {

class Transport {
public:
  template <typename Message>
  void send(const Message &message) {
    validatePaneDelivery<Message>();

    if constexpr (std::same_as<Message, OpenEditor>) {
      if (reject_editor) {
        throw EncodingError{"Editor transport is full"};
      }
    }

    if constexpr (std::same_as<Message, CreatePane>) {
      if (reject_create_pane) {
        throw EncodingError{"Pane transport is full"};
      }
    }

    if constexpr (std::same_as<Message, CreateTab>) {
      if (reject_create_tab) {
        throw EncodingError{"Tab transport is full"};
      }
    }

    if constexpr (std::same_as<Message, ForgetWorktree>) {
      if (reject_forget_worktree) {
        throw EncodingError{"Worktree transport is full"};
      }
    }

    if constexpr (std::same_as<Message, QueryHistory>) {
      if (reject_history) {
        throw EncodingError{"History transport is full"};
      }
    }

    if constexpr (std::same_as<Message, CopySelection>) {
      if (reject_copy) {
        throw EncodingError{"Copy transport is full"};
      }
    }

    std::vector<Byte> bytes(Codec::encodedSize(message));
    Codec::encode(message, bytes);
    sent.push_back(std::move(bytes));
  }

  template <typename Message>
  Message last() const {
    for (const auto &bytes : sent | std::views::reverse) {
      if (bytes.front() == static_cast<Byte>(MessageSchema<Message>::tag)) {
        storage.fill(0);
        DecodeStorage decoded{storage};

        return Codec::decode<Message>(bytes, decoded);
      }
    }

    throw std::runtime_error{"Expected request was not sent"};
  }

  std::size_t count(ClientTag tag) const {
    return static_cast<std::size_t>(std::count_if(sent.begin(), sent.end(), [&](const auto &bytes) {
      return bytes.front() == static_cast<Byte>(tag);
    }));
  }

  void willDetach(std::uint64_t pane_id) {
    detaching.push_back(pane_id);
  }

  std::string inputSince(std::size_t first_message) const {
    std::string input;
    for (const auto &bytes : std::span{sent}.subspan(first_message)) {
      if (bytes.front() == static_cast<Byte>(ClientTag::pane_input)) {
        input += textView(Codec::decode<PaneInput>(bytes).bytes);
      }
    }

    return input;
  }

  std::vector<std::vector<Byte>> sent;
  std::vector<std::uint64_t> detaching;
  bool reject_history = false;
  bool reject_copy = false;
  bool reject_editor = false;
  bool reject_create_pane = false;
  bool reject_create_tab = false;
  bool reject_forget_worktree = false;
  bool reject_next_pane_resize = false;
  std::optional<std::size_t> reject_input_after;
  std::optional<std::size_t> reject_detach_after;
  static constexpr std::size_t decode_capacity = 4096;
  mutable std::array<Byte, decode_capacity> storage{};

private:
  template <typename Message>
  void validatePaneDelivery() {
    if constexpr (std::same_as<Message, PaneInput>) {
      if (reject_input_after && count(ClientTag::pane_input) >= *reject_input_after) {
        throw EncodingError{"Pane input transport is full"};
      }
    }

    if constexpr (std::same_as<Message, DetachPane>) {
      if (reject_detach_after && count(ClientTag::detach_pane) >= *reject_detach_after) {
        throw EncodingError{"Detach transport is full"};
      }
    }

    if constexpr (std::same_as<Message, PaneResize>) {
      if (std::exchange(reject_next_pane_resize, false)) {
        throw EncodingError{"Resize transport is full"};
      }
    }
  }
};

template <typename Message, typename Client, ClientCommandHandler Handler>
auto deliver(Client &client, const Message &message, Handler &handler) {
  std::vector<Byte> bytes(Codec::encodedSize(message));
  Codec::encode(message, bytes);

  return client.consume(bytes, handler);
}

template <typename Message, typename Client>
auto deliver(Client &client, const Message &message) {
  UnsupportedClientCommand handler;

  return deliver(client, message, handler);
}

template <typename Client>
void deliverSingleCell(Client &client, FrameBody frame) {
  const std::array cells{Cell{.text = byteView("X")}};
  constexpr std::size_t cell_capacity = 64;
  std::array<Byte, cell_capacity> encoded{};
  const std::array spans{FrameSpan{.start = 0, .count = 1, .cells = CellRunCodec::encode(cells, encoded)}};
  const std::array<Byte, 1> flags{};
  frame.cols = frame.rows = 1;
  frame.text_metadata = TextMetadata{.row_flags = flags};
  frame.spans = spans;
  deliver(client, PaneFrame{frame});
}

template <typename Client>
void openFirstPane(Client &client, Transport &transport) {
  client.connected(1);
  require(transport.last<RequestRuntimeState>().interactive, "GUI must subscribe as an interactive client");
  deliver(client, ClientLayoutSnapshot{});
  const auto open = transport.last<OpenPane>();
  require(open.launch && !open.launch->arguments.empty(), "default launch must contain a shell");
  const TabLocation location{.workspace = WorkspaceLocation{.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};
  deliver(client, PaneOpened{.request_id = open.request_id, .pane_id = 1, .location = location, .created = true, .pane_generation = 1});
  const std::array<PaneDescriptor, 1> descriptors{{{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}}};
  deliver(client, TabSnapshot{.request_id = transport.last<RequestTabSnapshot>().request_id, .location = location, .panes = descriptors});
  const std::array tabs{TabDescriptor{.tab_id = location.tab_id, .pane_count = 1}};
  deliver(client, WorkspaceSnapshot{.request_id = transport.last<RequestWorkspaceSnapshot>().request_id, .workspace = location.workspace, .name = "project", .tabs = tabs});
}

}
