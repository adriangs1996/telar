export module telar.runtime.nvim.frames;

import std;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.runtime.nvim.screen;

// Interface: nvim/frames.cppm
export {
  namespace telar::runtime {

    // Whose frame an encoder writes: the pane's, for a client that has frame `seen`, zero for
    // one that has none and is sent every grid whole.
    struct NvimFrameFor {
      std::uint64_t pane_id = 0;
      std::uint64_t seen = 0;
    };

    // Writes what a client lacks of an editor's screen as the messages of one frame, each
    // already encoded: an NvimGrid for each grid that changed after the frame the client has,
    // the native surfaces that changed, then the NvimFrame that ends them. One encoder serves
    // every pane and client in turn: it keeps only the buffers a message is written in, so a
    // frame costs no allocation once they have grown.
    class NvimFrames {
    public:
      // The cells one NvimGrid carries, so the largest grid crosses in messages that each fit a
      // frame of the transport; the cells one of its spans holds; and the spans it may have.
      static constexpr std::size_t message_cells = std::size_t{32} * 1024;
      static constexpr std::size_t span_cells = 512;
      static constexpr std::size_t message_spans = 512;

      explicit NvimFrames(ConcurrentMemory& memory);

      // Whether a client that has frame `seen` lacks something the screen shows.
      [[nodiscard]] static bool pending(const NvimScreen& screen, std::uint64_t seen) noexcept;

      // Starts the frame `target` names. The screen must be settled, and stay as it is until
      // `end`.
      void begin(const NvimScreen& screen, NvimFrameFor target);

      // The id of the frame being written.
      [[nodiscard]] std::uint64_t frame() const noexcept;

      // Each of the following gives the bytes of one message, which stay until the next call.

      // The next NvimGrid of the frame; empty once every grid that changed was written.
      [[nodiscard]] std::span<const Byte> next(const NvimScreen& screen);

      // The native surfaces: each as the message that says how it is now, empty when it did not
      // change after the frame the client has.
      [[nodiscard]] std::span<const Byte> cmdline(const NvimScreen& screen);
      [[nodiscard]] std::span<const Byte> popupMenu(const NvimScreen& screen);
      [[nodiscard]] std::span<const Byte> messageList(const NvimScreen& screen);
      [[nodiscard]] std::span<const Byte> tabLine(const NvimScreen& screen);
      // The files the editor's buffers show, which is no surface: the same rule tells it.
      [[nodiscard]] std::span<const Byte> openFiles(const NvimScreen& screen);

      // The NvimFrame that ends the frame.
      [[nodiscard]] std::span<const Byte> end(const NvimScreen& screen);

    private:
      // A span of cells: where its first cell is in the grid, how many it holds, and where
      // their encoded bytes lie in `cells_`.
      struct Run {
        std::uint32_t start = 0;
        std::uint32_t count = 0;
        std::size_t offset = 0;
        std::size_t size = 0;
      };

      void start(const NvimScreenGrid& grid);
      // Encodes the rows of the grid being sent that one message takes, from `row_` on.
      void collect(const NvimScreen& screen, const NvimScreenGrid& grid);

      ds::Vec<Byte, ConcurrentMemory> cells_;
      ds::Vec<Run, ConcurrentMemory> runs_;
      ds::Vec<Byte, ConcurrentMemory> payload_;
      std::uint64_t pane_ = 0;
      std::uint64_t seen_ = 0;
      std::uint64_t frame_ = 0;
      std::size_t grid_ = 0;
      std::uint32_t row_ = 0;
      // Whether the grid being sent has had its first message, whether every row of it goes, and
      // whether the client moves the rows it has as the grid's last scrolls did.
      bool started_ = false;
      bool whole_ = false;
      bool replay_ = false;
    };

  }
}
