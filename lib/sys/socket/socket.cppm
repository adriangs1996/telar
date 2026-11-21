module;
#include "tbc/annotations.hpp"
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>

export module telar.sys.socket;

// The C headers stay in this global module fragment only; importers reach their
// declarations through these using-declarations instead of including them.
export {
  // Addresses.
  using ::in6_addr;
  using ::in_addr;
  using ::in_port_t;
  using ::sa_family_t;
  using ::sockaddr;
  using ::sockaddr_in;
  using ::sockaddr_in6;
  using ::sockaddr_storage;
  using ::sockaddr_un;
  using ::socklen_t;

  // Sockets.
  using ::accept;
  using ::bind;
  using ::cmsghdr;
  using ::connect;
  using ::getpeername;
  using ::getsockname;
  using ::getsockopt;
  using ::listen;
  using ::msghdr;
  using ::recv;
  using ::recvmsg;
  using ::send;
  using ::sendmsg;
  using ::setsockopt;
  using ::shutdown;
  using ::socket;
  using ::socketpair;
  // The timeout SO_RCVTIMEO and SO_SNDTIMEO take.
  using ::timeval;

  // Text forms, name resolution and network interfaces.
  using ::addrinfo;
  using ::freeaddrinfo;
  using ::freeifaddrs;
  using ::gai_strerror;
  using ::getaddrinfo;
  using ::getifaddrs;
  using ::getnameinfo;
  using ::if_indextoname;
  using ::if_nametoindex;
  using ::ifaddrs;
  using ::ifreq;
  using ::in6addr_loopback;
  using ::inet_ntop;
  using ::inet_pton;
}

// Macros do not cross an import. Each one the tree reads is captured while the headers still
// define it, undefined, and exported under its own name, so `AF_INET` reads the same to an
// importer that includes the header and to one that only imports this module.
// NOLINTNEXTLINE(cppcoreguidelines-macro-usage): an X-macro lists the C macros to capture, which no template can name
#define TELAR_SYS_SOCKET_OPTIONS(X) \
  X(AF_INET)                        \
  X(AF_INET6)                       \
  X(AF_UNIX)                        \
  X(AF_UNSPEC)                      \
  X(PF_ROUTE)                       \
  X(SOL_SOCKET)                     \
  X(SO_ERROR)                       \
  X(SO_KEEPALIVE)                   \
  X(SO_RCVBUF)                      \
  X(SO_RCVTIMEO)                    \
  X(SO_REUSEADDR)                   \
  X(SO_SNDBUF)                      \
  X(SO_SNDTIMEO)                    \
  X(SO_TYPE)

// Internet addresses, TCP options, name resolution and interfaces.
// NOLINTNEXTLINE(cppcoreguidelines-macro-usage): an X-macro lists the C macros to capture, which no template can name
#define TELAR_SYS_ADDRESSES(X) \
  X(AI_PASSIVE)                \
  X(EAI_MEMORY)                \
  X(EAI_SYSTEM)                \
  X(IFNAMSIZ)                  \
  X(INADDR_ANY)                \
  X(INADDR_BROADCAST)          \
  X(INADDR_LOOPBACK)           \
  X(INET6_ADDRSTRLEN)          \
  X(IF_NAMESIZE)               \
  X(IPV6_V6ONLY)               \
  X(NI_MAXHOST)                \
  X(NI_MAXSERV)                \
  X(NI_NUMERICHOST)            \
  X(NI_NUMERICSERV)            \
  X(SIOCGIFFLAGS)              \
  X(SIOCSIFFLAGS)              \
  X(TCP_KEEPCNT)               \
  X(TCP_KEEPINTVL)             \
  X(TCP_NODELAY)

// glibc declares these as enumerators and defines each macro as its own name.
// NOLINTNEXTLINE(cppcoreguidelines-macro-usage): an X-macro lists the C macros to capture, which no template can name
#define TELAR_SYS_ENUMERATORS(X) \
  X(IFF_LOOPBACK)                \
  X(IFF_UP)                      \
  X(IPPROTO_AH)                  \
  X(IPPROTO_DSTOPTS)             \
  X(IPPROTO_HOPOPTS)             \
  X(IPPROTO_ICMP)                \
  X(IPPROTO_ICMPV6)              \
  X(IPPROTO_IPV6)                \
  X(IPPROTO_ROUTING)             \
  X(IPPROTO_TCP)                 \
  X(IPPROTO_UDP)                 \
  X(MSG_CTRUNC)                  \
  X(MSG_DONTWAIT)                \
  X(MSG_PEEK)                    \
  X(SCM_RIGHTS)                  \
  X(SHUT_RDWR)                   \
  X(SHUT_WR)                     \
  X(SOCK_DGRAM)                  \
  X(SOCK_RAW)                    \
  X(SOCK_STREAM)

