module;
#include "telar_platform/trace_macro.hpp"
#include <concepts>
#include <unistd.h>
#include <cerrno>
#include <limits.h>
#include <sys/stat.h>
#include <exception>
#include <ghostty/vt.h>
#include <source_location>
#include <chrono>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>
#include <cassert>
#include <type_traits>
#include <bit>
#include <stdlib.h>

#include <cstddef>
#include <cstdint>
#include <span>
#include <algorithm>
#include <array>

#include <cstring>

#include <limits>

#include <stdexcept>
#include <charconv>
#include <optional>
#include "telar_base/diagnostics/config.hpp"

#include <utility>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string_view>
#include <sys/mman.h>

#include <atomic>

#include <variant>

export module telar.runtime.graphics.pane_media;

export import telar.runtime.graphics.file_input;


export import telar.runtime.terminal.osc_scanner;
export import telar.runtime.graphics.prepared_images;


export import telar.runtime.diagnostics.runtime_counters;
export import telar.runtime.diagnostics.operation;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.config;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;

// Interface: graphics/atomic_frame_filter.cppm
export {
namespace telar::runtime {

template <typename Source>
concept AtomicFrameSource = requires(Source &source, const AtomicFrameResource &resource) {
  { source.available(resource) } -> std::same_as<bool>;
  { source.release(resource) } -> std::same_as<void>;
};

template <typename Sink>
concept AtomicFrameSink = requires(Sink &sink, std::span<const std::uint8_t> bytes, const AtomicFrameView &frame) {
  { sink.output(bytes) } -> std::same_as<void>;
  { sink.atomicFrame(frame) } -> std::same_as<bool>;
};

class AtomicFrameFilter {
public:
  struct Statistics {
    std::uint64_t discarded = 0;
    std::uint64_t unavailable = 0;
    std::uint64_t forwarded = 0;
    std::uint64_t direct = 0;
    std::uint64_t file = 0;
  };

  template <AtomicFrameSource Source, AtomicFrameSink Sink>
  inline static Statistics feed(std::span<const std::uint8_t> bytes, std::size_t storage_limit, Source &source, Sink &sink) {
    const std::string_view text{reinterpret_cast<const char *>(bytes.data()), bytes.size()};
    std::size_t emitted = 0;
    std::size_t search_from = 0;
    Statistics statistics;
    while (const auto first = AtomicFrame::find(text, search_from)) {
      std::array<SelectedFrame, maximum_placements> selected;
      std::size_t count = 0;
      auto end = first->end;
      bool overflow = !record(selected, count, *first);
      while (const auto frame = AtomicFrame::at(text, end)) {
        overflow |= !record(selected, count, *frame);
        end = frame->end;
      }

      if (!overflow) {
        auto entries = std::span{selected}.first(count);
        for (auto &entry : entries) {
          for (auto recent = entry.recent_count; recent != 0; --recent) {
            const auto frame = AtomicFrame::at(text, entry.recent[recent - 1]).value();
            if (source.available(resource(frame, storage_limit))) {
              entry.selected = frame.start;
              break;
            }
          }
        }

        output(bytes.subspan(emitted, first->start - emitted), sink);
        auto position = first->start;
        while (position < end) {
          const auto frame = AtomicFrame::at(text, position).value();
          const auto selected = selectedStart(entries, frame.control.key);
          if (selected == frame.start) {
            const AtomicFrameView view{bytes.subspan(frame.start, frame.end - frame.start), frame.command_start - frame.start, frame.command_end - frame.start, frame.encoded_name, frame.control};
            if (sink.atomicFrame(view)) {
              ++statistics.direct;
              statistics.file += frame.control.medium == GraphicsInputMedium::file;
              ++statistics.forwarded;
            } else if (frame.control.medium == GraphicsInputMedium::file) {
              ++statistics.unavailable;
            } else {
              sink.output(view.bytes);
              ++statistics.forwarded;
            }
          } else {
            source.release(resource(frame, storage_limit));
            if (frame.cursor_wrapped) {
              // DECSC still updates the saved cursor when its replacement frame is discarded.
              sink.output({reinterpret_cast<const std::uint8_t *>(AtomicFrame::cursor_save.data()), AtomicFrame::cursor_save.size()});
            }
            statistics.unavailable += !selected.has_value();
            statistics.discarded += selected.has_value();
          }
          position = frame.end;
        }
        emitted = end;
      }
      search_from = end;
    }

    output(bytes.subspan(emitted), sink);
    return statistics;
  }

private:
  static constexpr std::size_t maximum_placements = 256;
  static constexpr std::size_t recent_frames = 8;

  struct SelectedFrame {
    AtomicFrameKey key;
    std::array<std::size_t, recent_frames> recent;
    std::size_t recent_count;
    std::optional<std::size_t> selected;
  };

  inline static bool record(std::span<SelectedFrame> entries, std::size_t &count, const AtomicFrame &frame) noexcept {
    for (auto &entry : entries.first(count)) {
      if (entry.key != frame.control.key) {
        continue;
      }

      if (entry.recent_count == entry.recent.size()) {
        std::move(entry.recent.begin() + 1, entry.recent.end(), entry.recent.begin());
        --entry.recent_count;
      }
      entry.recent[entry.recent_count++] = frame.start;
      return true;
    }

    if (count == entries.size()) {
      return false;
    }
    auto &entry = entries[count++];
    entry.key = frame.control.key;
    entry.recent[0] = frame.start;
    entry.recent_count = 1;
    entry.selected.reset();
    return true;
  }

  inline static std::optional<std::size_t> selectedStart(std::span<const SelectedFrame> entries, AtomicFrameKey key) noexcept {
    for (const auto &entry : entries) {
      if (entry.key == key) {
        return entry.selected;
      }
    }
    return std::nullopt;
  }

  inline static AtomicFrameResource resource(const AtomicFrame &frame, std::size_t storage_limit) noexcept {
    return {frame.encoded_name, frame.control.byte_count, storage_limit, frame.control.medium};
  }

  template <AtomicFrameSink Sink>
  inline static void output(std::span<const std::uint8_t> bytes, Sink &sink) {
    if (!bytes.empty()) {
      sink.output(bytes);
    }
  }
};

}
}

