module;
#include <pcap/pcap.h>

export module telar.native.pcap;

// libpcap's header stays in this global module fragment only; importers reach it through these
// declarations instead of including it.
export {
  using ::bpf_insn;
  using ::bpf_program;
  using ::bpf_u_int32;
  using ::pcap_if_t;
  using ::pcap_pkthdr;
  using ::pcap_stat;
  using ::pcap_t;
  using ::u_char;

  using ::pcap_activate;
  using ::pcap_close;
  using ::pcap_compile;
  using ::pcap_create;
  using ::pcap_datalink;
  using ::pcap_fileno;
  using ::pcap_findalldevs;
  using ::pcap_freealldevs;
  using ::pcap_freecode;
  using ::pcap_get_selectable_fd;
  using ::pcap_geterr;
  using ::pcap_inject;
  using ::pcap_next_ex;
  using ::pcap_offline_filter;
  using ::pcap_open_dead;
  using ::pcap_open_live;
  using ::pcap_open_offline;
  using ::pcap_set_buffer_size;
  using ::pcap_set_immediate_mode;
  using ::pcap_set_promisc;
  using ::pcap_set_snaplen;
  using ::pcap_set_timeout;
  using ::pcap_setfilter;
  using ::pcap_setnonblock;
  using ::pcap_stats;
}

// Macros do not cross an import. Each constant the tree reads is captured while the header still
// defines it, undefined, and exported under its own name.
#define TELAR_PCAP_CONSTANTS(X) \
  X(BPF_ABS)                    \
  X(BPF_JEQ)                    \
  X(BPF_JMP)                    \
  X(BPF_K)                      \
  X(BPF_LD)                     \
  X(BPF_RET)                    \
  X(BPF_W)                      \
  X(DLT_EN10MB)                 \
  X(DLT_IPV4)                   \
  X(DLT_IPV6)                   \
  X(DLT_LINUX_SLL)              \
  X(DLT_LINUX_SLL2)             \
  X(DLT_LOOP)                   \
  X(DLT_NULL)                   \
  X(DLT_PFLOG)                  \
  X(DLT_RAW)                    \
  X(PCAP_ERRBUF_SIZE)           \
  X(PCAP_ERROR_BREAK)           \
  X(PCAP_IF_UP)                 \
  X(PCAP_NETMASK_UNKNOWN)

namespace telar::native::pcap::captured {

#define TELAR_PCAP_CAPTURE(name) inline constexpr auto name##_ = name;
  TELAR_PCAP_CONSTANTS(TELAR_PCAP_CAPTURE)

}

#undef BPF_ABS
#undef BPF_JEQ
#undef BPF_JMP
#undef BPF_K
#undef BPF_LD
#undef BPF_RET
#undef BPF_W
#undef DLT_EN10MB
#undef DLT_IPV4
#undef DLT_IPV6
#undef DLT_LINUX_SLL
#undef DLT_LINUX_SLL2
#undef DLT_LOOP
#undef DLT_NULL
#undef DLT_PFLOG
#undef DLT_RAW
#undef PCAP_ERRBUF_SIZE
#undef PCAP_ERROR_BREAK
#undef PCAP_IF_UP
#undef PCAP_NETMASK_UNKNOWN

#define TELAR_PCAP_CONSTANT(name) inline constexpr auto name = telar::native::pcap::captured::name##_;

export {
  TELAR_PCAP_CONSTANTS(TELAR_PCAP_CONSTANT)
}

// The filter instruction macros build a braced bpf_insn; these build the same one.
#undef BPF_JUMP
#undef BPF_STMT

export {
  constexpr bpf_insn BPF_STMT(unsigned short code, bpf_u_int32 k) noexcept {
    return bpf_insn{.code = code, .jt = 0, .jf = 0, .k = k};
  }

  constexpr bpf_insn BPF_JUMP(unsigned short code, bpf_u_int32 k, unsigned char jump_true, unsigned char jump_false) noexcept {
    return bpf_insn{.code = code, .jt = jump_true, .jf = jump_false, .k = k};
  }
}
