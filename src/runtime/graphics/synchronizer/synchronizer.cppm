module;
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.graphics.synchronizer;

import std;
import telar.tbc;

import telar.runtime.graphics.prepared_images;

import telar.runtime.graphics.pane_media;

import telar.runtime.diagnostics.runtime_counters;
import telar.runtime.transport.connection;
import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.runtime.terminal.kitty;
import telar.runtime.terminal.control;
import telar.base.memory.allocators;
import telar.runtime.terminal.graphics_storage;
import telar.base.ds;

// Interface: graphics/credit.cppm
export {
  namespace telar::runtime {

    class GraphicsCreditBudget {
    public:
      bool acquire(std::size_t bytes) noexcept;

      void release(std::size_t bytes) noexcept;

      [[nodiscard]] std::size_t used() const noexcept;

      [[nodiscard]] std::size_t available() const noexcept;

      static constexpr std::size_t limit = std::size_t{512} * 1024 * 1024;

    private:
      std::size_t used_ = 0;
    };

    class GraphicsCreditLedger {
    public:
      explicit GraphicsCreditLedger(GraphicsCreditBudget& budget) noexcept;

      ~GraphicsCreditLedger();

      GraphicsCreditLedger(const GraphicsCreditLedger&) = delete;
      GraphicsCreditLedger& operator=(const GraphicsCreditLedger&) = delete;
      GraphicsCreditLedger(GraphicsCreditLedger&&) = delete;
      GraphicsCreditLedger& operator=(GraphicsCreditLedger&&) = delete;

      [[nodiscard]] bool canReserve(std::size_t bytes) const noexcept;

      bool reserve(std::size_t bytes) noexcept;

      bool returnBytes(std::uint64_t bytes) noexcept;

      [[nodiscard]] std::size_t available() const noexcept;

    private:
      GraphicsCreditBudget& budget_;
      std::size_t available_ = graphics_credit_bytes;
    };

  }
}

// Interface: graphics/media_processor.cppm
export {
  namespace telar::runtime {

    class MediaProcessor {
    public:
      struct Entry {
        std::uint64_t pane = 0;
        std::uint64_t generation = 0;
        std::shared_ptr<PaneMedia> media;
        bool reset = false;
#if TELAR_DIAGNOSTICS
        diagnostics::MediaCounters metrics{};
#endif
      };

      struct Request {
        static constexpr std::size_t capacity = 8;
        ds::Array<Entry, capacity> entries;
        std::size_t count = 0;
      };

      using Result = Request;

      // The result carries the request's media on.
      static tbc::val_a<Result> observe(tbc::ref_a<Request> request) noexcept;

      void stop() noexcept;
    };

  }
}