// Interface: graphics/frame_source.cppm
export {
namespace telar::runtime {

class GraphicsFrameSource {
public:
  inline static bool available(const AtomicFrameResource &resource) noexcept {
    if (resource.byte_count > resource.limit) {
      return false;
    }

    if (resource.medium == GraphicsInputMedium::file) {
      const auto file = GraphicsChildFile::open(resource.encoded_name);
      return file && file->size >= resource.byte_count;
    }

    std::array<std::uint8_t, PATH_MAX + 1> name;
    return static_cast<bool>(GraphicsChildSharedMemory::open(resource.encoded_name, name));
  }

  inline static void release(const AtomicFrameResource &resource) noexcept {
    if (resource.medium == GraphicsInputMedium::shared_memory) {
      GraphicsChildSharedMemory::release(resource.encoded_name);
    }
  }
};

}
}

// Interface: graphics/frame_pixels.cppm
export {
namespace telar::runtime {

class GraphicsFramePixels {
public:
  inline static std::optional<GraphicsFramePixels> open(const AtomicFrameResource &resource) noexcept {
    if (resource.byte_count == 0 || resource.byte_count > resource.limit) {
      return std::nullopt;
    }

    GraphicsFramePixels pixels;
    if (resource.medium == GraphicsInputMedium::file) {
      pixels.file_ = GraphicsChildFile::open(resource.encoded_name);
      if (!pixels.file_ || pixels.file_->size < resource.byte_count) {
        return std::nullopt;
      }
      return pixels;
    }

    std::array<std::uint8_t, PATH_MAX + 1> name;
    auto shared = GraphicsChildSharedMemory::open(resource.encoded_name, name);
    struct stat metadata{};
    if (!shared || ::fstat(shared.get(), &metadata) != 0 || metadata.st_size < 0 || static_cast<std::uint64_t>(metadata.st_size) < resource.byte_count) {
      return std::nullopt;
    }

    pixels.shared_ = std::move(shared);
    pixels.shared_bytes_ = resource.byte_count;
    ::shm_unlink(reinterpret_cast<const char *>(name.data()));
    return pixels;
  }

  inline bool copyTo(std::span<std::uint8_t> destination) const noexcept {
    if (file_) {
      return file_->read(destination, 0);
    }
    if (destination.size() != shared_bytes_) {
      return false;
    }
    return GraphicsChildSharedMemory::read(shared_.get(), destination, 0);
  }

private:
  std::optional<GraphicsChildFile> file_;
  FileDescriptor shared_;
  std::size_t shared_bytes_ = 0;
};

}
}

