module;
#include <cstddef>
#include <cstdint>

export module telar.gui.application.tests.session_fixture;

import std;
import telar.testing;
import telar.base.memory.allocators;
import telar.gui.application;
import telar.wire.clients;
import telar.wire.clipboard;
import telar.wire.editor;
import telar.wire.history;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.worktrees;
import telar.wire.vocabulary;
import telar.gui.foundation.system;
import telar.base.ds;

export {
  namespace telar::gui::application::tests::session_fixture {

    class Transport : public application::RuntimeTransport {
    public:
      std::span<Byte> buffer(std::size_t size) override {
        buffer_.resize(size);

        return buffer_;
      }

      void send(std::span<const Byte> message) override {
        const auto tag = static_cast<ClientTag>(message.front());

        validatePaneDelivery(tag);
        if (tag == MessageSchema<OpenEditor>::tag && reject_editor) {
          throw EncodingError{"Editor transport is full"};
        }

        if (tag == MessageSchema<CreatePane>::tag && reject_create_pane) {
          throw EncodingError{"Pane transport is full"};
        }

        if (tag == MessageSchema<CreateTab>::tag && reject_create_tab) {
          throw EncodingError{"Tab transport is full"};
        }

        if (tag == MessageSchema<ForgetWorktree>::tag && reject_forget_worktree) {
          throw EncodingError{"Worktree transport is full"};
        }

        if (tag == MessageSchema<QueryHistory>::tag && reject_history) {
          throw EncodingError{"History transport is full"};
        }

        if (tag == MessageSchema<CopySelection>::tag && reject_copy) {
          throw EncodingError{"Copy transport is full"};
        }

        sent.emplace_back(message.begin(), message.end());
      }

      template <typename Message>
      Message last() const {
        for (const auto& bytes : sent | std::views::reverse) {
          if (bytes.front() == static_cast<Byte>(MessageSchema<Message>::tag)) {
            storage.fill(0);
            DecodeStorage decoded{storage};

            return Codec::decode<Message>(bytes, decoded);
          }
        }

        throw std::runtime_error{"Expected request was not sent"};
      }

      std::size_t count(ClientTag tag) const {
        return static_cast<std::size_t>(std::count_if(sent.begin(), sent.end(), [&](const auto& bytes) {
          return bytes.front() == static_cast<Byte>(tag);
        }));
      }

      void willDetach(std::uint64_t pane_id) override {
        detaching.push_back(pane_id);
      }

      std::string inputSince(std::size_t first_message) const {
        std::string input;

        for (const auto& bytes : std::span{sent}.subspan(first_message)) {
          if (bytes.front() == static_cast<Byte>(ClientTag::pane_input)) {
            input += textView(Codec::decode<PaneInput>(bytes).bytes);
          }
        }

        return input;
      }

      // The commands run at a pane's prompt since a message, as the runtime receives them.
      std::vector<std::string> commandsSince(std::size_t first_message) const {
        std::vector<std::string> commands;

        for (const auto& bytes : std::span{sent}.subspan(first_message)) {
          if (bytes.front() == static_cast<Byte>(ClientTag::pane_command)) {
            commands.emplace_back(textView(Codec::decode<PaneCommand>(bytes).text));
          }
        }

        return commands;
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
      ds::Option<std::size_t> reject_input_after;
      ds::Option<std::size_t> reject_detach_after;
      static constexpr std::size_t decode_capacity = 4096;
      mutable std::array<Byte, decode_capacity> storage{};

    private:
      std::vector<Byte> buffer_;

      void validatePaneDelivery(ClientTag tag) {
        if (tag == MessageSchema<PaneInput>::tag && reject_input_after && count(ClientTag::pane_input) >= *reject_input_after) {
          throw EncodingError{"Pane input transport is full"};
        }

        if (tag == MessageSchema<DetachPane>::tag && reject_detach_after && count(ClientTag::detach_pane) >= *reject_detach_after) {
          throw EncodingError{"Detach transport is full"};
        }

        if (tag == MessageSchema<PaneResize>::tag && std::exchange(reject_next_pane_resize, false)) {
          throw EncodingError{"Resize transport is full"};
        }
      }
    };

    template <Allocator Upstream>
    struct AdaptedMemory {
      MemoryAdapter<Upstream> adapter;
    };

    // A session over a test's allocator, which it puts behind Memory.
    template <Allocator Upstream>
    class TestSession : private AdaptedMemory<Upstream>, public application::Session {
    public:
      TestSession(Upstream& memory, application::RuntimeTransport& transport, application::MonotonicNow now = &system::AwakeClock::nowNanoseconds)
          : AdaptedMemory<Upstream>{MemoryAdapter<Upstream>{memory}},
            application::Session(this->adapter, transport, now) {}

      TestSession(Upstream& memory, application::RuntimeTransport& transport, application::HostEffects& effects, application::MonotonicNow now = &system::AwakeClock::nowNanoseconds)
          : AdaptedMemory<Upstream>{MemoryAdapter<Upstream>{memory}},
            application::Session(this->adapter, transport, effects, now) {}
    };

    // Runs a test's callable as the session's command handler.
    template <typename Handler>
    class CommandHandler final : public application::ClientCommandHandler {
    public:
      explicit CommandHandler(Handler& handler)
          : handler_(handler) {}

      void operator()(const ClientCommand& message, CompleteClientCommand& reply) const override {
        handler_(message, reply);
      }

    private:
      Handler& handler_;
    };

    template <typename Message, typename Client, typename Handler>
    auto deliver(Client& client, const Message& message, Handler& handler) {
      std::vector<Byte> bytes(Codec::encodedSize(message));

      Codec::encode(message, bytes);
      if constexpr (std::derived_from<Handler, application::ClientCommandHandler>) {
        return client.consume(bytes, handler);
      } else {
        const CommandHandler<Handler> adapter{handler};

        return client.consume(bytes, adapter);
      }
    }

    template <typename Message, typename Client>
    auto deliver(Client& client, const Message& message) {
      application::UnsupportedClientCommand handler;

      return deliver(client, message, handler);
    }

    template <typename Client>
    void deliverSingleCell(Client& client, FrameBody frame) {
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
    void openFirstPane(Client& client, Transport& transport) {
      client.connected(1);
      telar::testing::check(transport.last<RequestRuntimeState>().interactive, "GUI must subscribe as an interactive client");
      deliver(client, ClientLayoutSnapshot{});
      const auto open = transport.last<OpenPane>();

      telar::testing::check(open.launch && !open.launch->arguments.empty(), "default launch must contain a shell");
      const TabLocation location{.workspace = WorkspaceLocation{.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};

      deliver(client, PaneOpened{.request_id = open.request_id, .pane_id = 1, .location = location, .created = true, .pane_generation = 1});
      const std::array<PaneDescriptor, 1> descriptors{{{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}}};

      deliver(client, TabSnapshot{.request_id = transport.last<RequestTabSnapshot>().request_id, .location = location, .panes = descriptors});
      const std::array tabs{TabDescriptor{.tab_id = location.tab_id, .pane_count = 1}};

      deliver(client, WorkspaceSnapshot{.request_id = transport.last<RequestWorkspaceSnapshot>().request_id, .workspace = location.workspace, .name = "project", .tabs = tabs});
    }

  }
}
