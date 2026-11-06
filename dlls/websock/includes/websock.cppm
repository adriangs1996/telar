module;

#if (!defined(TELAR_WEBSOCK_HPP))
#include "telar_base/memory/allocator.hpp"
#endif

export module telar.websock;


// Interface: includes/websock/websock.cppm
export {
#ifndef TELAR_WEBSOCK_HPP
#define TELAR_WEBSOCK_HPP

namespace telar::websock {

  template <Allocator IAllocator>
  class Server final {

    IAllocator &allocator_;

  public:
    inline Server(IAllocator &allocator)
        : allocator_(allocator) {};

    ~Server();

    // Ignore this for now;
    Server(const Server &) = delete;
    Server(Server &&) = delete;
    Server &operator=(Server &&) = delete;
    Server &operator=(const Server &) = delete;
  };
}

#endif
}
