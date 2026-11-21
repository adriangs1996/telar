export module telar.runtime.nvim.frames;

import std;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.wire.nvim;
import telar.wire.vocabulary;
import telar.runtime.nvim.screen;

// Interface: nvim/frames.cppm
export {
  namespace telar::runtime {

    // Writes what a client lacks of an editor's screen as the messages of one frame: an NvimGrid
    // for each grid that changed after the frame the client has, then the NvimFrame that ends
    // them. One encoder serves every pane and client in turn: it keeps only the buffers a frame
    // is built in, so a frame costs no allocation once they have grown.
    class NvimFrames {
    public:
      // The cells one NvimGrid carries: the largest grid crosses in messages that each fit a
      // frame of the transport.
      static constexpr std::size_t message_cells = std::size_t{32} * 1024;

      explicit NvimFrames(ConcurrentMemory& memory);

      // Whether a client that has frame `seen` lacks something the screen shows.
      [[nodiscard]] static bool pending(const NvimScreen& screen, std::uint64_t seen) noexcept;

      // Starts the frame of pane `pane_id` for a client that has frame `seen`, zero for one
      // that has none and is sent every grid whole. The screen must be settled, and stay as it
      // is until `end`.
      void begin(const NvimScreen& screen, std::uint64_t pane_id, std::uint64_t seen);

      // The next message of the frame's grids, which views this encoder's buffers until the
      // next call; none once every grid that changed was sent.
      [[nodiscard]] ds::Option<NvimGrid> next(const NvimScreen& screen);

      // The native surfaces, each as the message that says how it is now when it changed after
      // the frame the client has. They view the screen and this encoder's buffers until `begin`.
      [[nodiscard]] ds::Option<NvimCmdline> cmdline(const NvimScreen& screen) const;
      [[nodiscard]] ds::Option<NvimPopupMenu> popupMenu(const NvimScreen& screen);
      [[nodiscard]] ds::Option<NvimMessageList> messageList(const NvimScreen& screen);
      [[nodiscard]] ds::Option<NvimTabLine> tabLine(const NvimScreen& screen);

      // The message that ends the frame, which views this encoder's buffers until `begin`.
      [[nodiscard]] NvimFrame end(const NvimScreen& screen);

    private:
      // The rows of the grid being sent that one message takes, from `row_` on.
      void collect(const NvimScreen& screen, const NvimScreenGrid& grid);
      void appendRow(const NvimScreen& screen, const NvimScreenGrid& grid, std::uint32_t row);
      void encodeSpans();
      [[nodiscard]] NvimGrid message(const NvimScreenGrid& grid, bool first) const;
      void start(const NvimScreenGrid& grid);

      // A run of consecutive rows: the cells it holds in `cells_`, and where its first cell is
      // in the grid.
      struct Run {
        std::size_t first = 0;
        std::size_t count = 0;
        std::uint32_t start = 0;
      };

      ds::Vec<Cell, ConcurrentMemory> cells_;
      ds::Vec<Byte, ConcurrentMemory> texts_;
      ds::Vec<Byte, ConcurrentMemory> bytes_;
      ds::Vec<Run, ConcurrentMemory> runs_;
      ds::Vec<FrameSpan, ConcurrentMemory> spans_;
      ds::Vec<std::uint32_t, ConcurrentMemory> removed_;
      ds::Vec<NvimMenuItem, ConcurrentMemory> menu_items_;
      ds::Vec<NvimMessageItem, ConcurrentMemory> messages_;
      ds::Vec<NvimTab, ConcurrentMemory> tabs_;
      ds::Vec<NvimTab, ConcurrentMemory> buffers_;
      ds::Array<char, max_nvim_mode_bytes> mode_{};
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
