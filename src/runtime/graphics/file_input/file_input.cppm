module;
#include "tbc/view.hpp"
#include <unistd.h>
#include <cerrno>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <cstdio>
#include <cstdlib>
#include <sys/mman.h>
#include <new>

#include <cstddef>
#include <cstdint>



#include <cstring>

export module telar.runtime.graphics.file_input;

import std;

import telar.base.diagnostics;
import telar.base.memory;
import telar.base.text;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.graphics.kitty;


// Interface: graphics/atomic_frame.cppm
export {
namespace telar::runtime {

enum class GraphicsInputMedium {
  shared_memory,
  file
};

struct AtomicFrameKey {
  std::uint32_t image_id;
  std::uint32_t placement_id;

  bool operator==(const AtomicFrameKey &) const noexcept = default;
};

struct AtomicFrameControl {
  AtomicFrameKey key;
  GraphicsInputMedium medium;
  std::uint32_t width;
  std::uint32_t height;
  std::uint8_t depth;
  std::size_t byte_count;

  inline static std::optional<AtomicFrameControl> parse(std::string_view text) noexcept {
    std::optional<std::uint32_t> image, placement, width, height, depth;
    std::optional<GraphicsInputMedium> medium;
    bool transmit = false;
    bool cursor_static = false;
    bool quiet = false;
    KittyControlFields fields{text};
    while (const auto field = fields.next()) {
      switch (field->key) {
      case 'a':
        if (transmit || field->value != "T") {
          return std::nullopt;
        }
        transmit = true;
        break;
      case 't':
        if (medium || (field->value != "s" && field->value != "f")) {
          return std::nullopt;
        }
        medium = field->value == "s" ? GraphicsInputMedium::shared_memory : GraphicsInputMedium::file;
        break;
      case 'C':
        if (cursor_static || field->value != "1") {
          return std::nullopt;
        }
        cursor_static = true;
        break;
      case 'q':
        if (quiet || field->value != "2") {
          return std::nullopt;
        }
        quiet = true;
        break;
      case 'i':
      case 'p':
      case 's':
      case 'v':
      case 'f': {
        auto &destination = field->key == 'i' ? image : field->key == 'p' ? placement
                                                    : field->key == 's'   ? width
                                                    : field->key == 'v'   ? height
                                                                          : depth;
        const auto value = kittyUnsigned<std::uint32_t>(field->value);
        if (destination || !value || *value == 0) {
          return std::nullopt;
        }
        destination = *value;
        break;
      }
      default:
        return std::nullopt;
      }
    }

    constexpr std::uint32_t rgb_depth = 24;
    constexpr std::uint32_t rgba_depth = 32;
    if (!fields.valid() || !transmit || !cursor_static || !quiet || !medium || !image || !placement || !width || !height || !depth || (*depth != rgb_depth && *depth != rgba_depth)) {
      return std::nullopt;
    }

    const auto pixels = static_cast<std::uint64_t>(*width) * *height;
    const auto bytes_per_pixel = *depth == rgb_depth ? 3 : 4;
    if (pixels > SIZE_MAX / bytes_per_pixel) {
      return std::nullopt;
    }

    return AtomicFrameControl{{*image, *placement}, *medium, *width, *height, static_cast<std::uint8_t>(*depth), static_cast<std::size_t>(pixels * bytes_per_pixel)};
  }
};

struct AtomicFrame {
  std::size_t start;
  std::size_t end;
  std::size_t command_start;
  std::size_t command_end;
  std::string_view encoded_name;
  AtomicFrameControl control;
  bool cursor_wrapped;

  inline static std::optional<AtomicFrame> at(std::string_view bytes, std::size_t start) noexcept {
    if (start > bytes.size()) {
      return std::nullopt;
    }

    const bool wrapped = bytes.substr(start).starts_with(cursor_save);
    const auto envelope = start + (wrapped ? cursor_save.size() : 0);
    if (!bytes.substr(envelope).starts_with(prefix)) {
      return std::nullopt;
    }

    const auto control_start = envelope + prefix.size();
    const auto terminator = bytes.find(command_terminator, control_start);
    if (terminator == std::string_view::npos || !bytes.substr(terminator).starts_with(suffix)) {
      return std::nullopt;
    }

    const auto end = terminator + suffix.size();
    if (wrapped && !bytes.substr(end).starts_with(cursor_restore)) {
      return std::nullopt;
    }

    const auto command = bytes.substr(control_start, terminator - control_start);
    const auto separator = command.find(';');
    if (separator == std::string_view::npos || separator + 1 == command.size()) {
      return std::nullopt;
    }

    const auto control = AtomicFrameControl::parse(command.substr(0, separator));
    if (!control) {
      return std::nullopt;
    }

    return AtomicFrame{start, end + (wrapped ? cursor_restore.size() : 0), control_start - introducer.size(), terminator + command_terminator.size(), command.substr(separator + 1), *control, wrapped};
  }

  inline static std::optional<AtomicFrame> find(std::string_view bytes, std::size_t from) noexcept {
    for (auto start = bytes.find(prefix, from); start != std::string_view::npos; start = bytes.find(prefix, start + prefix.size())) {
      if (start >= cursor_save.size() && start - cursor_save.size() >= from && bytes.substr(start - cursor_save.size()).starts_with(cursor_save)) {
        if (auto wrapped = at(bytes, start - cursor_save.size())) {
          return wrapped;
        }
      }

      if (auto frame = at(bytes, start)) {
        return frame;
      }
    }
    return std::nullopt;
  }

  static constexpr std::string_view prefix = "\x1b[?2026h\x1b[H\x1b_G";
  static constexpr std::string_view suffix = "\x1b\\\x1b[?2026l";
  static constexpr std::string_view cursor_save = "\x1b"
                                                  "7";
  static constexpr std::string_view cursor_restore = "\x1b"
                                                     "8";
  static constexpr std::string_view introducer = "\x1b_G";
  static constexpr std::string_view command_terminator = "\x1b\\";
};

struct AtomicFrameView {
  std::span<const std::uint8_t> bytes;
  std::size_t command_start;
  std::size_t command_end;
  std::string_view encoded_name;
  AtomicFrameControl control;
};

struct AtomicFrameResource {
  std::string_view encoded_name;
  std::size_t byte_count;
  std::size_t limit;
  GraphicsInputMedium medium;
};

}
}

