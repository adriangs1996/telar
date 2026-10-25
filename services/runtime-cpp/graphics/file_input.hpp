#pragma once

#include "child_file.hpp"
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
      if (const auto query = KittyFileQuery::parse(control)) {
        sink.ingest(bytes.subspan(emitted, start - emitted));
        answer(*query, path, storage_limit, sink);
        emitted = search_from;
        continue;
      }
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

  template <MediaInputSink Sink>
  static std::span<const std::uint8_t> stripQueries(std::span<const std::uint8_t> bytes, std::span<std::uint8_t> scratch, std::size_t limit, Sink &sink) {
    if (scratch.size() < bytes.size()) {
      return bytes;
    }

    const std::string_view text{reinterpret_cast<const char *>(bytes.data()), bytes.size()};
    std::size_t search_from = 0;
    std::size_t copied_until = 0;
    std::size_t kept = 0;
    while (const auto command = nextCommand(text, search_from)) {
      const auto query = KittyFileQuery::parse(command->control);
      if (!query) {
        continue;
      }

      answer(*query, command->path, limit, sink);
      const auto preceding = bytes.subspan(copied_until, command->start - copied_until);
      std::ranges::copy(preceding, scratch.data() + kept);
      kept += preceding.size();
      copied_until = search_from;
    }
    if (copied_until == 0) {
      return bytes;
    }

    const auto tail = bytes.subspan(copied_until);
    std::ranges::copy(tail, scratch.data() + kept);
    return scratch.first(kept + tail.size());
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
  static void answer(KittyFileQuery query, std::string_view path, std::size_t limit, Sink &sink) {
    const auto file = query.bytes <= limit ? GraphicsChildFile::open(path) : std::nullopt;
    const bool accepted = file && file->size >= query.bytes;
    std::array<char, 64> response;
    auto *end = std::copy_n("\x1b_Gi=", 5, response.data());
    end = std::to_chars(end, response.data() + response.size(), query.image_id).ptr;
    const std::string_view status = accepted ? ";OK\x1b\\" : ";EBADF:file not accepted\x1b\\";
    end = std::copy(status.begin(), status.end(), end);
    sink.reply({reinterpret_cast<const std::uint8_t *>(response.data()), static_cast<std::size_t>(end - response.data())});
  }

  template <MediaInputSink Sink>
  static bool forward(const Transmission &request, Sink &sink) {
    const auto file = GraphicsChildFile::open(request.path);
    if (!file || request.range.offset > file->size) {
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