// Interface: graphics/upload_limits.cppm
export {
namespace telar::runtime {

class GraphicsUploadLimits {
public:
  struct Observation {
    std::optional<std::uint32_t> loading_image;
    std::size_t completed_commands = 0;
  };

  struct Reached {
    bool chunks = false;
    bool bytes = false;
  };

  inline explicit GraphicsUploadLimits(std::size_t byte_limit, std::size_t chunk_limit = GraphicsLimits::maximum_chunks_per_image) noexcept
      : byte_limit_(byte_limit),
        chunk_limit_(chunk_limit) {}

  inline Observation observe(GhosttyTerminal terminal, std::span<const std::uint8_t> bytes) {
    Observation observation{.loading_image = loadingImage(storage(terminal))};
    std::size_t position = 0;
    while (const auto transition = framing_.advance(bytes, position)) {
      observation.completed_commands += *transition == KittyFraming::Transition::ended;
    }
    return observation;
  }

  inline Observation observeEncodedChunk(GhosttyTerminal terminal) {
    // Generated control fields and base64 contain no framing transitions. The opening ESC may still terminate an earlier APC.
    constexpr std::array<std::uint8_t, 5> envelope{0x1b, '_', 'G', 0x1b, '\\'};
    return observe(terminal, envelope);
  }

  inline std::optional<std::uint32_t> enforce(GhosttyTerminal terminal, const Observation &observation) {
    const auto graphics = storage(terminal);
    const auto loading = loadingImage(graphics);
    if (loading || observation.loading_image) {
      loading_chunks_ += std::min(observation.completed_commands, std::numeric_limits<std::size_t>::max() - loading_chunks_);
    } else {
      loading_chunks_ = 0;
    }

    const bool exceeded_chunks = loading_chunks_ > chunk_limit_;
    if (!loading) {
      loading_chunks_ = 0;
      if (exceeded_chunks && observation.loading_image) {
        checkGhostty(ghostty_kitty_graphics_image_remove(terminal, *observation.loading_image));
        reached_.chunks = true;
        return observation.loading_image;
      }
      return std::nullopt;
    }

    std::size_t bytes = 0;
    checkGhostty(ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_LOADING_BYTES, &bytes));
    if (!exceeded_chunks && bytes <= byte_limit_) {
      return std::nullopt;
    }

    checkGhostty(ghostty_kitty_graphics_loading_abort(terminal));
    loading_chunks_ = 0;
    reached_.chunks |= exceeded_chunks;
    reached_.bytes |= !exceeded_chunks;
    return loading;
  }

  inline Reached takeReached() noexcept {
    return std::exchange(reached_, {});
  }

private:
  inline static GhosttyKittyGraphics storage(GhosttyTerminal terminal) {
    GhosttyKittyGraphics graphics = nullptr;
    checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics));
    return graphics;
  }

  inline static std::optional<std::uint32_t> loadingImage(GhosttyKittyGraphics graphics) {
    std::uint32_t identity = 0;
    const auto result = ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_LOADING_IMAGE_ID, &identity);
    if (result == GHOSTTY_NO_VALUE) {
      return std::nullopt;
    }

    checkGhostty(result);
    return identity;
  }

  KittyFraming framing_;
  std::size_t byte_limit_;
  std::size_t chunk_limit_;
  std::size_t loading_chunks_ = 0;
  Reached reached_;
};

}
}