// Interface: graphics/synchronizer.cppm
export {
  namespace telar::runtime {

    class GraphicsSynchronizer {
    public:
      enum class StageResult : std::uint8_t {
        idle,
        blocked,
        staged,
      };

      // The credit budget, the pane's media and the runtime's counters are region `a`.
      explicit GraphicsSynchronizer(tbc::mut_a<GraphicsCreditBudget> budget, std::uint64_t pane, tbc::val_a<std::shared_ptr<PaneMedia>> media);

      ~GraphicsSynchronizer();
      GraphicsSynchronizer(const GraphicsSynchronizer&) = delete;
      GraphicsSynchronizer& operator=(const GraphicsSynchronizer&) = delete;
      GraphicsSynchronizer(GraphicsSynchronizer&&) = delete;
      GraphicsSynchronizer& operator=(GraphicsSynchronizer&&) = delete;

      template <Allocator GraphicsMemory>
      [[nodiscard]] bool synchronized(const GraphicsStorage<GraphicsMemory>& storage) const noexcept;

#if TELAR_DIAGNOSTICS
      [[nodiscard]] std::size_t transferBytes() const noexcept;
#endif

      void requestSnapshot() noexcept;

      void configure(bool shared) noexcept;

      void returnCredit(std::uint64_t bytes) noexcept;

#if TELAR_DIAGNOSTICS
      // What the synchronizer counted since the last call, which the caller adds to the runtime's metrics.
      diagnostics::GraphicsCounters takeCounters() noexcept;
#endif

      [[nodiscard]] bool wantsImage(ImageKey key, bool shared) const noexcept;

      void abandon(std::uint64_t revision) noexcept;

      bool advanceTransfer(Connection<ConcurrentMemory>& connection);

      template <Allocator GraphicsMemory>
      bool publish(Connection<ConcurrentMemory>& connection, const GraphicsStorage<GraphicsMemory>& storage);

      // Not inlined: publish runs for every attached pane on every frame and stages only when the images
      // changed; its locals in that frame would put every frame's calls on deeper stack pages.
      template <Allocator GraphicsMemory>
      [[gnu::noinline]] StageResult stage(const GraphicsStorage<GraphicsMemory>& storage);

      template <Allocator GraphicsMemory>
      void stageAtMediaBoundary(const GraphicsStorage<GraphicsMemory>& storage) noexcept;

    private:
      // What the synchronizer counts for diagnostics, nothing in a build without them.
      struct Metrics {
#if TELAR_DIAGNOSTICS
        diagnostics::GraphicsCounters counters;
        std::uint64_t available_revision = 0;
        std::uint64_t pending_blocked = 0;
        std::uint64_t pending_adopted = 0;
#endif
      };

      // Sends through the connection and counts it: the connection and the metrics alone, so what the
      // synchronizer knows stays borrowed while it sends.
      template <typename Message>
      static void send(Connection<ConcurrentMemory>& connection, const Message& message, Metrics& metrics);

      template <Allocator GraphicsMemory>
      void initialize(const GraphicsStorage<GraphicsMemory>& storage) noexcept;

      enum class SnapshotState : std::uint8_t {
        idle,
        pending,
        open,
      };

      struct Transfer {
        ImageDescription image;
        std::uint64_t revision;
        FrozenImage frozen;
        std::size_t offset = 0;
        ds::Array<GraphicsPlacement, graphics_placement_count> placements{};
        std::size_t placement_count = 0;
        std::size_t placement_index = 0;
        bool metadata_sent = false;
      };

      bool publishTransfer(Connection<ConcurrentMemory>& connection, GraphicsHeader header);

      // The steps of publish past its transfer, each sending at most one message: true when it sent one.
      template <Allocator GraphicsMemory>
      bool deleteStaleImage(Connection<ConcurrentMemory>& connection, const GraphicsStorage<GraphicsMemory>& storage, GraphicsHeader header);

      template <Allocator GraphicsMemory>
      bool deleteStalePlacement(Connection<ConcurrentMemory>& connection, const GraphicsStorage<GraphicsMemory>& storage, GraphicsHeader header);

      template <Allocator GraphicsMemory>
      bool sendChangedPlacement(Connection<ConcurrentMemory>& connection, const GraphicsStorage<GraphicsMemory>& storage, GraphicsHeader header);

      [[nodiscard]] bool knows(ImageKey key) const noexcept;

      // The slot among the known placements for `identity`: those alone, so a transfer stays borrowed.
      static GraphicsPlacement& placementSlot(std::span<GraphicsPlacement> placements, std::uint64_t identity);

      static constexpr std::size_t maximum_chunk_bytes = std::size_t{1024} * 1024;
      static constexpr std::size_t maximum_queue_bytes = std::size_t{2} * 1024 * 1024;
      // Frozen transfers borrow this pane's allocator until their destruction.
      tbc::val_a<std::shared_ptr<PaneMedia>> media_;
      tbc::val_a<GraphicsCreditLedger> credit_;
      std::uint64_t pane_;
      // Keeps the media media_ owns.
      tbc::val_self<ds::Option<Transfer>> transfer_;
      ds::Array<ImageKey, graphics_image_count * 2> known_images_{};
      ds::Array<GraphicsPlacement, graphics_placement_count * 2> known_placements_{};
      std::uint64_t observed_revision_ = 0;
      SnapshotState snapshot_ = SnapshotState::idle;
      bool shared_ = false;
      bool initialized_ = false;
      [[no_unique_address]] Metrics metrics_;
    };

    // The storages it publishes: the pane terminal's and the media terminal's.
    extern template bool GraphicsSynchronizer::synchronized<telar::ConcurrentMemory>(const GraphicsStorage<telar::ConcurrentMemory>& storage) const noexcept;
    extern template bool GraphicsSynchronizer::publish<telar::ConcurrentMemory>(Connection<telar::ConcurrentMemory>& connection, const GraphicsStorage<telar::ConcurrentMemory>& storage);
    extern template GraphicsSynchronizer::StageResult GraphicsSynchronizer::stage<telar::ConcurrentMemory>(const GraphicsStorage<telar::ConcurrentMemory>& storage);
    extern template void GraphicsSynchronizer::stageAtMediaBoundary<telar::ConcurrentMemory>(const GraphicsStorage<telar::ConcurrentMemory>& storage) noexcept;
    extern template bool GraphicsSynchronizer::synchronized<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>(const GraphicsStorage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>& storage) const noexcept;
    extern template bool GraphicsSynchronizer::publish<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>(Connection<telar::ConcurrentMemory>& connection, const GraphicsStorage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>& storage);
    extern template GraphicsSynchronizer::StageResult GraphicsSynchronizer::stage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>(const GraphicsStorage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>& storage);
    extern template void GraphicsSynchronizer::stageAtMediaBoundary<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>(const GraphicsStorage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>& storage) noexcept;

  }
}
