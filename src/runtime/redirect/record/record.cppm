module;
#include "tbc/annotations.hpp"

export module telar.runtime.redirect.record;

import std;
import telar.native.pcap;
import telar.sys.socket;
import telar.sys.posix;

export import telar.runtime.redirect.pf_rules;
import telar.base.diagnostics;
import telar.base.memory.containers;
import telar.base.text;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.platform.process;
import telar.vocabulary;
import telar.base.memory.allocators;

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
      // Darwin's pfioc_iface layout is absent from the public SDK. Keep this ABI
      // limited to DIOCSETIFFLAG/DIOCCLRIFFLAG and the PFI_IFLAG_SKIP bit on lo0.
      // https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/pfvar.h
      struct InterfaceRequest {
        char name[IFNAMSIZ]{};
        alignas(8) void* buffer = nullptr;
        alignas(8) int element_size = 0;
        int size = 0;
        int zero = 0;
        int flags = 0;
      };

      static_assert(sizeof(InterfaceRequest) == 40 && __builtin_offsetof(InterfaceRequest, flags) == 36);
      enum class Operation : unsigned long {
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
        constexpr std::array<std::string_view, 5> arguments{"-v", "-s", "Interfaces", "-i", "lo0"};

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

    enum class RecordLock {
      owner,
      update,
    };

    template <Allocator Memory>
    class RecordFile {
    public:
      explicit RecordFile(Memory& memory, std::string_view name, RecordLock mode = RecordLock::owner);

      std::optional<String<Memory>> load();

      void save(std::string_view content);

      void clear();

    private:
      static void validate(int descriptor);

      Memory& memory_;
      String<Memory> name_;
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
        const auto position = owners_.find(marker);
        if (position == String<Memory>::npos) {
          return;
        }

        owners_.erase(position, marker.size());
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

      static void validateOwner(std::string_view owner);

      String<Memory> ownerMarker(std::string_view owner);

      template <typename Store>
      TBC_GENERIC void load(Store& store) {
        owners_.clear();
        restore_skip_ = false;
        const auto saved = store.load();
        if (!saved) {
          return;
        }

        auto content = std::string_view{*saved};
        if (!content.starts_with("skip\n") && !content.starts_with("filter\n")) {
          throw std::runtime_error{"Invalid PF loopback recovery record"};
        }

        restore_skip_ = content.starts_with("skip\n");
        content.remove_prefix(restore_skip_ ? 5 : 7);
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
        String<Memory> content{restore_skip_ ? "skip\n" : "filter\n", AllocatorRef<char, Memory>{memory_}};

        content.append(owners_);
        store.save(content);
      }

      Memory& memory_;
      String<Memory> owners_;
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
      struct Header {
        Byte length;
        Byte family;
        Byte action;
        Byte reason;
        std::array<char, 16> interface;
        std::array<char, 16> ruleset;
        std::uint32_t rule;
        std::uint32_t subrule;
        uid_t uid;
        pid_t pid;
        uid_t rule_uid;
        pid_t rule_pid;
        Byte direction;
        std::array<Byte, 3> padding;
      };

      static_assert(sizeof(Header) == 64 && __builtin_offsetof(Header, uid) == 44 && __builtin_offsetof(Header, direction) == 60);
      enum class PfDirection : Byte {
        incoming = 1,
        outgoing = 2,
      };
      enum class Action : Byte {
        pass = 0,
      };

    public:
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
            capture_(nullptr, &pcap_close) {
        index_ = LogInterface::create();
        try {
          state.saveLog(index_);
        } catch (...) {
          LogInterface::remove(index_);
          throw;
        }

        std::array<char, 16> name{};

        std::snprintf(name.data(), name.size(), "pflog%u", index_);
        std::array<char, PCAP_ERRBUF_SIZE> error{};

        capture_.reset(pcap_create(name.data(), error.data()));
        if (!capture_) {
          throw std::runtime_error{error.data()};
        }

        if (pcap_set_snaplen(capture_.get(), 65600) != 0 || pcap_set_timeout(capture_.get(), 1) != 0 || pcap_set_immediate_mode(capture_.get(), 1) != 0 || pcap_activate(capture_.get()) < 0 || pcap_datalink(capture_.get()) != DLT_PFLOG || pcap_setnonblock(capture_.get(), 1, error.data()) != 0) {
          throw std::runtime_error{"Cannot capture private PF discovery log"};
        }

        setCloseOnExec(pcap_fileno(capture_.get()));
        bpf_insn instructions[] = {
            BPF_STMT(BPF_LD | BPF_W | BPF_ABS, __builtin_offsetof(Header, uid)),
            BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, htonl(uid_), 0, 1),
            BPF_STMT(BPF_RET | BPF_K, 65600),
            BPF_STMT(BPF_RET | BPF_K, 0),
        };

        bpf_program filter{.bf_len = std::size(instructions), .bf_insns = instructions};
        if (pcap_setfilter(capture_.get(), &filter) != 0) {
          throw std::runtime_error{pcap_geterr(capture_.get())};
        }
      }

      unsigned index() const noexcept;

      int descriptor() const noexcept;

      const Metadata& metadata() const noexcept;

      std::span<Byte> receive();

      static std::size_t normalize(std::span<const Byte> packet, uid_t uid, std::span<Byte> output, Metadata* metadata = nullptr, Direction direction = Direction::outbound);

    private:
      uid_t uid_;
      Direction direction_;
      unsigned index_ = 0;
      std::unique_ptr<pcap_t, decltype(&pcap_close)> capture_;
      std::array<Byte, 65540> bytes_{};
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
      explicit Record(Memory& memory, const PfIdentity<Memory>& identity, std::string_view endpoint);

      std::optional<std::uint64_t> load();

      void save(std::uint64_t token);

      void saveLog(unsigned index);

      void clear();

    private:
      Memory& memory_;
      String<Memory> endpoint_;
      RecordFile<Memory> file_;
      std::optional<unsigned> log_index_;
      std::optional<std::uint64_t> last_token_;
    };

    extern template class Record<Memory>;
    extern template class Record<ConcurrentMemory>;

  }
}
