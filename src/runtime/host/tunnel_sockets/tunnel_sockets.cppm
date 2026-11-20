export module telar.runtime.host.tunnel_sockets;

import std;

// Interface: platform/tunnel_sockets.cppm
export {
  namespace telar::runtime {

    struct TunnelSockets {
      int child;
      int origin;
    };

    // The sockets a tunnel relays between and the host the child asked for, which the tunnel copies.
    struct TunnelRoute {
      TunnelSockets sockets;
      std::string_view hostname;
    };

  }
}
