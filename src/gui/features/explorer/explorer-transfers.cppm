// The files the explorer carries from one machine to another. The runtimes do not talk to each
// other and the window is connected to each, so it reads a chunk from one and writes it to the
// other, one chunk in flight for each file. A transfer is this state machine; whoever drives
// the explorer sends what it asks and gives it the answers.
export module telar.gui.features.explorer:transfers;

import std;

import :cache;
import :files;
import :view;
import telar.base.ds;
import telar.tbc;

export namespace telar::gui::features::explorer {

  struct TransferLimits {
    // The transfers that run at once; the others wait their turn. And the ones the explorer
    // keeps, waiting, running and just ended.
    static constexpr std::size_t running = 2;
    static constexpr std::size_t kept = 64;
    // How often the progress of one shows, and how long one that ended stays in view.
    static constexpr std::uint64_t shown_every_ms = 250;
    static constexpr std::uint64_t lingers_ms = 8000;
  };

  // A row a transfer adds to the directory its file arrives in carries the transfer's id with
  // this bit, where a row a change adds carries the change's.
  inline constexpr std::uint32_t arriving_item = 0x80000000;

  // What a transfer asks next of a runtime.
  enum class TransferAsk : std::uint8_t {
    none,
    // The next chunk of the source; the chunk it holds written to the partial.
    read,
    write,
    // The partial given the target's name, or removed.
    keep,
    drop,
    // Of a tree: a link made where it goes, that says what the chunk it holds does.
    link,
    // The source of a move sent to the trash of its machine.
    trash,
    // Of a tree: the directory its walk is in made where it goes; that directory's listing,
    // which the cache of its machine reads and no request of the transfer's own; and the
    // directory the tree had made sent to the trash, after a failure or a cancel.
    make,
    list,
    clear,
  };

  // A request that left for a transfer: its number, the connection it left on, and when.
  struct Sent {
    std::uint64_t request = 0;
    std::uint64_t epoch = 0;
    std::uint64_t now_ms = 0;
  };

  struct Asking {
    TransferAsk ask = TransferAsk::none;
    std::uint64_t machine = 0;

    friend bool operator==(const Asking&, const Asking&) = default;
  };

  // What `transfer` asks now: nothing while a request of its is in flight, while it waits its
  // turn, and once it ended.
  [[nodiscard]] Asking asks(const View& view, std::size_t index) noexcept;

  // The path `ask` is about: what is read, listed or sent to the trash where it comes from, or
  // what is made, written or named where it goes.
  void pathOf(ds::String<Memory>& path, const Transfer& transfer, TransferAsk ask);

  // The identity its runtime checks before it reads: the file's, of a tree the one being carried.
  [[nodiscard]] FileIdentity readIdentity(const Transfer& transfer) noexcept;

  // How much of it arrived, and of how much: of a tree, of what its walk has seen so far.
  [[nodiscard]] std::uint64_t arrivedBytes(const Transfer& transfer) noexcept;
  [[nodiscard]] std::uint64_t wholeBytes(const Transfer& transfer) noexcept;

  // The listing of the directory a tree's walk is in, whole: its files wait their turn, its
  // directories are walked after, a link is read as what it says, and what is none is left out.
  void walked(View& view, std::size_t index, const Directory& directory, std::uint64_t now_ms);

  // Whether what the transfer changes next on `machine` joins the change its plan already made
  // there, and is no change of its own.
  [[nodiscard]] bool joins(const ds::Vec<Begun, Memory>& begun, std::uint32_t batch, std::uint64_t machine) noexcept;

  // Its request left under `request_id`, on the connection `epoch` of the machine it went to.
  void asked(Transfer& transfer, const Sent& sent) noexcept;

  // The answer to its request in flight: the transfer goes on, ends, or starts to remove what
  // had arrived.
  void take(View& view, std::size_t index, Carried& answer, std::uint64_t now_ms);

  // The connection its request left on is gone, and nothing answers it.
  void lose(View& view, std::size_t index, std::uint64_t now_ms);

  // Fails the transfers to or from a machine the window no longer reaches: nothing answers
  // them. Returns how many.
  std::size_t strand(View& view, const Context& context, std::uint64_t now_ms);

  // It cannot go on, for what `why` says: what had arrived is removed first.
  void giveUp(View& view, std::size_t index, std::string_view why, std::uint64_t now_ms);

  // The machine the request it has in flight went to; 0 with none in flight.
  [[nodiscard]] std::uint64_t awaits(const Transfer& transfer) noexcept;

  // Starts to carry what the plan sends from one machine to another, and takes those changes
  // out of the ones typed. Returns how many transfers it started.
  std::size_t carry(View& view);

  // Brings the file the question asked about to the machine of the panes. False when the
  // explorer keeps as many transfers as it can.
  bool bring(View& view);

  // Asks the transfers to or from `machine` to stop, or every one when it is 0. Returns how
  // many. One stops once no request of its is in flight, which `halt` then does.
  std::size_t stopTransfers(View& view, std::uint64_t machine);

  // Asks the transfer `id` to stop. False when it is past stopping, or there is none.
  bool stopTransfer(View& view, std::uint32_t id);

  // Stops a transfer that was asked to and waits for no answer: what had arrived is removed
  // first, when something had. False for any other transfer.
  bool halt(View& view, std::size_t index, std::uint64_t now_ms);

  // Forgets the transfers that ended a while ago, and shows the progress that waited its turn.
  // True when one went.
  bool sweep(View& view, std::uint64_t now_ms);

  // How many transfers have not ended.
  [[nodiscard]] std::size_t transferring(const View& view) noexcept;

  // The transfer whose file a row stands for; none for any other row.
  [[nodiscard]] tbc::val_a<const Transfer*> transferOf(tbc::ref_a<View> view, const Row& row) noexcept;

  // Whether it ended, arrived or not.
  [[nodiscard]] bool ended(TransferPhase phase) noexcept;

}
