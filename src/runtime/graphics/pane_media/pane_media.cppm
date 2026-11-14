module;
#include "tbc/annotations.hpp"
#include <ghostty/vt.h>

#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.graphics.pane_media;

import std;
import telar.sys.posix;

export import telar.runtime.graphics.file_input;

export import telar.runtime.terminal.osc_scanner;
export import telar.runtime.graphics.prepared_images;

export import telar.runtime.diagnostics.runtime_counters;
export import telar.runtime.diagnostics.operation;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.config.core;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;
import telar.runtime.terminal.text_reader;

// Interface: graphics/atomic_frame_filter.cppm
export {
  namespace telar::runtime {

    // Where AtomicFrameFilter checks a frame's upload and lets it go. One indirect call per frame.
    class AtomicFrameSource {
    public:
      virtual bool available(const AtomicFrameResource& resource) = 0;
      virtual void release(const AtomicFrameResource& resource) = 0;

    protected:
      AtomicFrameSource() = default;
      AtomicFrameSource(const AtomicFrameSource&) = default;
      AtomicFrameSource& operator=(const AtomicFrameSource&) = default;
      ~AtomicFrameSource() = default;
    };

    // What AtomicFrameFilter writes to: the bytes it passes through and the frames it selects. One
    // indirect call per run of bytes or frame.
    class AtomicFrameSink {
    public:
      virtual void output(std::span<const std::uint8_t> bytes) = 0;
      virtual bool atomicFrame(const AtomicFrameView& frame) = 0;

    protected:
      AtomicFrameSink() = default;
      AtomicFrameSink(const AtomicFrameSink&) = default;
      AtomicFrameSink& operator=(const AtomicFrameSink&) = default;
      ~AtomicFrameSink() = default;
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

      static Statistics feed(std::span<const std::uint8_t> bytes, std::size_t storage_limit, AtomicFrameSource& source, AtomicFrameSink& sink);

    private:
      static constexpr std::size_t maximum_placements = 256;
      static constexpr std::size_t recent_frames = 8;

      struct SelectedFrame {
        AtomicFrameKey key;
        std::array<std::size_t, recent_frames> recent;
        std::size_t recent_count;
        std::optional<std::size_t> selected;
      };

      static bool record(std::span<SelectedFrame> entries, std::size_t& count, const AtomicFrame& frame) noexcept;

      static std::optional<std::size_t> selectedStart(std::span<const SelectedFrame> entries, AtomicFrameKey key) noexcept;

      static AtomicFrameResource resource(const AtomicFrame& frame, std::size_t storage_limit) noexcept;

      static void output(std::span<const std::uint8_t> bytes, AtomicFrameSink& sink);
    };

  }
}

// Interface: graphics/frame_source.cppm
export {
  namespace telar::runtime {

    class GraphicsFrameSource {
    public:
      // Where a child's upload lies once it checks out: a non-empty upload within its limit, in a file
      // or a shared memory object that holds at least its bytes.
      struct Handle {
        std::optional<GraphicsChildFile> file;
        FileDescriptor shared;
      };

      // The upload's handle, or none; a shared memory object's name comes back in `name`.
      static std::optional<Handle> validate(const AtomicFrameResource& resource, std::array<std::uint8_t, PATH_MAX + 1>& name) noexcept;

      static bool available(const AtomicFrameResource& resource) noexcept;

      static void release(const AtomicFrameResource& resource) noexcept;
    };

  }
}

// Interface: graphics/frame_pixels.cppm
export {
  namespace telar::runtime {

    class GraphicsFramePixels {
    public:
      static std::optional<GraphicsFramePixels> open(const AtomicFrameResource& resource) noexcept;

      bool copyTo(std::span<std::uint8_t> destination) const noexcept;

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

      explicit GraphicsUploadLimits(std::size_t byte_limit, std::size_t chunk_limit = GraphicsLimits::maximum_chunks_per_image) noexcept;

      Observation observe(GhosttyTerminal terminal, std::span<const std::uint8_t> bytes);

      Observation observeEncodedChunk(GhosttyTerminal terminal);

      std::optional<std::uint32_t> enforce(GhosttyTerminal terminal, const Observation& observation);

      Reached takeReached() noexcept;

    private:
      static GhosttyKittyGraphics storage(GhosttyTerminal terminal);

      static std::optional<std::uint32_t> loadingImage(GhosttyKittyGraphics graphics);

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
    class MediaTerminal final : public MediaInputSink {
    public:
      explicit MediaTerminal(Memory& memory, TerminalSize size, GraphicsLimits limits, std::shared_ptr<PtyResponseQueue> responses = {});

      void feed(std::span<const Byte> bytes);

      void ordinary(std::span<const Byte> bytes);

      bool enquire() const noexcept;

      // Documents stream past the media terminal, which ignores them, instead of being buffered
      // whole: the interactive terminal keeps them.
      bool streamable(control::Sequence sequence) const noexcept;

      bool complete(control::Sequence sequence);

      void reply(std::span<const Byte> bytes);

      void ingest(std::span<const Byte> bytes) override;

      void ingestEncodedChunk(std::span<const Byte> bytes) override;

      void resize(TerminalSize size);

      void refresh();

      bool insertImage(const AtomicFrameControl& control, std::span<const Byte> data) noexcept;

      ImageKey imageKey(std::uint32_t identity);

#if TELAR_DIAGNOSTICS
      diagnostics::GraphicsStorageSnapshot storageMetrics();
#endif

      std::size_t storageLimit() const noexcept;

      std::span<const Byte> responses() const noexcept;

      void consumeResponses(std::size_t count) noexcept;

      bool drainResponses() noexcept;

      bool pendingResponses() const noexcept;

      std::size_t nextResponseSize() const noexcept;

      bool responseFailed() const noexcept;

      void requireOpen() const;

      GraphicsUploadLimits::Reached takeUploadLimits() noexcept;

      GraphicsStorage<Memory> graphics;

    private:
      struct ResponseFailure {};

      void write(std::span<const Byte> bytes, const GraphicsUploadLimits::Observation& observation);

      void replyUploadLimit(std::uint32_t image);

      static void receiveResponse(GhosttyTerminal, void* context, const Byte* bytes, std::size_t count) noexcept;

      control::Parser<Memory> control_parser_;
      GhosttyAllocatorBridge<Memory> allocator_;
      TerminalHandle terminal_;
      std::shared_ptr<PtyResponseQueue> responses_;
      ResponseOutbox<Memory> response_outbox_;
      std::size_t storage_limit_;
      GraphicsUploadLimits uploads_;
      bool response_failed_ = false;
    };

    extern template class MediaTerminal<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>;

  }
}

// Interface: graphics/atomic_frame_loader.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class AtomicFrameLoader {
    public:
      explicit AtomicFrameLoader(MediaAllocator<Memory>& memory, MediaTerminal<MediaAllocator<Memory>>& terminal, PreparedImages<Memory>& prepared) noexcept;

      bool load(const AtomicFrameView& frame, bool shared_transport);

    private:
      void place(AtomicFrameKey key);

      MediaAllocator<Memory>& memory_;
      MediaTerminal<MediaAllocator<Memory>>& terminal_;
      PreparedImages<Memory>& prepared_;
    };

    extern template class AtomicFrameLoader<telar::ConcurrentMemory>;

  }
}

