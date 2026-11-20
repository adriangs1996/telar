module;
#include "tbc/annotations.hpp"

export module telar.runtime.redirect.record;

import std;
import telar.tbc;
import telar.native.pcap;
import telar.sys.socket;
import telar.sys.posix;

import telar.runtime.redirect.pf_rules;
import telar.base.memory.containers;
import telar.platform.primitives;
import telar.platform.process;
import telar.vocabulary;
import telar.base.memory.allocators;
import telar.runtime.redirect.direction;
import telar.base.ds;

// Interface: redirect/log_interface.cppm
export {
  namespace telar::runtime::redirect {

    class LogInterface {
    public:
      static constexpr unsigned maximum = 16;

      static unsigned create();

      static void remove(unsigned index);
    };

  }
}

// Interface: redirect/pf_loopback.cppm
export {
  namespace telar::runtime::redirect {

    class LoopbackFlags {
      static constexpr std::size_t request_bytes = 40;
      static constexpr std::size_t flags_offset = 36;

      // Darwin's pfioc_iface layout is absent from the public SDK. Keep this ABI
      // limited to DIOCSETIFFLAG/DIOCCLRIFFLAG and the PFI_IFLAG_SKIP bit on lo0.
      // https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/pfvar.h
      // Its user address and the field after it are aligned to eight bytes.
      struct InterfaceRequest {
        // A C array's layout: Array is one.
        ds::Array<char, IFNAMSIZ> name{};
        alignas(std::uint64_t) void* buffer = nullptr;
        alignas(std::uint64_t) int element_size = 0;
        int size = 0;
        int zero = 0;
        int flags = 0;
      };

      static_assert(sizeof(InterfaceRequest) == request_bytes && __builtin_offsetof(InterfaceRequest, flags) == flags_offset);
      enum class Operation : std::uint32_t {
        set_flags = sys::ioctlReadWrite<InterfaceRequest>('D', 89),
        clear_flags = sys::ioctlReadWrite<InterfaceRequest>('D', 90),
      };
      static constexpr int skip_flag = 0x0100;

    public:
      static void setSkipped(bool skipped);
    };

    // Generic over the caller's command and flags.
    template <typename Command, typename Flags = LoopbackFlags>
    class TBC_GENERIC PfLoopback {
    public:
      inline explicit PfLoopback(Command& command) noexcept
          : command_(command) {}

      inline bool skipped() {
        constexpr ds::Array<std::string_view, 5> arguments{"-v", "-s", "Interfaces", "-i", "lo0"};

        return parse(command_.run(arguments));
      }

      inline void setSkipped(bool value) {
        Flags::setSkipped(value);
        if (skipped() != value) {
          throw std::runtime_error{"PF loopback skip flag did not change"};
        }
      }

      inline static bool parse(std::string_view output) {
        while (!output.empty()) {
          const auto newline = output.find('\n');
          auto line = output.substr(0, newline);
          if (line == "lo0" || line.starts_with("lo0 ") || line.starts_with("lo0\t")) {
            line.remove_prefix(3);
            const auto first = line.find_first_not_of(" \t\r");
            if (first == std::string_view::npos) {
              return false;
            }

            line.remove_prefix(first);
            line = line.substr(0, line.find_last_not_of(" \t\r") + 1);
            if (line == "(skip)") {
              return true;
            }

            break;
          }

          if (newline == std::string_view::npos) {
            break;
          }

          output.remove_prefix(newline + 1);
        }

        throw std::runtime_error{"Cannot read PF loopback skip status"};
      }

    private:
      Command& command_;
    };

  }
}

// Interface: redirect/record_file.cppm
export {
  namespace telar::runtime::redirect {

    enum class RecordLock : std::uint8_t {
      owner,
      update,
    };

    template <Allocator Memory>
    class RecordFile {
    public:
      explicit RecordFile(tbc::mut_a<Memory> memory, std::string_view name, RecordLock mode = RecordLock::owner);

      ds::Option<ds::String<Memory>> load();

      void save(std::string_view content);

      void clear();

    private:
      static void validate(int descriptor);

      tbc::mut_a<Memory> memory_;
      tbc::val_a<ds::String<Memory>> name_;
      FileDescriptor directory_;
      FileDescriptor lock_;
    };

    extern template class RecordFile<Memory>;
    extern template class RecordFile<ConcurrentMemory>;

  }
}

