module;
#include <netinet/in.h>
#include <sys/socket.h>

module telar.sys.socket;

// The parentheses keep each name from expanding as the macro the body calls.
unsigned char*(CMSG_DATA)(cmsghdr * header) noexcept {
  return CMSG_DATA(header); // NOLINT(clang-diagnostic-unsafe-buffer-usage): the system macro offsets the header pointer
}

cmsghdr*(CMSG_FIRSTHDR)(msghdr * message) noexcept {
  return CMSG_FIRSTHDR(message);
}

// musl's macro compares a length with a pointer difference.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"

cmsghdr*(CMSG_NXTHDR)(msghdr * message, cmsghdr* header) noexcept {
  return CMSG_NXTHDR(message, header); // NOLINT(clang-diagnostic-unsafe-buffer-usage): the system macro offsets the header pointer
}

#pragma clang diagnostic pop

bool(IN6_IS_ADDR_LINKLOCAL)(const in6_addr* address) noexcept {
  return IN6_IS_ADDR_LINKLOCAL(address);
}

bool(IN6_IS_ADDR_MULTICAST)(const in6_addr* address) noexcept {
  return IN6_IS_ADDR_MULTICAST(address);
}

bool(IN6_IS_ADDR_UNSPECIFIED)(const in6_addr* address) noexcept {
  return IN6_IS_ADDR_UNSPECIFIED(address);
}

bool(IN6_IS_ADDR_V4MAPPED)(const in6_addr* address) noexcept {
  return IN6_IS_ADDR_V4MAPPED(address);
}