// Interface: graphics/media_terminal.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class MediaTerminal {
public:
  inline explicit MediaTerminal(Memory &memory, TerminalSize size, GraphicsLimits limits, std::shared_ptr<PtyResponseQueue> responses = {})
      : graphics(memory),
        control_parser_(memory),
        allocator_(memory),
        responses_(responses ? std::move(responses) : std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, Memory>{memory})),
        response_outbox_(memory, *responses_),
        storage_limit_(limits.screenBytes()),
        uploads_(limits.screenBytes()) {
    checkGhostty(ghostty_terminal_new(allocator_.get(), terminal_.output(), size.cols, size.rows));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_USERDATA, this));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_WRITE_PTY, reinterpret_cast<const void *>(&receiveResponse)));
    const auto storage = limits.screenBytes();
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &storage));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES_KITTY, &GraphicsLimits::payload_bytes));
    const bool disabled = false;
    const bool enabled = true;
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_GLYPH_PROTOCOL, &disabled));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, &disabled));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, nullptr));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, &enabled));
    resize(size);
  }

  inline void feed(std::span<const Byte> bytes) {
    try {
      requireOpen();
      const auto consumed = control_parser_.feed(bytes, *this);
      if (consumed != bytes.size()) {
        throw std::logic_error{"Media control filter failed to consume input"};
      }
      response_outbox_.drain();
    } catch (...) {
      response_failed_ |= !responses_->closed();
      responses_->stopProducing();
      control_parser_.discard();
      response_outbox_.discard();
      throw;
    }
  }

  inline void ordinary(std::span<const Byte> bytes) {
    GraphicsFileInput::feed(bytes, storage_limit_, *this);
  }

  inline bool enquire() const noexcept {
    return true;
  }

  inline bool streamable(control::Sequence sequence) const noexcept {
    return sequence.kind != control::Kind::apc && control::streamable(sequence);
  }

  inline bool complete(control::Sequence sequence) {
    if (sequence.kind == control::Kind::csi) {
      const auto parameters = control::Parameters::parse(sequence.body());
      if (parameters && !parameters->colon && parameters->modifiers() == "?" && (parameters->final == 'h' || parameters->final == 'l' || parameters->final == 's' || parameters->final == 'r')) {
        for (const auto mode : std::span{parameters->values}.first(parameters->count)) {
          if (std::find(control::desktop_modes.begin(), control::desktop_modes.end(), mode) == control::desktop_modes.end()) {
            control::forwardPrivateMode(mode, parameters->final, [this](auto command) { ordinary(command); });
          }
        }
        return true;
      }
    }
    if (!control::query(sequence)) {
      if (sequence.kind == control::Kind::apc) {
        GraphicsFileInput::frame(sequence.bytes, sequence.terminator(), storage_limit_, *this);
        return true;
      }
      ordinary(sequence.bytes);
      if (sequence.ending != control::Ending::final_byte) {
        const auto terminator = sequence.terminator();
        ordinary({reinterpret_cast<const Byte *>(terminator.data()), terminator.size()});
      }
    }
    return true;
  }

  inline void reply(std::span<const Byte> bytes) {
    response_outbox_.append(bytes);
    response_outbox_.drain();
  }

  inline void ingest(std::span<const Byte> bytes) {
    requireOpen();
    TELAR_TRACE("media.terminal.feed");
    write(bytes, uploads_.observe(terminal_.get(), bytes));
  }

  inline void ingestEncodedChunk(std::span<const Byte> bytes) {
    requireOpen();
    TELAR_TRACE("media.terminal.feed");
    write(bytes, uploads_.observeEncodedChunk(terminal_.get()));
  }

  inline void resize(TerminalSize size) {
    checkGhostty(ghostty_terminal_resize(terminal_.get(), size.cols, size.rows, size.cell_width_px, size.cell_height_px));
  }

  inline void refresh() {
    graphics.update(terminal_.get());
  }

  inline bool insertImage(const AtomicFrameControl &control, std::span<const Byte> data) noexcept {
    const GhosttyKittyGraphicsImageInsert image{
        .size = sizeof(GhosttyKittyGraphicsImageInsert),
        .image_id = control.key.image_id,
        .width = control.width,
        .height = control.height,
        .format = control.depth == 24 ? GHOSTTY_KITTY_IMAGE_FORMAT_RGB : GHOSTTY_KITTY_IMAGE_FORMAT_RGBA,
        .data = data.data(),
        .data_len = data.size(),
    };
    return ghostty_kitty_graphics_image_insert(terminal_.get(), &image) == GHOSTTY_SUCCESS;
  }

  inline ImageKey imageKey(std::uint32_t identity) {
    GhosttyKittyGraphics storage = nullptr;
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &storage));
    const auto image = ghostty_kitty_graphics_image(storage, identity);
    ImageKey key{identity, 0};
    checkGhostty(ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &key.generation));
    return key;
  }

#if TELAR_DIAGNOSTICS
  inline diagnostics::GraphicsStorageSnapshot storageMetrics() {
    return graphics.storageMetrics(terminal_.get());
  }
#endif

  inline std::size_t storageLimit() const noexcept {
    return storage_limit_;
  }

  inline std::span<const Byte> responses() const noexcept {
    return responses_->readable();
  }

  inline void consumeResponses(std::size_t count) noexcept {
    responses_->consume(count);
    response_outbox_.drain();
  }

  inline bool drainResponses() noexcept { return response_outbox_.drain(); }
  inline bool pendingResponses() const noexcept { return response_outbox_.pending(); }
  inline std::size_t nextResponseSize() const noexcept { return response_outbox_.nextSize(); }
  inline bool responseFailed() const noexcept { return response_failed_; }

  inline void requireOpen() const {
    if (responses_->closed()) {
      throw ResponseFailure{};
    }
  }

  inline GraphicsUploadLimits::Reached takeUploadLimits() noexcept {
    return uploads_.takeReached();
  }

  GraphicsStorage<Memory> graphics;

