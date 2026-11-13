module;
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
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

  // Text forms, name resolution and network interfaces.
  using ::addrinfo;
  using ::freeaddrinfo;
  using ::freeifaddrs;
  using ::getaddrinfo;
  using ::getifaddrs;
  using ::getnameinfo;
  using ::if_indextoname;
  using ::if_nametoindex;
  using ::ifaddrs;
  using ::inet_ntop;
  using ::inet_pton;
}
