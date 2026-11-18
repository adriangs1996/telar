module;
#include "tbc/annotations.hpp"

export module telar.runtime.terminal.kitty;

import std;
import telar.ghostty.vt;
import telar.sys.posix;
import telar.tbc;
import telar.base.memory.allocators;
import telar.base.text;
import telar.config.core;
import telar.platform.primitives;
import telar.vocabulary;
import telar.base.ds;

// What the terminal reads of kitty graphics: command framing, the cursor movement a placement
// causes, child files and the media budget that graphics queries charge.
export namespace telar::runtime {

  struct KittyControlField {
    char key;
    std::string_view value;
  };

  class KittyControlFields {
  public:
    constexpr explicit KittyControlFields(std::string_view control) noexcept
        : remaining_(control) {}

    ds::Option<KittyControlField> next() noexcept;

    constexpr bool valid() const noexcept {
      return valid_;
    }

  private:
    std::string_view remaining_;
    bool valid_ = true;
  };

  // Generic over the caller's integer width, so it stays here.
  template <std::unsigned_integral Number>
  TBC_GENERIC ds::Option<Number> kittyUnsigned(std::string_view text) noexcept {
    return unsignedDecimal<Number>(text);
  }

  struct DisplayCells {
    std::uint32_t columns = 0;
    std::uint32_t rows = 0;
    bool operator==(const DisplayCells&) const = default;
  };

  struct ImageDisplayRequest {
    std::uint32_t width;
    std::uint32_t height;
    DisplayCells requested;
    std::uint32_t offset_x;
    std::uint32_t offset_y;
    std::uint32_t cell_width;
    std::uint32_t cell_height;
  };

  constexpr std::uint32_t saturatedDimension(std::uint64_t value) noexcept {
    return static_cast<std::uint32_t>(std::min<std::uint64_t>(value, std::numeric_limits<std::uint32_t>::max()));
  }

  constexpr std::uint32_t scaledDimension(std::uint32_t value, std::uint32_t numerator, std::uint32_t denominator) noexcept {
    return denominator == 0 ? 0 : saturatedDimension((static_cast<std::uint64_t>(value) * numerator + denominator / 2) / denominator);
  }

  DisplayCells displayCells(const ImageDisplayRequest& request) noexcept;

  class KittyFraming {
  public:
    enum class Transition {
      started,
      ended,
    };

    constexpr bool ground() const noexcept {
      return state_ == State::ground;
    }

    bool canSkip(std::span<const std::uint8_t> bytes) const noexcept;

    // One complete ASCII CSI leaves graphics framing unchanged at exact ground.
    bool canSkipCsi(std::span<const std::uint8_t> bytes) const noexcept;

    constexpr bool inside() const noexcept {
      return state_ == State::kitty;
    }

    bool touches(std::span<const std::uint8_t> bytes) noexcept;

    ds::Option<Transition> advance(std::span<const std::uint8_t> bytes, std::size_t& position) noexcept;

    static constexpr bool content(std::uint8_t byte) noexcept {
      return byte < first_c1 && byte != cancel_byte && byte != substitute_byte && byte != escape_byte;
    }

  private:
    enum class State {
      ground,
      escape,
      identify,
      kitty,
      other,
    };

    static constexpr bool opens(std::uint8_t byte) noexcept {
      return byte == 'X' || byte == '^' || byte == '_' || byte == 0x98 || byte == 0x9e || byte == 0x9f;
    }

    static constexpr bool ends(std::uint8_t byte) noexcept {
      return byte == cancel_byte || byte == substitute_byte || byte == escape_byte || (byte >= first_c1 && byte <= 0x97) || (byte >= 0x99 && byte <= 0x9d);
    }

    static constexpr std::uint8_t escape_byte = 0x1b;
    static constexpr std::uint8_t cancel_byte = 0x18;
    static constexpr std::uint8_t substitute_byte = 0x1a;
    static constexpr std::uint8_t first_c1 = 0x80;
    State state_ = State::ground;
  };

  struct KittyCommandView {
    std::size_t end;
    std::string_view control;
    std::string_view payload_prefix;
    bool truncated;
  };

  class KittyCommandScanner {
  public:
    constexpr bool ground() const noexcept {
      return framing_.ground();
    }

    bool canSkip(std::span<const std::uint8_t> bytes) const noexcept;

    bool canSkipCsi(std::span<const std::uint8_t> bytes) const noexcept;

    ds::Option<KittyCommandView> next(std::span<const std::uint8_t> bytes) noexcept;

  private:
    void capture(std::span<const std::uint8_t> bytes) noexcept;

