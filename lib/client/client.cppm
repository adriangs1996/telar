module;
#include "tbc/annotations.hpp"
#include "telar_wire/codecs/telar_annotations.hpp"

export module telar.client;

import std;
import telar.tbc;

import telar.base.text.utf8;
import telar.wire.vocabulary;
import telar.sys.posix;
import telar.sys.socket;
import telar.base.ds;

// The connection reports request failures with it; the rest of the wire
// vocabulary stays with telar.wire.vocabulary.
export namespace telar::runtime {
  using telar::runtime::RequestError;
}

// Interface: telar_client/serializers/telar_handshake.cppm
export {
  namespace telar {

    inline constexpr std::size_t schema_id_bytes = 8;

    using SchemaId = ds::Array<Byte, schema_id_bytes>;

    namespace handshake {

      inline constexpr ds::Array<Byte, 8> magic{
          'T',
          'E',
          'L',
          'A',
          'R',
          'I',
          'P',
          'C',
      };

      // cqp00002 added PaneShell, PaneGit, PaneBlocks, word completion and command specs;
      // cqp00003 added ReadPaneRows, PaneRows, PaneScrollback, SearchPaneRows, PaneCommand and
      // ConfigureShellPrompt; cqp00004 added PaneDocument; cqp00005 added the editor colors to
      // ConfigureTerminalColors, ReadPaneTheme and PaneTheme; cqp00006 added QueryMonitor,
      // MonitorSnapshot, RequestProcessSignal and RequestProcessPriority; cqp00007 added
      // QueryHistoryWorkspaces and HistoryWorkspaces; cqp00008 adds the editor pane: CreateNvimPane,
      // NvimInput, NvimPaste, NvimMouse, NvimFocus, NvimPromptReply, NvimOpen, PaneKindNotice,
      // NvimGrid, NvimFrame, NvimCmdline, NvimPopupMenu, NvimMessageList, NvimTabLine and
      // NvimPrompt, and the failure a request answers for a pane of another kind. Peers without them reject the messages.
      inline constexpr SchemaId schema_id{'c', 'q', 'p', '0', '0', '0', '0', '8'};

      // The schemas a client of this build can speak with a runtime, oldest first. Each added
      // messages to the one before it and left the layouts of the others alone, so a client that
      // sends an older runtime only the requests it knows speaks its dialect. The last is this
      // build's. A new schema joins the enum, dialect_schemas and, for each request it adds, since.
      enum class Dialect : std::uint8_t {
        schema87,
        cqp00002,
        cqp00003,
        cqp00004,
        cqp00005,
        cqp00006,
        cqp00007,
        cqp00008,
      };

      inline constexpr Dialect current_dialect = Dialect::cqp00008;

      inline constexpr ds::Array<SchemaId, 8> dialect_schemas{
          SchemaId{'8', '7', '6', 'b', '4', '8', '0', 'd'},
          SchemaId{'c', 'q', 'p', '0', '0', '0', '0', '2'},
          SchemaId{'c', 'q', 'p', '0', '0', '0', '0', '3'},
          SchemaId{'c', 'q', 'p', '0', '0', '0', '0', '4'},
          SchemaId{'c', 'q', 'p', '0', '0', '0', '0', '5'},
          SchemaId{'c', 'q', 'p', '0', '0', '0', '0', '6'},
          SchemaId{'c', 'q', 'p', '0', '0', '0', '0', '7'},
          schema_id,
      };

      [[nodiscard]] constexpr const SchemaId& schemaOf(Dialect dialect) noexcept {
        return dialect_schemas.at(std::to_underlying(dialect));
      }

      // The dialect of a runtime that answers with `schema`; nothing for one this build cannot speak.
      [[nodiscard]] constexpr ds::Option<Dialect> dialectOf(const SchemaId& schema) noexcept {
        for (std::size_t index = 0; index < dialect_schemas.size(); ++index) {
          if (dialect_schemas.at(index) == schema) {
            return static_cast<Dialect>(index);
          }
        }

        return ds::none;
      }

      // The first dialect whose runtime understands `tag`: what each schema added, in one place. A
      // request no case names is one every dialect has.
      [[nodiscard]] constexpr Dialect since(ClientTag tag) noexcept {
        switch (tag) {
        case ClientTag::hold_tab:
          return Dialect::cqp00002;
        case ClientTag::read_pane_rows:
        case ClientTag::search_pane_rows:
        case ClientTag::pane_command:
        case ClientTag::configure_shell_prompt:
          return Dialect::cqp00003;
        // Its layout gained the editor colors with the schema that added ReadPaneTheme.
        case ClientTag::configure_terminal_colors:
        case ClientTag::read_pane_theme:
          return Dialect::cqp00005;
        case ClientTag::query_monitor:
        case ClientTag::request_process_signal:
        case ClientTag::request_process_priority:
          return Dialect::cqp00006;
        case ClientTag::query_history_workspaces:
          return Dialect::cqp00007;
        case ClientTag::create_nvim_pane:
        case ClientTag::nvim_input:
        case ClientTag::nvim_paste:
        case ClientTag::nvim_mouse:
        case ClientTag::nvim_focus:
        case ClientTag::nvim_prompt_reply:
        case ClientTag::nvim_open:
          return Dialect::cqp00008;
        default:
          return Dialect::schema87;
        }
      }

      // Whether a runtime of dialect `peer` understands `tag`.
      [[nodiscard]] constexpr bool speaks(Dialect peer, ClientTag tag) noexcept {
        return peer >= since(tag);
      }

    } // namespace handshake

    enum class HandshakeTag : Byte {
      client_hello = 1,
      server_accept = 2,
      server_reject = 3,
    };

    enum class HandshakeRejectReason : Byte {
      incompatible_schema = 1,
      client_limit_reached = 2,
    };

    struct ClientHello {
      SchemaId schema = handshake::schema_id;
    };

    struct ServerAccept {
      SchemaId schema;
    };

    struct ServerReject {
      HandshakeRejectReason reason;
      SchemaId expected_schema;
    };

    using HandshakeResponse = std::variant<ServerAccept, ServerReject>;

    struct HandshakeReasonByte {
      static constexpr std::size_t width = u8::width;

      static HandshakeRejectReason validate(HandshakeRejectReason reason) TELAR_THROWS(EncodingError);

      static void encode(HandshakeRejectReason reason, std::span<Byte>& output) TELAR_THROWS(EncodingError);

      static HandshakeRejectReason decode(std::span<const Byte>& input) TELAR_THROWS(EncodingError);
    };

    template <Direction Side, HandshakeTag Tag, typename... Fields>
    struct HandshakeLayout : Schema<Side, Tag, Fields...> {
      static constexpr auto magic = handshake::magic;
      static constexpr std::size_t payload_size =
          magic.size() + Schema<Side, Tag, Fields...>::payload_size;

#ifdef TELAR_DEBUG
      template <typename Message>
      static void prettyPrint(const Message& message, std::FILE* output = stderr);
#endif
    };

    using SchemaIdCodec = FixedBytes<SchemaId{}.size()>;

    template <typename Message>
    struct HandshakeSchema;

    template <>
    struct HandshakeSchema<ClientHello>
        : HandshakeLayout<Direction::client, HandshakeTag::client_hello, Field<&ClientHello::schema, SchemaIdCodec, "schema">> {};

    template <>
    struct HandshakeSchema<ServerAccept>
        : HandshakeLayout<Direction::server, HandshakeTag::server_accept, Field<&ServerAccept::schema, SchemaIdCodec, "schema">> {};

    template <>
    struct HandshakeSchema<ServerReject>
        : HandshakeLayout<Direction::server, HandshakeTag::server_reject, Field<&ServerReject::reason, HandshakeReasonByte, "reason">, Field<&ServerReject::expected_schema, SchemaIdCodec, "expected_schema">> {};

  } // namespace telar
}

