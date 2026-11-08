module;
#include <cstdlib>
#include <stdlib.h>
#include <new>
#include <cstdio>

#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <cerrno>
#include <cstdint>
#include <sys/stat.h>
#include <sys/un.h>
#include <cassert>
#include <cstddef>
#include <cstring>
#include <csignal>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pcap/pcap.h>
#include <arpa/inet.h>
#include <limits.h>
#include <poll.h>

export module telar.runtime.traffic.tap;

import std;

export import telar.runtime.traffic.control_backend;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: traffic/tap.cppm
export {
namespace telar::runtime::traffic {

template <ConcurrentAllocator Memory, typename Plugins>
class Tap {
public:
  inline explicit Tap(Plugins &plugins, Service<Memory> *traffic) noexcept : plugins_(plugins), traffic_(traffic) {}

  inline FlowControl *flowControl() noexcept { return traffic_; }

  inline bool listening() const noexcept { return plugins_.listening() || (traffic_ && traffic_->listening()); }

  inline void submit(CapturedExchange<Memory> &exchange) noexcept {
    if (traffic_) {
      traffic_->submit(exchange);
    }
    plugins_.submit(exchange);
  }

private:
  Plugins &plugins_;
  Service<Memory> *traffic_;
};

}
}
