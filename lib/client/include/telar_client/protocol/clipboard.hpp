#pragma once

#include "../serializers/telar_messages.hpp"

namespace telar {

  struct CopySelection {
    std::uint64_t pane_id{};
    std::uint16_t start_x{};
    std::uint32_t start_y{};
    std::uint16_t end_x{};
    std::uint32_t end_y{};
    bool linewise{};
  };

  template <>
  struct MessageSchema<CopySelection>
      : Schema<Direction::client, ClientTag::copy_selection, Field<&CopySelection::pane_id, NonzeroU64, "pane_id">, Field<&CopySelection::start_x, u16, "start_x">, Field<&CopySelection::start_y, u32, "start_y">, Field<&CopySelection::end_x, u16, "end_x">, Field<&CopySelection::end_y, u32, "end_y">, Field<&CopySelection::linewise, BoolByte, "linewise">> {};

  struct PaneClipboard {
    std::uint64_t pane_id{};
    std::span<const Byte> bytes{};
  };

  template <>
  struct MessageSchema<PaneClipboard>
      : Schema<Direction::server, ServerTag::pane_clipboard, Field<&PaneClipboard::pane_id, NonzeroU64, "pane_id">, Field<&PaneClipboard::bytes, SizedBytes<u32, 1048576>, "bytes">> {};

  inline constexpr std::size_t clipboard_content_limit = 1024 * 1024;

  struct ClipboardTicket {
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    std::uint64_t client_generation{};
    std::uint64_t nonce{};

    bool operator==(const ClipboardTicket&) const = default;
  };

  template <>
  struct BodySchema<ClipboardTicket>
      : Serializer<Field<&ClipboardTicket::pane_id, NonzeroU64, "pane_id">, Field<&ClipboardTicket::pane_generation, NonzeroU64, "pane_generation">, Field<&ClipboardTicket::client_generation, NonzeroU64, "client_generation">, Field<&ClipboardTicket::nonce, NonzeroU64, "nonce">> {};

  struct ClipboardRepresentation {
    std::string_view mime;
    std::span<const Byte> data;
  };

  template <>
  struct BodySchema<ClipboardRepresentation>
      : Serializer<Field<&ClipboardRepresentation::mime, Utf8Text16<256>, "mime">, Field<&ClipboardRepresentation::data, SizedBytes<u32, clipboard_content_limit>, "data">> {};

  void validateClipboardContents(std::span<const ClipboardRepresentation> contents);

  struct ClipboardDesktopRequest {
    ClipboardTicket ticket;
    bool write = false;
    bool primary = false;
    bool prompt = false;
    bool listing = false;
    bool rememberable = false;
    std::string_view name{};
    std::span<const std::string_view> mimes{};
    std::span<const ClipboardRepresentation> contents{};

    void validate() const;
  };

  template <>
  struct MessageSchema<ClipboardDesktopRequest>
      : Schema<Direction::server, ServerTag::clipboard_desktop_request, Field<&ClipboardDesktopRequest::ticket, ValueCodec<ClipboardTicket>, "ticket">, Field<&ClipboardDesktopRequest::write, BoolByte, "write">, Field<&ClipboardDesktopRequest::primary, BoolByte, "primary">, Field<&ClipboardDesktopRequest::prompt, BoolByte, "prompt">, Field<&ClipboardDesktopRequest::listing, BoolByte, "listing">, Field<&ClipboardDesktopRequest::rememberable, BoolByte, "rememberable">, Field<&ClipboardDesktopRequest::name, Utf8Text16<256>, "name">, Field<&ClipboardDesktopRequest::mimes, CountedSpan<u8, Utf8Text16<256>, 4>, "mimes">, Field<&ClipboardDesktopRequest::contents, CountedSpan<u8, ValueCodec<ClipboardRepresentation>, 128>, "contents">> {};

  enum class ClipboardDesktopStatus : Byte {
    success,
    denied,
    unsupported,
    failure,
  };

  struct CompleteClipboardDesktop {
    ClipboardTicket ticket;
    ClipboardDesktopStatus status = ClipboardDesktopStatus::denied;
    bool remember = false;
    bool prepared = false;
    std::span<const ClipboardRepresentation> contents{};
    std::span<const std::string_view> available{};

    void validate() const;
  };