private:
  struct ResponseFailure {};

  inline void write(std::span<const Byte> bytes, const GraphicsUploadLimits::Observation &observation) {
    ghostty_terminal_vt_write(terminal_.get(), bytes.data(), bytes.size());
    if (response_failed_) {
      throw ResponseFailure{};
    }
    if (const auto image = uploads_.enforce(terminal_.get(), observation)) {
      replyUploadLimit(*image);
    }

    bool processing_error = false;
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR, &processing_error));
    if (processing_error) {
      throw TerminalError{GHOSTTY_OUT_OF_MEMORY};
    }
  }

  inline void replyUploadLimit(std::uint32_t image) {
    constexpr std::string_view prefix = "\x1b_Gi=";
    constexpr std::string_view suffix = ";ENOMEM: graphics upload limit exceeded\x1b\\";
    std::array<char, prefix.size() + 10 + suffix.size()> response;
    auto *identity = std::copy(prefix.begin(), prefix.end(), response.data());
    const auto formatted = std::to_chars(identity, identity + 10, image);
    const auto *end = std::copy(suffix.begin(), suffix.end(), formatted.ptr);
    reply({reinterpret_cast<const Byte *>(response.data()), static_cast<std::size_t>(end - response.data())});
  }

  inline static void receiveResponse(GhosttyTerminal, void *context, const Byte *bytes, std::size_t count) noexcept {
    constexpr std::string_view kitty_response = "\x1b_G";
    if (count < kitty_response.size() || std::memcmp(bytes, kitty_response.data(), kitty_response.size()) != 0) {
      return;
    }

    auto &self = *static_cast<MediaTerminal *>(context);
    try {
      self.response_outbox_.append({bytes, count});
    } catch (...) {
      // No exception may cross the foreign callback. The enclosing write
      // fails after it returns, cancelling this pane generation explicitly.
      self.response_failed_ = true;
      self.responses_->stopProducing();
    }
  }

  control::Parser<Memory> control_parser_;
  GhosttyAllocatorBridge<Memory> allocator_;
  TerminalHandle terminal_;
  std::shared_ptr<PtyResponseQueue> responses_;
  ResponseOutbox<Memory> response_outbox_;
  std::size_t storage_limit_;
  GraphicsUploadLimits uploads_;
  bool response_failed_ = false;
};

}
}

// Interface: graphics/atomic_frame_loader.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class AtomicFrameLoader {
public:
  inline explicit AtomicFrameLoader(MediaAllocator<Memory> &memory, MediaTerminal<MediaAllocator<Memory>> &terminal, PreparedImages<Memory> &prepared) noexcept
      : memory_(memory),
        terminal_(terminal),
        prepared_(prepared) {}

  inline bool load(const AtomicFrameView &frame, bool shared_transport) {
    TELAR_TRACE("media.loadAtomicFrame");
    const auto child = GraphicsFramePixels::open({frame.encoded_name, frame.control.byte_count, terminal_.storageLimit(), frame.control.medium});
    if (!child) {
      return false;
    }

    ImageAllocation allocation{memory_, frame.control.byte_count};
    if (!allocation) {
      return false;
    }

    auto storage = SharedImageStorage::create(frame.control.byte_count);
    if (!storage || !child->copyTo(storage->mapping().bytes()) || !storage->mapping().protect(PROT_READ) || !allocation.adopt(storage->mapping())) {
      return false;
    }

    terminal_.feed(frame.bytes.first(frame.command_start));
    // Ghostty owns a placeholder; the allocator owns and charges the full mapping.
    // Keeping native storage accounting separate matches its eviction behavior.
    if (!terminal_.insertImage(frame.control, allocation.placeholder())) {
      allocation.reset();
      storage.reset();
      terminal_.feed(frame.bytes.subspan(frame.command_end));
      return true;
    }
    allocation.release();

    place(frame.control.key);
    terminal_.feed(frame.bytes.subspan(frame.command_end));
    if (shared_transport) {
      auto frozen = FrozenImage<Memory>::adoptSharedName(storage->takeName(), frame.control.byte_count);
      prepared_.put(terminal_.imageKey(frame.control.key.image_id), std::move(frozen));
    }
    return true;
  }

