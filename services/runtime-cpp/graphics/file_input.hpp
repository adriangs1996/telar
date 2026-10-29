#pragma once

#include "child_file.hpp"
#include "temporary_path.hpp"
#include "kitty_file_control.hpp"
#include "kitty_framing.hpp"
#include <algorithm>
#include <charconv>

namespace telar::runtime {

template <typename Sink>
concept MediaInputSink = requires(Sink &sink, std::span<const std::uint8_t> bytes) {
  { sink.ingest(bytes) } -> std::same_as<void>;
  { sink.ingestEncodedChunk(bytes) } -> std::same_as<void>;
  { sink.reply(bytes) } -> std::same_as<void>;
};

class GraphicsFileInput {
public:
  template <MediaInputSink Sink>
  static void feed(std::span<const std::uint8_t> bytes, std::size_t storage_limit, Sink &sink) {
    const std::string_view text{reinterpret_cast<const char *>(bytes.data()), bytes.size()};
    std::size_t emitted = 0;
    std::size_t search_from = 0;
    while (const auto parsed = nextCommand(text, search_from)) {
      const auto &[start, control, path] = *parsed;
      const auto command = text.substr(start + introducer.size(), search_from - terminator.size() - start - introducer.size());
      if (control.size() > control_capacity || !std::ranges::all_of(command, [](unsigned char byte) { return KittyFraming::content(byte); })) {
        continue;
      }

      const auto range = KittyFileRange::parse(control);
      if (!range) {
        continue;
      }
      sink.ingest(bytes.subspan(emitted, start - emitted));
      emitted = start;
      if (forward(Transmission{control, path, *range, storage_limit}, sink)) {
        emitted = search_from;
      }
    }

    if (emitted != bytes.size()) {
      sink.ingest(bytes.subspan(emitted));
    }
  }

  // The native control parser owns this complete, non-query APC. Its
  // terminator is separate, so inspect the frame without copying its payload.
  template <MediaInputSink Sink>
  static void frame(std::span<const std::uint8_t> bytes, std::string_view ending, std::size_t storage_limit, Sink &sink) {
    if (bytes.size() >= introducer.size() && bytes[0] == 0x1b && bytes[2] == 'G') {
      const std::string_view body{reinterpret_cast<const char *>(bytes.data() + introducer.size()), bytes.size() - introducer.size()};
      const auto separator = body.find(';');
      if (separator != std::string_view::npos && separator <= control_capacity && std::ranges::all_of(body, [](unsigned char byte) { return KittyFraming::content(byte); })) {
        const auto control = body.substr(0, separator);
        if (const auto range = KittyFileRange::parse(control)) {
          if (forward(Transmission{control, body.substr(separator + 1), *range, storage_limit}, sink)) {
            return;
          }
        }
      }
    }
    sink.ingest(bytes);
    sink.ingest({reinterpret_cast<const std::uint8_t *>(ending.data()), ending.size()});
  }


private:
  struct Command {
    std::size_t start;
    std::string_view control;
    std::string_view path;
  };

  static std::optional<Command> nextCommand(std::string_view text, std::size_t &search_from) noexcept {
    for (;;) {
      const auto start = text.find(introducer, search_from);
      if (start == std::string_view::npos) {
        return std::nullopt;
      }
      const auto end = text.find(terminator, start + introducer.size());
      if (end == std::string_view::npos) {
        return std::nullopt;
      }

      search_from = end + terminator.size();
      const auto command = text.substr(start + introducer.size(), end - start - introducer.size());
      const auto separator = command.find(';');
      if (separator != std::string_view::npos && separator + 1 != command.size()) {
        return Command{start, command.substr(0, separator), command.substr(separator + 1)};
      }
    }
  }

  struct Transmission {
    std::string_view control;
    std::string_view path;
    KittyFileRange range;
    std::size_t limit;
  };

  template <MediaInputSink Sink>
  static bool forward(const Transmission &request, Sink &sink) {
    const auto file = GraphicsChildFile::open(request.path);
    if (!file || request.range.offset > file->size) {
      return false;
    }
    GraphicsTemporaryPath temporary{*file};
    if (request.range.temporary && !temporary.authorize().empty()) {
      return false;
    }

    const auto available = file->size - request.range.offset;
    const auto length = request.range.size.value_or(available);
    if (length == 0 || length > available || length > request.limit) {
      return false;
    }

    std::array<std::uint8_t, raw_chunk_bytes * chunks_per_read> raw;
    std::array<char, chunk_capacity> chunk;
    std::uint64_t sent = 0;
    while (sent < length) {
      auto batch = std::span{raw}.first(static_cast<std::size_t>(std::min<std::uint64_t>(raw.size(), length - sent)));
      if (!file->read(batch, request.range.offset + sent)) {
        batch = batch.first(std::min(batch.size(), raw_chunk_bytes));
        if (!file->read(batch, request.range.offset + sent)) {
          if (sent == 0) {
            return false;
          }

          constexpr std::string_view final_chunk = "\x1b_Gm=0;\x1b\\";
          sink.ingest({reinterpret_cast<const std::uint8_t *>(final_chunk.data()), final_chunk.size()});
          return true;
        }
      }

      while (!batch.empty()) {
        const auto bytes = batch.first(std::min(batch.size(), raw_chunk_bytes));
        const auto control = sent == 0 ? request.control : std::string_view{};
        sent += bytes.size();
        sink.ingestEncodedChunk(encodeChunk(chunk, control, bytes, sent < length));
        batch = batch.subspan(bytes.size());
      }
    }
    return true;
  }

  static std::span<const std::uint8_t> encodeChunk(std::span<char> chunk, std::string_view control, std::span<const std::uint8_t> raw, bool more) {
    auto *end = std::copy(introducer.begin(), introducer.end(), chunk.data());
    if (!control.empty()) {
      KittyControlFields fields{control};
      while (const auto field = fields.next()) {
        if (field->key == 't' || field->key == 'S' || field->key == 'O' || field->key == 'm') {
          continue;
        }
        *end++ = field->key;
        *end++ = '=';
        end = std::copy(field->value.begin(), field->value.end(), end);
        *end++ = ',';
      }
      end = std::copy_n("t=d,", 4, end);
    }

    end = std::copy_n(more ? "m=1;" : "m=0;", 4, end);
    end += base64::encode(raw, {end, static_cast<std::size_t>(chunk.data() + chunk.size() - end)}).value();
    end = std::copy(terminator.begin(), terminator.end(), end);
    return {reinterpret_cast<const std::uint8_t *>(chunk.data()), static_cast<std::size_t>(end - chunk.data())};
  }

  static constexpr std::string_view introducer = "\x1b_G";
  static constexpr std::string_view terminator = "\x1b\\";
  static constexpr std::size_t control_capacity = 512;
  static constexpr std::size_t raw_chunk_bytes = 3072;
  static constexpr std::size_t chunks_per_read = 16;
  static constexpr std::size_t encoded_chunk_bytes = 4096;
  static constexpr std::size_t chunk_capacity = introducer.size() + control_capacity + 9 + encoded_chunk_bytes + terminator.size();
};

}
