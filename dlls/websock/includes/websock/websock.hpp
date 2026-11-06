#ifndef TELAR_WEBSOCK_HPP
#define TELAR_WEBSOCK_HPP

namespace telar::websock {

  template <typename IAllocator>
  class Server final {

    IAllocator &allocator_;

  public:
    Server(IAllocator &allocator)
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