private:
  inline void place(AtomicFrameKey key) {
    std::array<char, 64> command;
    auto *end = std::copy_n("\x1b_Ga=p,i=", 9, command.data());
    end = std::to_chars(end, command.data() + command.size(), key.image_id).ptr;
    end = std::copy_n(",p=", 3, end);
    end = std::to_chars(end, command.data() + command.size(), key.placement_id).ptr;
    end = std::copy_n(",C=1,q=2\x1b\\", 10, end);
    terminal_.feed({reinterpret_cast<const Byte *>(command.data()), static_cast<std::size_t>(end - command.data())});
  }

  MediaAllocator<Memory> &memory_;
  MediaTerminal<MediaAllocator<Memory>> &terminal_;
  PreparedImages<Memory> &prepared_;
};

}
}

// Interface: graphics/media_input.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class MediaInput {
public:
  inline explicit MediaInput(MediaAllocator<Memory> &memory, MediaTerminal<MediaAllocator<Memory>> &terminal, PreparedImages<Memory> &prepared, const std::atomic<unsigned> &shared_clients) noexcept
      : terminal_(terminal),
        atomic_frames_(memory, terminal, prepared),
        shared_clients_(shared_clients) {}

  inline AtomicFrameFilter::Statistics feed(std::span<const Byte> bytes) {
    terminal_.requireOpen();
    CheckedSource source{{}, terminal_};
    return AtomicFrameFilter::feed(bytes, terminal_.storageLimit(), source, *this);
  }

  inline void output(std::span<const Byte> bytes) {
    terminal_.feed(bytes);
  }

  inline bool atomicFrame(const AtomicFrameView &frame) {
    terminal_.requireOpen();
    return atomic_frames_.load(frame, shared_clients_.load(std::memory_order_acquire) != 0);
  }

private:
  struct CheckedSource {
    GraphicsFrameSource source;
    MediaTerminal<MediaAllocator<Memory>> &terminal;

    inline bool available(const AtomicFrameResource &resource) {
      terminal.requireOpen();
      return source.available(resource);
    }

    inline void release(const AtomicFrameResource &resource) {
      terminal.requireOpen();
      source.release(resource);
    }
  };

  MediaTerminal<MediaAllocator<Memory>> &terminal_;
  AtomicFrameLoader<Memory> atomic_frames_;
  const std::atomic<unsigned> &shared_clients_;
};

template <Allocator Memory>
MediaInput(MediaAllocator<Memory> &memory, MediaTerminal<MediaAllocator<Memory>> &terminal, PreparedImages<Memory> &prepared, const std::atomic<unsigned> &shared_clients) -> MediaInput<Memory>;

}
}