    KittyFraming framing_;
    ds::Array<char, 256> control_;
    ds::Array<char, 64> payload_;
    std::size_t control_length_ = 0;
    std::size_t payload_length_ = 0;
    bool in_payload_ = false;
    bool truncated_ = false;
  };

  class KittyCursor {
  public:
    ds::Option<DisplayCells> observe(const KittyCommandView& command, std::uint32_t cell_width, std::uint32_t cell_height) noexcept;

  private:
    struct ImageSize {
      std::uint32_t image_id = 0;
      std::uint32_t image_number = 0;
      std::uint32_t width = 0;
      std::uint32_t height = 0;
    };

    struct Header : ImageSize {
      char action = 't';
      char target = 'a';
      std::uint32_t source_x = 0;
      std::uint32_t source_y = 0;
      std::uint32_t source_width = 0;
      std::uint32_t source_height = 0;
      DisplayCells requested;
      std::uint32_t offset_x = 0;
      std::uint32_t offset_y = 0;
      bool stays = false;
      bool more = false;

      constexpr bool transmits() const noexcept {
        return action == 't' || action == 'T';
      }
    };

    ds::Option<DisplayCells> execute(const Header& header, std::uint32_t cell_width, std::uint32_t cell_height) noexcept;

    ImageSize* find(const Header& header) noexcept;

    static ds::Option<Header> parse(const KittyCommandView& command) noexcept;

    static ds::Option<ds::Array<std::uint32_t, 2>> pngSize(std::string_view encoded) noexcept;

    static constexpr std::size_t image_capacity = 64;
    ds::Array<ImageSize, image_capacity> sizes_{};
    ds::Option<Header> pending_;
    std::size_t next_size_ = 0;
  };

  // Moves a terminal's cursor past the cells each kitty placement covers, writing the bytes around
  // the commands to the terminal. One call per write runs the scan and the placements together.
  class GraphicsCursor {
  public:
    constexpr bool ground() const noexcept {
      return scanner_.ground();
    }

    void feed(GhosttyTerminal terminal, std::span<const Byte> bytes, TerminalSize size);

  private:
    void feedCommands(GhosttyTerminal terminal, std::span<const Byte> bytes, TerminalSize size);

    static void advance(GhosttyTerminal terminal, DisplayCells cells, TerminalSize size);

    KittyCommandScanner scanner_;
    KittyCursor cursor_;
  };

  struct GraphicsChildFile {
    FileDescriptor descriptor;
    std::uint64_t size;

    static ds::Option<GraphicsChildFile> open(std::string_view encoded_path) noexcept;

    static ds::Option<GraphicsChildFile> openDecoded(std::span<const std::uint8_t> decoded_path) noexcept;

    static ds::Option<GraphicsChildFile> openPath(const char* decoded) noexcept;

    bool read(std::span<std::uint8_t> bytes, std::uint64_t offset) const noexcept;
  };

  // Mappings that stand in for placeholder allocations, shared by the threads that decode and draw
  // images under its mutex. A mapping lives until its placeholder is deallocated.
  class TBC_SHARED MappedImages {
  public:
    bool adopt(const void* placeholder, MappedRegion& pixels) noexcept;

    MappedRegion take(const void* placeholder) noexcept;

    // The pixels standing in for a placeholder, which live as long as it does, or the bytes themselves.
    tbc::view<std::span<const std::uint8_t>, tbc::lt::a> resolve(tbc::view<std::span<const std::uint8_t>, tbc::lt::a> bytes) const noexcept;

  private:
    struct Entry {
      const void* placeholder = nullptr;
      MappedRegion pixels;
    };

    static constexpr std::size_t capacity = 64;
    tbc::view<ds::Array<Entry, capacity>, tbc::lt::a> entries_;
    mutable std::mutex mutex_;
    std::atomic<std::size_t> count_{0};
  };

  struct MediaUsage {
    // Accessed only while holding its associated MediaBudget mutex.
    std::size_t bytes = 0;
  };

  // The bytes every pane's media may hold, which the panes reserve from at once under its mutex.
  class TBC_SHARED MediaBudget {
  public:
    constexpr explicit MediaBudget(std::size_t limit) noexcept
        : limit_(limit) {}

    bool reserve(std::size_t& pane_used, std::size_t pane_limit, std::size_t bytes) noexcept;

    void release(std::size_t& pane_used, std::size_t bytes) noexcept;

    std::size_t used() const noexcept;

    std::size_t usedBy(const std::size_t& pane_used) const noexcept;