// Interface: redirect/loopback_lease.cppm
export {
  namespace telar::runtime::redirect {

    template <Allocator Memory>
    class LoopbackLeases {
    public:
      explicit LoopbackLeases(Memory& memory);

      // Generic over the caller's store and interface.
      template <typename Store, typename Interface>
      TBC_GENERIC void acquire(Store& store, Interface& interface, std::string_view owner) {
        validateOwner(owner);
        load(store);
        const auto marker = ownerMarker(owner);
        const bool present = std::string_view{owners_}.contains(marker);
        if (!present && owners_.size() / owner_bytes >= maximum_owners) {
          throw std::runtime_error{"Too many transparent redirect loopback owners"};
        }

        const bool skipped = interface.skipped();

        restore_skip_ = restore_skip_ || skipped;
        if (!present) {
          owners_.append(marker);
        }

        // Persist before the ioctl so a failed change or a crash can be recovered.
        save(store);
        if (skipped) {
          interface.setSkipped(false);
        }
      }

      template <typename Store, typename Interface>
      TBC_GENERIC void release(Store& store, Interface& interface, std::string_view owner) {
        validateOwner(owner);
        load(store);
        const auto marker = ownerMarker(owner);
        const auto position = owners_.view().find(marker);
        if (position == std::string_view::npos) {
          return;
        }

        owners_.remove(position, marker.size());
        if (owners_.empty()) {
          if (restore_skip_) {
            interface.setSkipped(true);
          }

          store.clear();
        } else {
          save(store);
        }
      }

    private:
      static constexpr std::size_t owner_bytes = 21;
      static constexpr std::size_t maximum_owners = 64;
      // The first line of a record: whether lo0 skipped pf before the first owner.
      static constexpr std::string_view skip_header = "skip\n";
      static constexpr std::string_view filter_header = "filter\n";

      static void validateOwner(std::string_view owner);

      ds::String<Memory> ownerMarker(std::string_view owner);

      template <typename Store>
      TBC_GENERIC void load(Store& store) {
        owners_.clear();
        restore_skip_ = false;
        const auto saved = store.load();
        if (!saved) {
          return;
        }

        auto content = std::string_view{*saved};
        if (!content.starts_with(skip_header) && !content.starts_with(filter_header)) {
          throw std::runtime_error{"Invalid PF loopback recovery record"};
        }

        restore_skip_ = content.starts_with(skip_header);
        content.remove_prefix(restore_skip_ ? skip_header.size() : filter_header.size());
        if (content.empty() || content.size() % owner_bytes != 0 || content.size() > maximum_owners * owner_bytes) {
          throw std::runtime_error{"Invalid PF loopback owner list"};
        }

        while (!content.empty()) {
          const auto owner = content.substr(0, owner_bytes - 1);

          validateOwner(owner);
          const auto marker = content.substr(0, owner_bytes);
          if (marker.back() != '\n' || std::string_view{owners_}.contains(marker)) {
            throw std::runtime_error{"Invalid or duplicate PF loopback owner"};
          }

          owners_.append(marker);
          content.remove_prefix(owner_bytes);
        }
      }

      template <typename Store>
      TBC_GENERIC void save(Store& store) {
        ds::String<Memory> content{memory_, restore_skip_ ? skip_header : filter_header};

        content.append(owners_);
        store.save(content);
      }

      Memory& memory_;
      ds::String<Memory> owners_;
      bool restore_skip_ = false;
    };

    extern template class LoopbackLeases<Memory>;
    extern template class LoopbackLeases<ConcurrentMemory>;

    // Generic over the caller's interface.
    template <Allocator Memory, typename Interface>
    class TBC_GENERIC SharedLoopback {
    public:
      inline explicit SharedLoopback(Memory& memory, Interface& interface, std::string_view owner) noexcept
          : memory_(memory),
            interface_(interface),
            owner_(owner) {}

      inline void acquire() {
        RecordFile file{memory_, "loopback", RecordLock::update};
        LoopbackLeases leases{memory_};

        leases.acquire(file, interface_, owner_);
      }

      inline void release() {
        RecordFile file{memory_, "loopback", RecordLock::update};
        LoopbackLeases leases{memory_};

        leases.release(file, interface_, owner_);
      }

    private:
      Memory& memory_;
      Interface& interface_;
      std::string_view owner_;
    };

  }
}