// Interface: graphics/media_input.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class MediaInput final : public AtomicFrameSink {
    public:
      explicit MediaInput(MediaAllocator<Memory>& memory, MediaTerminal<MediaAllocator<Memory>>& terminal, PreparedImages<Memory>& prepared, const std::atomic<unsigned>& shared_clients) noexcept;

      AtomicFrameFilter::Statistics feed(std::span<const Byte> bytes);

      void output(std::span<const Byte> bytes) override;

      // The input lends the terminal, so a batch resizes it through the input too.
      void resize(TerminalSize size);

      bool atomicFrame(const AtomicFrameView& frame) override;

    private:
      class CheckedSource final : public AtomicFrameSource {
      public:
        explicit CheckedSource(MediaTerminal<MediaAllocator<Memory>>& terminal) noexcept;

        bool available(const AtomicFrameResource& resource) override;

        void release(const AtomicFrameResource& resource) override;

      private:
        MediaTerminal<MediaAllocator<Memory>>& terminal_;
      };

      MediaTerminal<MediaAllocator<Memory>>& terminal_;
      AtomicFrameLoader<Memory> atomic_frames_;
      const std::atomic<unsigned>& shared_clients_;
    };

    extern template class MediaInput<telar::ConcurrentMemory>;

    template <Allocator Memory>
    MediaInput(MediaAllocator<Memory>& memory, MediaTerminal<MediaAllocator<Memory>>& terminal, PreparedImages<Memory>& prepared, const std::atomic<unsigned>& shared_clients) -> MediaInput<Memory>;

  }
}

// Interface: graphics/pane_media.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class PaneMedia final : public TerminalMedia {
    public:
      using AllocatedMemory = MediaAllocator<Memory>;

      explicit PaneMedia(Memory& memory, MediaBudget& budget, GraphicsLimits limits, TerminalSize size, std::shared_ptr<PtyResponseQueue> responses = {});

      void requireOrderedInput() noexcept override;

      // The prefix of the input made of whole atomic frames, which the terminal parses as one unit.
      std::size_t atomicPrefix(std::span<const Byte> bytes) const noexcept override;

      void output(std::span<const Byte> bytes) noexcept override;

      void resize(TerminalSize size) noexcept;

      bool holdsRead(std::size_t bytes) const noexcept;

      bool seal() noexcept;

      void complete() noexcept;

      bool process() noexcept;

      // Only the runtime calls cancel/complete. A busy worker observes the closed
      // queue, then ownership returns through ObservationWorker before cleanup.
      void cancel() noexcept;

      bool failed() const noexcept override;

#if TELAR_DIAGNOSTICS
      diagnostics::GraphicsStorageSnapshot storageMetrics();

      const diagnostics::MediaQueue& queueMetrics() const noexcept;

      void noteHeldRead() noexcept;

      std::size_t usedBytes() const noexcept;

      const diagnostics::MediaCounters& batchMetrics() const noexcept;
#endif

      MediaUsage& queryUsage() noexcept;

      bool busy() const noexcept;

      void noteSharedTransport(bool added) noexcept;

      std::optional<FrozenImage<Memory>> takeTransfer(ImageKey key, bool shared);

      // Generic over the caller's predicate, so it stays here.
      template <typename Consumer>
      TBC_HOT_PATH inline void discardUnwantedTransfers(const Consumer& wanted) noexcept {
        prepared_.discardUnwanted(wanted);
        requests_.discardUnwanted(wanted);
      }

      bool idle() const noexcept override;

      MediaTerminal<AllocatedMemory>* terminal() noexcept;

      std::uint64_t takeDroppedBytes() noexcept;

      std::shared_ptr<PaneMedia> retired_next;

    private:
      void responseProgress() noexcept;

#if TELAR_DIAGNOSTICS
      void observeQueue() noexcept;
#endif

      void dropActive(std::size_t incoming) noexcept;

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

    extern template class PaneMedia<telar::ConcurrentMemory>;

  }
}
