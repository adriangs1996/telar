export module telar.runtime.graphics.file_input;

import std;
import telar.tbc;

import telar.base.memory.allocators;
import telar.base.text;
import telar.vocabulary;
import telar.platform.primitives;
import telar.runtime.terminal.kitty;
import telar.base.ds;

// Interface: graphics/atomic_frame.cppm
export {
  namespace telar::runtime {

    enum class GraphicsInputMedium {
      shared_memory,
      file,
    };

    struct AtomicFrameKey {
      std::uint32_t image_id;
      std::uint32_t placement_id;

      bool operator==(const AtomicFrameKey&) const noexcept = default;
    };

    struct AtomicFrameControl {
      AtomicFrameKey key;
      GraphicsInputMedium medium;
      std::uint32_t width;
      std::uint32_t height;
      std::uint8_t depth;
      std::size_t byte_count;

      static ds::Option<AtomicFrameControl> parse(std::string_view text) noexcept;
    };

    struct AtomicFrame {
      std::size_t start;
      std::size_t end;
      std::size_t command_start;
      std::size_t command_end;
      std::string_view encoded_name;
      AtomicFrameControl control;
      bool cursor_wrapped;

      static ds::Option<AtomicFrame> at(std::string_view bytes, std::size_t start) noexcept;

      static ds::Option<AtomicFrame> find(std::string_view bytes, std::size_t from) noexcept;

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
      ds::Option<std::uint64_t> size;
      bool temporary = false;

      static ds::Option<KittyFileRange> parse(std::string_view control) noexcept;
    };

  }
}

// Interface: graphics/file_input.cppm
export {
  namespace telar::runtime {

    // What GraphicsFileInput writes to: the bytes it passes through and the chunks it reads from
    // files. One indirect call per run of bytes or chunk.
    class MediaInputSink {
    public:
      virtual void ingest(std::span<const std::uint8_t> bytes) = 0;
      virtual void ingestEncodedChunk(std::span<const std::uint8_t> bytes) = 0;

    protected:
      MediaInputSink() = default;
      MediaInputSink(const MediaInputSink&) = default;
      MediaInputSink& operator=(const MediaInputSink&) = default;
      ~MediaInputSink() = default;
    };

    class GraphicsFileInput {
    public:
      static void feed(std::span<const std::uint8_t> bytes, std::size_t storage_limit, MediaInputSink& sink);

      // The native control parser owns this complete, non-query APC. Its
      // terminator is separate, so inspect the frame without copying its payload.
      static void frame(std::span<const std::uint8_t> bytes, std::string_view ending, std::size_t storage_limit, MediaInputSink& sink);

    private:
      struct Command {
        std::size_t start;
        std::string_view control;
        std::string_view path;
      };

      static tbc::view<ds::Option<Command>, tbc::lt::a> nextCommand(tbc::view<std::string_view, tbc::lt::a> text, std::size_t& search_from) noexcept;

      struct Transmission {
        std::string_view control;
        std::string_view path;
        KittyFileRange range;
        std::size_t limit;
      };

      static bool forward(const Transmission& request, MediaInputSink& sink);

      static tbc::view<std::span<const std::uint8_t>, tbc::lt::a> encodeChunk(tbc::view<std::span<char>, tbc::lt::a> chunk, std::string_view control, std::span<const std::uint8_t> raw, bool more);

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

    class ImageAllocation {
    public:
      explicit ImageAllocation(MediaAllocator<ConcurrentMemory>& memory, std::size_t byte_count) noexcept;

      ~ImageAllocation();

      void reset() noexcept;

      ImageAllocation(const ImageAllocation&) = delete;
      ImageAllocation& operator=(const ImageAllocation&) = delete;

      explicit operator bool() const noexcept;

      bool adopt(MappedRegion& mapping) noexcept;

      std::span<const std::uint8_t> placeholder() const noexcept;

      void release() noexcept;

    private:
      static constexpr std::size_t placeholder_bytes = 1;
      MediaAllocator<ConcurrentMemory>& memory_;
      std::uint8_t* placeholder_ = nullptr;
      std::size_t reserved_bytes_ = 0;
    };

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

      bool append(std::span<const Byte> bytes) noexcept;

      bool resize(TerminalSize size) noexcept;

      void clear() noexcept;

      std::span<const Event> events() const noexcept;

      std::span<const Byte> bytes(Output output) const noexcept;

      std::size_t byteCount() const noexcept;

      bool hasReadCapacity(std::size_t bytes) const noexcept;

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