// Interface: redirect/packet_log.cppm
export {
  namespace telar::runtime::redirect {

    class PacketLog {
      // Darwin's pfloghdr.
      static constexpr std::size_t name_bytes = 16;
      static constexpr std::size_t header_bytes = 64;
      static constexpr std::size_t uid_offset = 44;
      static constexpr std::size_t direction_offset = 60;
      // The capture's snapshot, which its filter returns too: a whole 64 KiB packet behind the header.
      static constexpr unsigned snapshot_bytes = 65600;

      struct Header {
        Byte length;
        Byte family;
        Byte action;
        Byte reason;
        ds::Array<char, name_bytes> interface;
        ds::Array<char, name_bytes> ruleset;
        std::uint32_t rule;
        std::uint32_t subrule;
        uid_t uid;
        pid_t pid;
        uid_t rule_uid;
        pid_t rule_pid;
        Byte direction;
        ds::Array<Byte, 3> padding;
      };

      static_assert(sizeof(Header) == header_bytes && __builtin_offsetof(Header, uid) == uid_offset && __builtin_offsetof(Header, direction) == direction_offset);
      enum class PfDirection : Byte {
        incoming = 1,
        outgoing = 2,
      };
      enum class Action : Byte {
        pass = 0,
      };

    public:
      // A logged packet behind its 4-byte family word: a 64 KiB IP packet at most.
      static constexpr std::size_t frame_bytes = 65540;

      struct Metadata {
        pid_t pid = 0;
        FixedText<IFNAMSIZ> interface;
        unsigned interface_index = 0;
        bool incoming = false;
      };

      // Generic over the caller's store and interface.
      template <typename State>
      TBC_GENERIC explicit PacketLog(State& state, uid_t uid, Direction direction = Direction::outbound)
          : uid_(uid),
            direction_(direction),
            index_(LogInterface::create()),
            capture_(nullptr, &pcap_close) {
        try {
          state.saveLog(index_);
        } catch (...) {
          LogInterface::remove(index_);
          throw;
        }

        ds::Array<char, IFNAMSIZ> name{};

        std::format_to_n(name.dataMut(), static_cast<std::ptrdiff_t>(name.size() - 1), "pflog{}", index_);
        ds::Array<char, PCAP_ERRBUF_SIZE> error{};

        capture_.reset(pcap_create(name.dataMut(), error.dataMut()));
        if (!capture_) {
          throw std::runtime_error{error.data()};
        }

        if (pcap_set_snaplen(capture_.get(), static_cast<int>(snapshot_bytes)) != 0 || pcap_set_timeout(capture_.get(), 1) != 0 || pcap_set_immediate_mode(capture_.get(), 1) != 0 || pcap_activate(capture_.get()) < 0 || pcap_datalink(capture_.get()) != DLT_PFLOG || pcap_setnonblock(capture_.get(), 1, error.dataMut()) != 0) {
          throw std::runtime_error{"Cannot capture private PF discovery log"};
        }

        setCloseOnExec(pcap_fileno(capture_.get()));
        // Keeps the packets pf logged for this account and drops the rest.
        constexpr auto load_word = static_cast<unsigned short>(combineFlags(BPF_LD, BPF_W, BPF_ABS));
        constexpr auto jump_equal = static_cast<unsigned short>(combineFlags(BPF_JMP, BPF_JEQ, BPF_K));
        constexpr auto return_constant = static_cast<unsigned short>(combineFlags(BPF_RET, BPF_K));
        ds::Array<bpf_insn, 4> instructions{
            BPF_STMT(load_word, __builtin_offsetof(Header, uid)),
            BPF_JUMP(jump_equal, htonl(uid_), 0, 1),
            BPF_STMT(return_constant, snapshot_bytes),
            BPF_STMT(return_constant, 0),
        };

        bpf_program filter{.bf_len = static_cast<unsigned>(instructions.size()), .bf_insns = instructions.dataMut()};
        if (pcap_setfilter(capture_.get(), &filter) != 0) {
          throw std::runtime_error{pcap_geterr(capture_.get())};
        }
      }

      [[nodiscard]] unsigned index() const noexcept;

      [[nodiscard]] int descriptor() const noexcept;

      [[nodiscard]] const Metadata& metadata() const noexcept;

      std::span<Byte> receive();

      static std::size_t normalize(std::span<const Byte> packet, uid_t uid, std::span<Byte> output, Metadata* metadata = nullptr, Direction direction = Direction::outbound);

    private:
      uid_t uid_;
      Direction direction_;
      unsigned index_ = 0;
      std::unique_ptr<pcap_t, decltype(&pcap_close)> capture_;
      ds::Array<Byte, frame_bytes> bytes_{};
      Metadata metadata_;
    };

  }
}

// Interface: redirect/record.cppm
export {
  namespace telar::runtime::redirect {

    template <Allocator Memory>
    class Record {
    public:
      // What the record keeps lives in `memory`, region `a`; the endpoint and the label are copied.
      explicit Record(tbc::mut_a<Memory> memory, const PfIdentity<Memory>& identity, std::string_view endpoint);

      ds::Option<std::uint64_t> load();

      void save(std::uint64_t token);

      void saveLog(unsigned index);

      void clear();

    private:
      tbc::mut_a<Memory> memory_;
      tbc::val_a<ds::String<Memory>> endpoint_;
      tbc::val_a<RecordFile<Memory>> file_;
      ds::Option<unsigned> log_index_;
      ds::Option<std::uint64_t> last_token_;
    };

    extern template class Record<Memory>;
    extern template class Record<ConcurrentMemory>;

  }
}