// Interface: graphics/pane_media.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class PaneMedia {
public:
  using AllocatedMemory = MediaAllocator<Memory>;

  inline explicit PaneMedia(Memory &memory, MediaBudget &budget, GraphicsLimits limits, TerminalSize size, std::shared_ptr<PtyResponseQueue> responses = {})
      : memory_(memory, budget, limits.pane_bytes),
        prepared_(memory, memory_),
        requests_(memory, memory_),
        responses_(responses ? std::move(responses) : std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, Memory>{memory})),
        limits_(limits),
        current_size_(size) {
    terminal_.emplace(memory_, size, limits, responses_);
  }

  inline void requireOrderedInput() noexcept { ordered_input_ = true; }

  inline void output(std::span<const Byte> bytes) noexcept {
    if (cancelled_) {
      return;
    }
    const bool kitty = framing_.touches(bytes);
    auto &batch = batches_[active_];
    if (!batch.append(bytes)) {
      if (ordered_input_) {
        ingress_failed_ = true;
        responses_->stopProducing();
        return;
      }
      dropActive(bytes.size());
      batch.append(bytes);
    }
    batch.kitty |= kitty;
    TELAR_DIAGNOSTIC(observeQueue());
  }

  inline void resize(TerminalSize size) noexcept {
    if (cancelled_) {
      return;
    }
    current_size_ = size;
    auto &batch = batches_[active_];
    if (!batch.resize(size)) {
      if (ordered_input_) {
        ingress_failed_ = true;
        responses_->stopProducing();
        return;
      }
      dropActive(0);
      batch.resize(size);
    }
    TELAR_DIAGNOSTIC(observeQueue());
  }

  inline bool holdsRead(std::size_t bytes) const noexcept {
    return pending_responses_ || (!batches_[active_].hasReadCapacity(bytes) && (ordered_input_ || (busy_ && (batches_[active_].kitty || batches_[sealed_].kitty || framing_.inside()))));
  }

  inline bool seal() noexcept {
    if (busy_) {
      return false;
    }
    if (cancelled_ || responses_->closed()) {
      cancel();
      return false;
    }
    if (pending_responses_) {
      if (!responses_->hasCapacityFor(next_response_bytes_)) {
        return false;
      }
      drain_only_ = true;
      busy_ = true;
      return true;
    }
    if (batches_[active_].events().empty()) {
      return false;
    }

    drain_only_ = false;
    sealed_ = active_;
    active_ ^= 1;
    sealed_size_ = current_size_;
    busy_ = true;
    return true;
  }

  inline void complete() noexcept {
    if (!drain_only_) {
      batches_[sealed_].clear();
    }
    pending_responses_ = progress_.pending_responses;
    next_response_bytes_ = progress_.next_response_bytes;
    failed_ = progress_.failed;
    busy_ = false;
    if (cancelled_ || progress_.cancelled) {
      cancel();
    }
    TELAR_DIAGNOSTIC(observeQueue());
  }

  inline bool process() noexcept {
    progress_ = {};
    TELAR_DIAGNOSTIC(batch_metrics_ = {});
    if (responses_->closed()) {
      progress_.cancelled = true;
      return false;
    }
    if (drain_only_) {
      if (terminal_) {
        terminal_->drainResponses();
        responseProgress();
      }
      return false;
    }
    TELAR_TRACE("media.process");
    TELAR_DIAGNOSTIC(AllocationScope allocation_scope{AllocationPath::media});
    TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{batch_metrics_.ingest});
    const auto &batch = batches_[sealed_];
    TELAR_DIAGNOSTIC(batch_metrics_.bytes = batch.byteCount());
    bool reset = batch.reset_before || !terminal_;
    try {
      if (reset) {
        prepared_.clear();
        requests_.clear();
        terminal_.reset();
        terminal_.emplace(memory_, sealed_size_, limits_, responses_);
      }

      MediaInput input{memory_, *terminal_, prepared_, shared_clients_};
      for (const auto &event : batch.events()) {
        if (const auto *output = std::get_if<MediaBatch::Output>(&event)) {
          [[maybe_unused]] const auto statistics = input.feed(batch.bytes(*output));
          TELAR_DIAGNOSTIC(diagnostics::accumulate(batch_metrics_.discarded_frames, statistics.discarded));
          TELAR_DIAGNOSTIC(diagnostics::accumulate(batch_metrics_.unavailable_frames, statistics.unavailable));
          TELAR_DIAGNOSTIC(diagnostics::accumulate(batch_metrics_.forwarded_frames, statistics.forwarded));
          TELAR_DIAGNOSTIC(diagnostics::accumulate(batch_metrics_.direct_frames, statistics.direct));
          TELAR_DIAGNOSTIC(diagnostics::accumulate(batch_metrics_.file_frames, statistics.file));
        } else {
          terminal_->resize(std::get<TerminalSize>(event));
        }
      }
      terminal_->refresh();
      if (shared_clients_.load(std::memory_order_acquire) != 0) {
        prepared_.prepare(terminal_->graphics.images());
      }
      requests_.process(terminal_->graphics.images());
    } catch (...) {
      progress_.failed = !responses_->closed() || (terminal_ && terminal_->responseFailed());
      progress_.cancelled = !progress_.failed;
      responses_->stopProducing();
      prepared_.clear();
      requests_.clear();
      terminal_.reset();
      reset = true;
      TELAR_DIAGNOSTIC(batch_metrics_.failures = progress_.failed);
    }
    responseProgress();
    TELAR_DIAGNOSTIC(batch_metrics_.prepared_frames = prepared_.takePreparedCount());
    TELAR_DIAGNOSTIC(batch_metrics_.resets = reset);
    return reset;
  }

  // Only the runtime calls cancel/complete. A busy worker observes the closed
  // queue, then ownership returns through ObservationWorker before cleanup.
  inline void cancel() noexcept {
    cancelled_ = true;
    responses_->close();
    if (!busy_) {
      batches_[0].clear();
      batches_[1].clear();
      terminal_.reset();
      prepared_.clear();
      requests_.clear();
      pending_responses_ = false;
      next_response_bytes_ = 0;
    }
  }

  inline bool failed() const noexcept { return failed_ || ingress_failed_; }