namespace telar::sys::captured {

#define TELAR_SYS_CAPTURE(name) inline constexpr auto name##_ = name;
  TELAR_SYS_SOCKET_OPTIONS(TELAR_SYS_CAPTURE)
  TELAR_SYS_ADDRESSES(TELAR_SYS_CAPTURE)
#ifndef __GLIBC__
  TELAR_SYS_ENUMERATORS(TELAR_SYS_CAPTURE)
#endif

  // The option that sets how long a connection idles before its first keepalive probe, which
  // Darwin and Linux name differently.
#ifdef __APPLE__
  inline constexpr int keepalive_idle_ = TCP_KEEPALIVE;
#else
  inline constexpr int keepalive_idle_ = TCP_KEEPIDLE;
#endif

  // Control messages; the sizes bound buffers, so they stay constant expressions.
  inline constexpr size_t controlLength(size_t length) noexcept {
    return CMSG_LEN(length);
  }

  inline constexpr size_t controlSpace(size_t length) noexcept {
    return CMSG_SPACE(length);
  }

  // Address classes.
  inline constexpr bool isMulticast(in_addr_t address) noexcept {
    return IN_MULTICAST(address);
  }

}

#undef AF_INET
#undef AF_INET6
#undef AF_UNIX
#undef AF_UNSPEC
#undef PF_ROUTE
#undef SOL_SOCKET
#undef SO_ERROR
#undef SO_KEEPALIVE
#undef SO_RCVBUF
#undef SO_RCVTIMEO
#undef SO_REUSEADDR
#undef SO_SNDBUF
#undef SO_SNDTIMEO
#undef SO_TYPE
#undef AI_PASSIVE
#undef EAI_MEMORY
#undef EAI_SYSTEM
#undef IFNAMSIZ
#undef INADDR_ANY
#undef INADDR_BROADCAST
#undef INADDR_LOOPBACK
#undef INET6_ADDRSTRLEN
#undef IF_NAMESIZE
#undef IPV6_V6ONLY
#undef NI_MAXHOST
#undef NI_MAXSERV
#undef NI_NUMERICHOST
#undef NI_NUMERICSERV
#undef SIOCGIFFLAGS
#undef SIOCSIFFLAGS
#undef TCP_KEEPCNT
#undef TCP_KEEPINTVL
#undef TCP_NODELAY
#undef IFF_LOOPBACK
#undef IFF_UP
#undef IPPROTO_AH
#undef IPPROTO_DSTOPTS
#undef IPPROTO_HOPOPTS
#undef IPPROTO_ICMP
#undef IPPROTO_ICMPV6
#undef IPPROTO_IPV6
#undef IPPROTO_ROUTING
#undef IPPROTO_TCP
#undef IPPROTO_UDP
#undef MSG_CTRUNC
#undef MSG_DONTWAIT
#undef MSG_PEEK
#undef SCM_RIGHTS
#undef SHUT_RDWR
#undef SHUT_WR
#undef SOCK_DGRAM
#undef SOCK_RAW
#undef SOCK_STREAM
#undef CMSG_LEN
#undef CMSG_SPACE
#undef CMSG_DATA
#undef CMSG_FIRSTHDR
#undef CMSG_NXTHDR
#undef IN_MULTICAST
#undef IN6_IS_ADDR_LINKLOCAL
#undef IN6_IS_ADDR_MULTICAST
#undef IN6_IS_ADDR_UNSPECIFIED
#undef IN6_IS_ADDR_V4MAPPED
#undef htonl
#undef htons
#undef ntohl
#undef ntohs

#define TELAR_SYS_CONSTANT(name) inline constexpr auto name = telar::sys::captured::name##_;
#ifdef __GLIBC__
#define TELAR_SYS_ENUMERATOR(name) using ::name;
#else
#define TELAR_SYS_ENUMERATOR TELAR_SYS_CONSTANT
#endif