  private:
    mutable std::mutex mutex_;
    std::size_t limit_;
    std::size_t used_ = 0;
  };

  // Generic over the caller's upstream allocator, so it stays here.
  template <Allocator Upstream>
  class TBC_SHARED TBC_GENERIC MediaAllocator {
  public:
    static constexpr bool thread_safe = ConcurrentAllocator<Upstream>;

    explicit MediaAllocator(Upstream& upstream, MediaBudget& budget, std::size_t pane_limit, MediaUsage* usage = nullptr) noexcept
        : upstream_(upstream),
          budget_(budget),
          limit_(pane_limit),
          usage_(usage != nullptr ? *usage : local_usage_) {}

    MediaAllocator(const MediaAllocator&) = delete;
    MediaAllocator& operator=(const MediaAllocator&) = delete;

    void* allocate(std::size_t size, std::size_t alignment) noexcept {
      if (!reserve(size)) {
        return nullptr;
      }

      auto* pointer = upstream_.allocate(size, alignment);
      if (pointer == nullptr) {
        release(size);
      }

      return pointer;
    }

    void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept {
      if (pointer != nullptr) {
        auto mapping = mappings_.take(pointer);
        if (mapping) {
          const auto bytes = mapping.bytes().size();

          mapping = {};
          release(bytes);
        }

        upstream_.deallocate(pointer, size, alignment);
        release(size);
      }
    }

    bool reserve(std::size_t bytes) noexcept {
      return budget_.reserve(usage_.bytes, limit_, bytes);
    }

    void release(std::size_t bytes) noexcept {
      budget_.release(usage_.bytes, bytes);
    }

    std::size_t used() const noexcept {
      return budget_.usedBy(usage_.bytes);
    }

    MediaUsage& usage() noexcept {
      return usage_;
    }

    bool adoptMapping(const void* placeholder, MappedRegion& pixels) noexcept {
      return mappings_.adopt(placeholder, pixels);
    }

    tbc::view<std::span<const std::uint8_t>, tbc::lt::a> imagePixels(tbc::view<std::span<const std::uint8_t>, tbc::lt::a> bytes) const noexcept {
      return mappings_.resolve(bytes);
    }

  private:
    Upstream& upstream_;
    MediaBudget& budget_;
    std::size_t limit_;
    MediaUsage local_usage_;
    MediaUsage& usage_;
    tbc::view<MappedImages, tbc::lt::a> mappings_;
  };

  struct GraphicsQueryResources {
    constexpr GraphicsQueryResources() = default;

    constexpr GraphicsQueryResources(GraphicsLimits values) noexcept
        : limits(values) {}

    constexpr GraphicsQueryResources(GraphicsLimits values, MediaBudget& shared, MediaUsage* pane_usage = nullptr) noexcept
        : limits(values),
          budget(&shared),
          usage(pane_usage) {}

    GraphicsLimits limits{};
    // Borrowed from RuntimeModel, which outlives all pane controllers/workers.
    // Standalone terminals use a local budget with the same configured limits.
    MediaBudget* budget = nullptr;
    // Owned by PaneMedia; Terminal is destroyed before that shared owner.
    MediaUsage* usage = nullptr;
  };

  // The opened descriptor establishes which file is read. Only a canonical
  // temporary path with the protocol marker may be removed, and replacement
  // entries are checked again before cleanup. No caller-owned path is retained.
  class GraphicsTemporaryPath {
  public:
    constexpr explicit GraphicsTemporaryPath(const GraphicsChildFile& file) noexcept
        : file_(file) {}

    GraphicsTemporaryPath(const GraphicsTemporaryPath&) = delete;
    GraphicsTemporaryPath& operator=(const GraphicsTemporaryPath&) = delete;

    ~GraphicsTemporaryPath();

    // The refusal, if any, is a literal.
    tbc::view<std::string_view, tbc::lt::static_storage> authorize() noexcept;

  private:
    const GraphicsChildFile& file_;
    ds::Array<char, PATH_MAX> path_{};
    bool armed_ = false;
  };

  // terminal/png_decoder.cpp defines these outside any module: its default limit is the screen's
  // from telar.runtime.terminal.graphics_storage, which imports the control module above this one.
  extern "C++" {
  void installPngDecoder();
  // The decoded pixels are a block of the allocator, region `a`, that the image keeps.
  bool decodePngImage(tbc::view<const GhosttyAllocator*, tbc::lt::a> allocator, std::span<const std::uint8_t> bytes, tbc::view<GhosttySysImage&, tbc::lt::a> image, std::size_t limit = 128 * 1024 * 1024) noexcept;
  }

}