// Interface: graphics/kitty_file_control.cppm
export {
namespace telar::runtime {

struct KittyFileRange {
  std::uint64_t offset = 0;
  std::optional<std::uint64_t> size;
  bool temporary = false;

  inline static std::optional<KittyFileRange> parse(std::string_view control) noexcept {
    KittyFileRange range;
    bool file = false;
    KittyControlFields fields{control};
    while (const auto field = fields.next()) {
      switch (field->key) {
      case 'a':
        if (field->value != "t" && field->value != "T") {
          return std::nullopt;
        }
        break;
      case 't':
        if (field->value != "f" && field->value != "t") {
          return std::nullopt;
        }
        file = true;
        range.temporary = field->value == "t";
        break;
      case 'm':
        if (field->value != "0") {
          return std::nullopt;
        }
        break;
      case 'S':
      case 'O': {
        const auto number = kittyUnsigned<std::uint64_t>(field->value);
        if (!number) {
          return std::nullopt;
        }
        if (field->key == 'S') {
          range.size = *number;
        } else {
          range.offset = *number;
        }
        break;
      }
      default:
        break;
      }
    }
    return file && fields.valid() ? std::optional{range} : std::nullopt;
  }
};

}
}

// Interface: graphics/file_input.cppm
export {
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
  inline static void feed(std::span<const std::uint8_t> bytes, std::size_t storage_limit, Sink &sink) {
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
  inline static void frame(std::span<const std::uint8_t> bytes, std::string_view ending, std::size_t storage_limit, Sink &sink) {
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

  inline static tbc::view<std::optional<Command>, tbc::lt::a> nextCommand(tbc::view<std::string_view, tbc::lt::a> text, std::size_t &search_from) noexcept {
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
  inline static bool forward(const Transmission &request, Sink &sink) {
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

  inline static tbc::view<std::span<const std::uint8_t>, tbc::lt::a> encodeChunk(tbc::view<std::span<char>, tbc::lt::a> chunk, std::string_view control, std::span<const std::uint8_t> raw, bool more) {
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
}

// Interface: graphics/image_allocation.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class ImageAllocation {
public:
  inline explicit ImageAllocation(MediaAllocator<Memory> &memory, std::size_t byte_count) noexcept
      : memory_(memory) {
    placeholder_ = static_cast<std::uint8_t *>(memory_.allocate(placeholder_bytes, alignof(std::uint8_t)));
    if (placeholder_ == nullptr) {
      return;
    }
    if (!memory_.reserve(byte_count)) {
      memory_.deallocate(std::exchange(placeholder_, nullptr), placeholder_bytes, alignof(std::uint8_t));
      return;
    }
    reserved_bytes_ = byte_count;
  }

  inline ~ImageAllocation() {
    reset();
  }

  inline void reset() noexcept {
    if (reserved_bytes_ != 0) {
      memory_.release(std::exchange(reserved_bytes_, 0));
    }
    memory_.deallocate(std::exchange(placeholder_, nullptr), placeholder_bytes, alignof(std::uint8_t));
  }

  ImageAllocation(const ImageAllocation &) = delete;
  ImageAllocation &operator=(const ImageAllocation &) = delete;

  inline explicit operator bool() const noexcept {
    return placeholder_ != nullptr;
  }

  inline bool adopt(MappedRegion &mapping) noexcept {
    if (placeholder_ == nullptr || mapping.bytes().size() != reserved_bytes_ || !memory_.adoptMapping(placeholder_, mapping)) {
      return false;
    }

    reserved_bytes_ = 0;
    return true;
  }

  inline std::span<const std::uint8_t> placeholder() const noexcept {
    return {placeholder_, placeholder_bytes};
  }

  inline void release() noexcept {
    placeholder_ = nullptr;
  }

private:
  static constexpr std::size_t placeholder_bytes = 1;
  MediaAllocator<Memory> &memory_;
  std::uint8_t *placeholder_ = nullptr;
  std::size_t reserved_bytes_ = 0;
};

template <Allocator Memory>
ImageAllocation(MediaAllocator<Memory> &memory, std::size_t byte_count) -> ImageAllocation<Memory>;

}
}

// Interface: graphics/media_batch.cppm
export {
namespace telar::runtime {

class MediaBatch {
public:
  static constexpr std::size_t byte_capacity = 64 * 1024;
  static constexpr std::size_t event_capacity = 64;

  struct Output {
    std::size_t offset;
    std::size_t length;
  };

  using Event = std::variant<Output, TerminalSize>;

  inline bool append(std::span<const Byte> bytes) noexcept {
    if (bytes.size() > byte_capacity - byte_count_) {
      return false;
    }

    auto *previous = event_count_ == 0 ? nullptr : std::get_if<Output>(&events_[event_count_ - 1]);
    if (previous == nullptr && event_count_ == event_capacity) {
      return false;
    }

    if (!bytes.empty()) {
      std::memcpy(bytes_.data() + byte_count_, bytes.data(), bytes.size());
    }
    if (previous != nullptr) {
      previous->length += bytes.size();
    } else {
      events_[event_count_++] = Output{byte_count_, bytes.size()};
    }
    byte_count_ += bytes.size();
    return true;
  }

  inline bool resize(TerminalSize size) noexcept {
    if (event_count_ != 0 && std::holds_alternative<TerminalSize>(events_[event_count_ - 1])) {
      events_[event_count_ - 1] = size;
      return true;
    }
    if (event_count_ == event_capacity) {
      return false;
    }

    events_[event_count_++] = size;
    return true;
  }

  inline void clear() noexcept {
    byte_count_ = 0;
    event_count_ = 0;
    reset_before = false;
    kitty = false;
  }

  inline std::span<const Event> events() const noexcept {
    return std::span{events_}.first(event_count_);
  }

  inline std::span<const Byte> bytes(Output output) const noexcept {
    return std::span{bytes_}.subspan(output.offset, output.length);
  }

  inline std::size_t byteCount() const noexcept {
    return byte_count_;
  }

  inline bool hasReadCapacity(std::size_t bytes) const noexcept {
    constexpr std::size_t reserved_events = 2;
    return bytes <= byte_capacity - byte_count_ && event_count_ + reserved_events <= event_capacity;
  }

  bool reset_before = false;
  bool kitty = false;

private:
  std::array<Byte, byte_capacity> bytes_;
  std::array<Event, event_capacity> events_;
  std::size_t byte_count_ = 0;
  std::size_t event_count_ = 0;
};

}
}