export {
  namespace telar {

    struct HandshakeCodec {
      static constexpr std::size_t max_message_size = HandshakeSchema<ServerReject>::payload_size;

      template <typename Message>
      static ds::Array<Byte, HandshakeSchema<Message>::payload_size> encode(const Message& message) TELAR_THROWS(EncodingError);

      template <typename Message>
      static Message decode(std::span<const Byte> input) TELAR_THROWS(EncodingError);

      static HandshakeResponse decodeResponse(std::span<const Byte> input) TELAR_THROWS(EncodingError);

#ifdef TELAR_DEBUG
      template <typename Message>
      static void prettyPrint(const Message& message, std::FILE* output = stderr);
#endif

    private:
      static constexpr std::size_t header_size = handshake::magic.size() + u8::width;

      static HandshakeTag decodeHeader(std::span<const Byte>& input) TELAR_THROWS(EncodingError);

      template <typename Message>
      static Message decodeBody(std::span<const Byte> input) TELAR_THROWS(EncodingError);
    };

  } // namespace telar
}

// The handshake's sizes on the wire, which a peer of any build agrees on.
namespace telar::handshake {

  inline constexpr std::size_t hello_bytes = 17;
  inline constexpr std::size_t reject_bytes = 18;

  static_assert(HandshakeSchema<ClientHello>::payload_size == hello_bytes);
  static_assert(HandshakeSchema<ServerAccept>::payload_size == hello_bytes);
  static_assert(HandshakeSchema<ServerReject>::payload_size == reject_bytes);

}