  template <>
  struct MessageSchema<CompleteClipboardDesktop>
      : Schema<Direction::client, ClientTag::complete_clipboard_desktop, Field<&CompleteClipboardDesktop::ticket, ValueCodec<ClipboardTicket>, "ticket">, Field<&CompleteClipboardDesktop::status, EnumByte<ClipboardDesktopStatus, 3>, "status">, Field<&CompleteClipboardDesktop::remember, BoolByte, "remember">, Field<&CompleteClipboardDesktop::prepared, BoolByte, "prepared">, Field<&CompleteClipboardDesktop::contents, CountedSpan<u8, ValueCodec<ClipboardRepresentation>, 4>, "contents">, Field<&CompleteClipboardDesktop::available, CountedSpan<u8, Utf8Text16<256>, 16>, "available">> {};

  struct ClipboardDesktopExecute {
    ClipboardTicket ticket;
  };

  template <>
  struct MessageSchema<ClipboardDesktopExecute>
      : Schema<Direction::server, ServerTag::clipboard_desktop_execute, Field<&ClipboardDesktopExecute::ticket, ValueCodec<ClipboardTicket>, "ticket">> {};

  struct CancelClipboardDesktop {
    ClipboardTicket ticket;
  };

  template <>
  struct MessageSchema<CancelClipboardDesktop>
      : Schema<Direction::server, ServerTag::clipboard_desktop_cancel, Field<&CancelClipboardDesktop::ticket, ValueCodec<ClipboardTicket>, "ticket">> {};

  struct PastePaneClipboard {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    bool primary = false;
    bool listing_only = false;
    std::span<const Byte> text;
    std::span<const std::string_view> available;
  };

  template <>
  struct MessageSchema<PastePaneClipboard>
      : Schema<Direction::client, ClientTag::paste_pane_clipboard, Field<&PastePaneClipboard::request_id, NonzeroU64, "request_id">, Field<&PastePaneClipboard::pane_id, NonzeroU64, "pane_id">, Field<&PastePaneClipboard::pane_generation, NonzeroU64, "pane_generation">, Field<&PastePaneClipboard::primary, BoolByte, "primary">, Field<&PastePaneClipboard::listing_only, BoolByte, "listing_only">, Field<&PastePaneClipboard::text, SizedBytes<u32, clipboard_content_limit>, "text">, Field<&PastePaneClipboard::available, CountedSpan<u8, Utf8Text16<256>, 16>, "available">> {};

  inline constexpr std::size_t runtime_clipboard_max_bytes = std::size_t{32} * 1024 * 1024;
  inline constexpr std::size_t runtime_clipboard_chunk_bytes = 64 * 1024;

  // A zero transfer id starts a capture. Subsequent requests pull the next chunk
  // of that immutable capture over the same connection.
  struct ReadRuntimeClipboard {
    std::uint64_t request_id = 0;
    std::uint64_t transfer_id = 0;
    std::uint64_t offset = 0;

    void validate() const;
  };

  template <>
  struct MessageSchema<ReadRuntimeClipboard>
      : Schema<Direction::client, ClientTag::read_runtime_clipboard, Field<&ReadRuntimeClipboard::request_id, NonzeroU64, "request_id">, Field<&ReadRuntimeClipboard::transfer_id, u64, "transfer_id">, Field<&ReadRuntimeClipboard::offset, u64, "offset">> {};

  struct RuntimeClipboardChunk {
    std::uint64_t request_id = 0;
    std::uint64_t transfer_id = 0;
    std::uint64_t offset = 0;
    std::uint64_t total_bytes = 0;
    std::string_view mime;
    std::span<const Byte> bytes;

    void validate() const;
  };

  template <>
  struct MessageSchema<RuntimeClipboardChunk>
      : Schema<Direction::server, ServerTag::runtime_clipboard_chunk, Field<&RuntimeClipboardChunk::request_id, NonzeroU64, "request_id">, Field<&RuntimeClipboardChunk::transfer_id, NonzeroU64, "transfer_id">, Field<&RuntimeClipboardChunk::offset, u64, "offset">, Field<&RuntimeClipboardChunk::total_bytes, u64, "total_bytes">, Field<&RuntimeClipboardChunk::mime, Utf8Text16<256>, "mime">, Field<&RuntimeClipboardChunk::bytes, SizedBytes<u32, runtime_clipboard_chunk_bytes>, "bytes">> {};

} // namespace telar
