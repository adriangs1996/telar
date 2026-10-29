#pragma once

namespace telar {

inline constexpr std::size_t clipboard_content_limit = 1024 * 1024;

struct ClipboardTicket {
  std::uint64_t pane_id{};
  std::uint64_t pane_generation{};
  std::uint64_t client_generation{};
  std::uint64_t nonce{};

  bool operator==(const ClipboardTicket &) const = default;
};

template <>
struct BodySchema<ClipboardTicket>
    : Serializer<Field<&ClipboardTicket::pane_id, NonzeroU64, "pane_id">,
                 Field<&ClipboardTicket::pane_generation, NonzeroU64, "pane_generation">,
                 Field<&ClipboardTicket::client_generation, NonzeroU64, "client_generation">,
                 Field<&ClipboardTicket::nonce, NonzeroU64, "nonce">> {};

struct ClipboardRepresentation {
  std::string_view mime;
  std::span<const Byte> data;
};

template <>
struct BodySchema<ClipboardRepresentation>
    : Serializer<Field<&ClipboardRepresentation::mime, Utf8Text16<256>, "mime">,
                 Field<&ClipboardRepresentation::data, SizedBytes<u32, clipboard_content_limit>, "data">> {};

inline void validateClipboardContents(std::span<const ClipboardRepresentation> contents) {
  std::size_t size = 0;
  for (const auto &content : contents) {
    if (content.mime.empty() || content.mime.contains('\0') || content.data.size() > clipboard_content_limit - size) {
      throw EncodingError{"Invalid clipboard representation or aggregate size"};
    }
    size += content.data.size();
  }
}

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

  void validate() const {
    if (mimes.size() > 4 || contents.size() > 128) {
      throw EncodingError{"Invalid clipboard request bounds"};
    }
    validateClipboardContents(contents);
    if (!write && !contents.empty()) {
      throw EncodingError{"Clipboard read request contains write data"};
    }
  }
};

template <>
struct MessageSchema<ClipboardDesktopRequest>
    : Schema<Direction::server,
             ServerTag::clipboard_desktop_request,
             Field<&ClipboardDesktopRequest::ticket, ValueCodec<ClipboardTicket>, "ticket">,
             Field<&ClipboardDesktopRequest::write, BoolByte, "write">,
             Field<&ClipboardDesktopRequest::primary, BoolByte, "primary">,
             Field<&ClipboardDesktopRequest::prompt, BoolByte, "prompt">,
             Field<&ClipboardDesktopRequest::listing, BoolByte, "listing">,
             Field<&ClipboardDesktopRequest::rememberable, BoolByte, "rememberable">,
             Field<&ClipboardDesktopRequest::name, Utf8Text16<256>, "name">,
             Field<&ClipboardDesktopRequest::mimes, CountedSpan<u8, Utf8Text16<256>, 4>, "mimes">,
             Field<&ClipboardDesktopRequest::contents, CountedSpan<u8, ValueCodec<ClipboardRepresentation>, 128>, "contents">> {};

enum class ClipboardDesktopStatus : Byte {
  success,
  denied,
  unsupported,
  failure
};

struct CompleteClipboardDesktop {
  ClipboardTicket ticket;
  ClipboardDesktopStatus status = ClipboardDesktopStatus::denied;
  bool remember = false;
  bool prepared = false;
  std::span<const ClipboardRepresentation> contents{};
  std::span<const std::string_view> available{};

  void validate() const {
    if (contents.size() > 4 || available.size() > 16 || (prepared && (!contents.empty() || !available.empty()))) {
      throw EncodingError{"Invalid clipboard completion phase or bounds"};
    }
    validateClipboardContents(contents);
    if (status != ClipboardDesktopStatus::success && (!contents.empty() || !available.empty() || remember)) {
      throw EncodingError{"Unsuccessful clipboard completion carries data"};
    }
  }
};

template <>
struct MessageSchema<CompleteClipboardDesktop>
    : Schema<Direction::client,
             ClientTag::complete_clipboard_desktop,
             Field<&CompleteClipboardDesktop::ticket, ValueCodec<ClipboardTicket>, "ticket">,
             Field<&CompleteClipboardDesktop::status, EnumByte<ClipboardDesktopStatus, 3>, "status">,
             Field<&CompleteClipboardDesktop::remember, BoolByte, "remember">,
             Field<&CompleteClipboardDesktop::prepared, BoolByte, "prepared">,
             Field<&CompleteClipboardDesktop::contents, CountedSpan<u8, ValueCodec<ClipboardRepresentation>, 4>, "contents">,
             Field<&CompleteClipboardDesktop::available, CountedSpan<u8, Utf8Text16<256>, 16>, "available">> {};

struct ClipboardDesktopExecute {
  ClipboardTicket ticket;
};

template <>
struct MessageSchema<ClipboardDesktopExecute>
    : Schema<Direction::server, ServerTag::clipboard_desktop_execute,
             Field<&ClipboardDesktopExecute::ticket, ValueCodec<ClipboardTicket>, "ticket">> {};

struct CancelClipboardDesktop {
  ClipboardTicket ticket;
};

template <>
struct MessageSchema<CancelClipboardDesktop>
    : Schema<Direction::server, ServerTag::clipboard_desktop_cancel,
             Field<&CancelClipboardDesktop::ticket, ValueCodec<ClipboardTicket>, "ticket">> {};

struct PastePaneClipboard {
  std::uint64_t request_id{};
  std::uint64_t pane_id{};
  std::uint64_t pane_generation{};
  bool primary = false;
  std::span<const Byte> text;
  std::span<const std::string_view> available;
};

template <>
struct MessageSchema<PastePaneClipboard>
    : Schema<Direction::client,
             ClientTag::paste_pane_clipboard,
             Field<&PastePaneClipboard::request_id, NonzeroU64, "request_id">,
             Field<&PastePaneClipboard::pane_id, NonzeroU64, "pane_id">,
             Field<&PastePaneClipboard::pane_generation, NonzeroU64, "pane_generation">,
             Field<&PastePaneClipboard::primary, BoolByte, "primary">,
             Field<&PastePaneClipboard::text, SizedBytes<u32, clipboard_content_limit>, "text">,
             Field<&PastePaneClipboard::available, CountedSpan<u8, Utf8Text16<256>, 16>, "available">> {};

}