export {
  TELAR_SYS_SOCKET_OPTIONS(TELAR_SYS_CONSTANT) // NOLINT(readability-identifier-naming): exported under the system's own names
  TELAR_SYS_ADDRESSES(TELAR_SYS_CONSTANT)      // NOLINT(readability-identifier-naming): exported under the system's own names
  TELAR_SYS_ENUMERATORS(TELAR_SYS_ENUMERATOR)  // NOLINT(readability-identifier-naming): exported under the system's own names

  // NOLINTNEXTLINE(readability-identifier-naming): exported under the system's own name
  inline constexpr size_t CMSG_LEN(size_t length) noexcept {
    return telar::sys::captured::controlLength(length);
  }

  // NOLINTNEXTLINE(readability-identifier-naming): exported under the system's own name
  inline constexpr size_t CMSG_SPACE(size_t length) noexcept {
    return telar::sys::captured::controlSpace(length);
  }

  // The pointer arithmetic the macros do is no constant expression, and Darwin's and an optimizing
  // glibc's address classes call a static byte swap that an inline body would expose to importers,
  // so these are defined in socket.cpp, where the macros are.
  unsigned char* CMSG_DATA(cmsghdr* header) noexcept; // NOLINT(readability-identifier-naming): exported under the system's own names
  // The control headers are handed out by address, as Rust's libc::CMSG_FIRSTHDR and CMSG_NXTHDR
  // return raw pointers: the caller answers for the control buffer outliving the walk.
  TBC_RAW cmsghdr* CMSG_FIRSTHDR(msghdr* message) noexcept;                // NOLINT(readability-identifier-naming): exported under the system's own names
  TBC_RAW cmsghdr* CMSG_NXTHDR(msghdr* message, cmsghdr* header) noexcept; // NOLINT(readability-identifier-naming): exported under the system's own names

  // NOLINTNEXTLINE(readability-identifier-naming): exported under the system's own name
  inline constexpr bool IN_MULTICAST(in_addr_t address) noexcept {
    return telar::sys::captured::isMulticast(address);
  }

  bool IN6_IS_ADDR_LINKLOCAL(const in6_addr* address) noexcept;   // NOLINT(readability-identifier-naming): exported under the system's own names
  bool IN6_IS_ADDR_MULTICAST(const in6_addr* address) noexcept;   // NOLINT(readability-identifier-naming): exported under the system's own names
  bool IN6_IS_ADDR_UNSPECIFIED(const in6_addr* address) noexcept; // NOLINT(readability-identifier-naming): exported under the system's own names
  bool IN6_IS_ADDR_V4MAPPED(const in6_addr* address) noexcept;    // NOLINT(readability-identifier-naming): exported under the system's own names

#ifdef __APPLE__
  // Darwin defines the byte-order conversions only as macros, over static functions an inline
  // body cannot expose; every Darwin target is little-endian, so each is a byte swap.
  static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__);

  inline constexpr uint32_t htonl(uint32_t value) noexcept {
    return __builtin_bswap32(value);
  }

  inline constexpr uint16_t htons(uint16_t value) noexcept {
    return __builtin_bswap16(value);
  }

  inline constexpr uint32_t ntohl(uint32_t value) noexcept {
    return __builtin_bswap32(value);
  }

  inline constexpr uint16_t ntohs(uint16_t value) noexcept {
    return __builtin_bswap16(value);
  }
#else
  // glibc and musl declare functions.
  using ::htonl;
  using ::htons;
  using ::ntohl;
  using ::ntohs;
#endif
}

// Members that the headers reach through a macro have no name an importer can spell.
export namespace telar::sys {

  // The TCP option for the idle time before the first keepalive probe: TCP_KEEPALIVE on Darwin,
  // TCP_KEEPIDLE on Linux.
  inline constexpr int tcp_keepalive_idle = captured::keepalive_idle_;

  // The interface name an ifreq carries.
  inline constexpr auto& interfaceName(ifreq& request) noexcept {
    return request.ifr_name;
  }

  // The interface flags an ifreq carries.
  inline constexpr auto& interfaceFlags(ifreq& request) noexcept {
    return request.ifr_flags;
  }

  // The sixteen bytes of an IPv6 address.
  inline constexpr auto& addressBytes(in6_addr& address) noexcept {
    return address.s6_addr;
  }

}
