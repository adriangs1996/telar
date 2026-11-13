#pragma once

namespace telar {

  inline constexpr std::size_t runtime_clipboard_max_bytes = std::size_t{32} * 1024 * 1024;
  inline constexpr std::size_t runtime_clipboard_chunk_bytes = 64 * 1024;

  // A zero transfer id starts a capture. Subsequent requests pull the next chunk
  // of that immutable capture over the same connection.
  struct ReadRuntimeClipboard {
    std::uint64_t request_id = 0;
    std::uint64_t transfer_id = 0;
    std::uint64_t offset = 0;

    void validate() const {
      if (offset > runtime_clipboard_max_bytes || (transfer_id == 0 && offset != 0)) {
        throw EncodingError{"Invalid clipboard offset"};
      }
    }
  };

  template <>
  struct MessageSchema<ReadRuntimeClipboard>
      : Schema<Direction::client,
               ClientTag::read_runtime_clipboard,
               Field<&ReadRuntimeClipboard::request_id, NonzeroU64, "request_id">,
               Field<&ReadRuntimeClipboard::transfer_id, u64, "transfer_id">,
               Field<&ReadRuntimeClipboard::offset, u64, "offset">> {};

  struct RuntimeClipboardChunk {
    std::uint64_t request_id = 0;
    std::uint64_t transfer_id = 0;
    std::uint64_t offset = 0;
    std::uint64_t total_bytes = 0;
    std::string_view mime;
    std::span<const Byte> bytes;

    void validate() const {
      if (mime.empty() || total_bytes > runtime_clipboard_max_bytes || offset > total_bytes ||
          bytes.size() > total_bytes - offset || (bytes.empty() && offset != total_bytes)) {
        throw EncodingError{"Invalid clipboard chunk"};
      }
    }
  };

  template <>
  struct MessageSchema<RuntimeClipboardChunk>
      : Schema<Direction::server,
               ServerTag::runtime_clipboard_chunk,
               Field<&RuntimeClipboardChunk::request_id, NonzeroU64, "request_id">,
               Field<&RuntimeClipboardChunk::transfer_id, NonzeroU64, "transfer_id">,
               Field<&RuntimeClipboardChunk::offset, u64, "offset">,
               Field<&RuntimeClipboardChunk::total_bytes, u64, "total_bytes">,
               Field<&RuntimeClipboardChunk::mime, Utf8Text16<256>, "mime">,
               Field<&RuntimeClipboardChunk::bytes,
                     SizedBytes<u32, runtime_clipboard_chunk_bytes>,
                     "bytes">> {};

} // namespace telar