#if TELAR_DIAGNOSTICS
  inline diagnostics::GraphicsStorageSnapshot storageMetrics() {
    if (busy_) {
      return {.busy_panes = 1};
    }

    auto sample = terminal_ ? terminal_->storageMetrics() : diagnostics::GraphicsStorageSnapshot{};
    sample.prepared_bytes = prepared_.storedBytes();
    sample.staged_bytes = requests_.storedBytes();
    return sample;
  }

  inline const diagnostics::MediaQueue &queueMetrics() const noexcept {
    return queue_metrics_;
  }

  inline void noteHeldRead() noexcept {
    diagnostics::accumulate(queue_metrics_.held_reads);
  }

  inline std::size_t usedBytes() const noexcept {
    return memory_.used();
  }

  inline const diagnostics::MediaCounters &batchMetrics() const noexcept {
    return batch_metrics_;
  }
#endif

  inline MediaUsage &queryUsage() noexcept {
    return memory_.usage();
  }

  inline bool busy() const noexcept {
    return busy_;
  }

  inline void noteSharedTransport(bool added) noexcept {
    if (added) {
      shared_clients_.fetch_add(1, std::memory_order_release);
    } else {
      shared_clients_.fetch_sub(1, std::memory_order_release);
    }
  }

  inline std::optional<FrozenImage<Memory>> takeTransfer(ImageKey key, bool shared) {
    if (shared) {
      if (auto prepared = prepared_.take(key)) {
        return prepared;
      }
    }
    auto frozen = requests_.take(key, shared);
    if (!frozen && requests_.request(key, shared)) {
      output({});
    }
    return frozen;
  }

  template <typename Consumer>
  inline void discardUnwantedTransfers(const Consumer &wanted) noexcept {
    prepared_.discardUnwanted(wanted);
    requests_.discardUnwanted(wanted);
  }

  inline bool idle() const noexcept {
    return !busy_ && !pending_responses_ && batches_[active_].events().empty();
  }

  inline MediaTerminal<AllocatedMemory> *terminal() noexcept {
    return busy_ || !terminal_ ? nullptr : &*terminal_;
  }

  inline std::uint64_t takeDroppedBytes() noexcept {
    return std::exchange(dropped_bytes_, 0);
  }

  std::shared_ptr<PaneMedia> retired_next;

private:
  inline void responseProgress() noexcept {
    if (terminal_) {
      terminal_->drainResponses();
      progress_.pending_responses = terminal_->pendingResponses();
      progress_.next_response_bytes = terminal_->nextResponseSize();
    }
    progress_.cancelled |= responses_->closed() && !progress_.failed;
  }

#if TELAR_DIAGNOSTICS
  inline void observeQueue() noexcept {
    queue_metrics_.observe(batches_[0].events().size() + batches_[1].events().size(), batches_[0].byteCount() + batches_[1].byteCount());
  }
#endif

  inline void dropActive(std::size_t incoming) noexcept {
    auto &batch = batches_[active_];
    TELAR_DIAGNOSTIC(diagnostics::accumulate(queue_metrics_.dropped_events, batch.events().size() + 1));
    TELAR_DIAGNOSTIC(diagnostics::accumulate(queue_metrics_.dropped_bytes, batch.byteCount() + incoming));
    dropped_bytes_ += batch.byteCount() + incoming;
    batch.clear();
    batch.reset_before = true;
  }

  AllocatedMemory memory_;
  PreparedImages<Memory> prepared_;
  TransferRequests<Memory> requests_;
  std::shared_ptr<PtyResponseQueue> responses_;
  GraphicsLimits limits_;
  std::optional<MediaTerminal<AllocatedMemory>> terminal_;
  std::array<MediaBatch, 2> batches_;
  KittyFraming framing_;
  TerminalSize current_size_;
  TerminalSize sealed_size_{};
  std::size_t active_ = 0;
  std::size_t sealed_ = 0;
  std::uint64_t dropped_bytes_ = 0;
#if TELAR_DIAGNOSTICS
  diagnostics::MediaCounters batch_metrics_;
  diagnostics::MediaQueue queue_metrics_;
#endif
  bool busy_ = false;
  bool ordered_input_ = false;
  bool ingress_failed_ = false;
  bool drain_only_ = false;
  bool pending_responses_ = false;
  bool failed_ = false;
  bool cancelled_ = false;
  std::size_t next_response_bytes_ = 0;
  // The worker owns Progress while busy; complete imports it only after the
  // ObservationWorker acquire boundary. Runtime scheduling reads copied facts.
  struct Progress {
    std::size_t next_response_bytes = 0;
    bool pending_responses = false;
    bool failed = false;
    bool cancelled = false;
  } progress_;
  std::atomic<unsigned> shared_clients_{0};
};

}
}