// Interface: telar_client/codecs.cppm
export {
}

// Interface: telar_client/serializers.cppm
export {
}

// Interface: telar_client/telar_client.cppm
export {
  namespace telar {

    struct SocketError final : std::exception {
      explicit SocketError(const char* message);

      [[nodiscard]] const char* what() const noexcept override;

    private:
      const char* message_;
    };

    // Owns its socket: closed when the client goes, moved but never copied, and never inherited
    // by a program the process runs.
    class Client final {
    public:
      Client() = default;
      Client(const Client&) = delete;
      Client& operator=(const Client&) = delete;

      Client(Client&& other) noexcept;
      Client& operator=(Client&& other) noexcept;
      ~Client();

      static Client init(const char* socket_path) TELAR_THROWS(SocketError);

      void handshake() TELAR_THROWS(std::exception);

      void deinit();

      template <typename Message>
      TBC_GENERIC inline void send(const Message& message) {
        using Schema = MessageSchema<Message>;
        static_assert(Schema::direction == Direction::client, "Can only send Client Messages");

        sendFrame(Codec::encode(message));
      }

      template <typename Message>
      TBC_GENERIC inline void send(const Message& message, std::span<Byte> frame_buffer) {
        static_assert(MessageSchema<Message>::direction == Direction::client, "Can only send Client Messages");

        if (frame_buffer.size() < frame_prefix_size) {
          throw EncodingError{"Frame buffer too small"};
        }

        const auto payload = Codec::encode(message, frame_buffer.subspan(frame_prefix_size));
        auto prefix = frame_buffer.first(frame_prefix_size);

        u32::encode(static_cast<std::uint32_t>(payload.size()), prefix);
        writeAll(frame_buffer.first(frame_prefix_size + payload.size()));
      }

      tbc::val_a<std::span<const Byte>> receiveFrame(tbc::val_a<std::span<Byte>> buffer) TELAR_THROWS(SocketError);

      [[nodiscard]] int descriptor() const noexcept;

      void interrupt() const noexcept;

    private:
      static constexpr timeval io_timeout{
          .tv_sec = 30,
          .tv_usec = 0,
      };

      template <std::size_t N>
      TBC_GENERIC inline void sendFrame(const ds::Array<Byte, N>& payload) TELAR_THROWS(SocketError) {
        static_assert(N > 0 && N <= max_payload_size, "Invalid runtime frame length");
        ds::Array<Byte, frame_prefix_size + N> frame{};
        std::span<Byte> output = frame.viewMut();

        u32::encode(static_cast<std::uint32_t>(payload.size()), output);

        std::ranges::copy(payload.view(), output.begin());
        writeAll(frame.view());
      }

      void writeAll(std::span<const std::uint8_t> bytes) const TELAR_THROWS(SocketError);

      void readAll(std::span<std::uint8_t> bytes) const TELAR_THROWS(SocketError);

      sockaddr_un address_ = {};
      int fd_ = -1;
    };

  } // namespace telar
}

// Interface: telar_client/telar.cppm
export {
}
