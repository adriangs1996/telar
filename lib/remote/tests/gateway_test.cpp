#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <arpa/inet.h>
#include <cerrno>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

import std;
import telar.base.ds;
import telar.platform.fs;
import telar.platform.primitives;
import telar.remote.channel;
import telar.remote.identity;
import telar.remote.link;
import telar.remote.serve;
import telar.remote.streams;
import telar.remote.tests.fixture;
import telar.testing;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::remote;
  using runtime::FileDescriptor;

  // Writes all of `text` to a descriptor that may not block.
  void writeAll(int descriptor, std::string_view text) {
    while (!text.empty()) {
      const auto written = ::write(descriptor, text.data(), text.size());
      if (written > 0) {
        text.remove_prefix(static_cast<std::size_t>(written));
        continue;
      }

      check(errno == EAGAIN || errno == EINTR, "the peer must still read");
      pollfd entry{.fd = descriptor, .events = POLLOUT, .revents = 0};

      ::poll(&entry, 1, 1000);
    }
  }

  // Reads what a descriptor has, up to `count` bytes, waiting for the first of them; nothing
  // when it ended or five seconds passed.
  std::string readSome(int descriptor, std::size_t count) {
    std::string text;
    char buffer[4096];

    while (text.empty()) {
      pollfd entry{.fd = descriptor, .events = POLLIN, .revents = 0};
      if (::poll(&entry, 1, 5000) <= 0) {
        break;
      }

      const auto taken = ::read(descriptor, buffer, std::min(sizeof(buffer), count - text.size()));
      if (taken == 0 || (taken < 0 && errno != EAGAIN && errno != EINTR)) {
        break;
      }

      if (taken > 0) {
        text.append(buffer, static_cast<std::size_t>(taken));
      }
    }

    return text;
  }

  // Reads until `count` bytes came or the descriptor ended.
  std::string readExactly(int descriptor, std::size_t count) {
    std::string text;

    while (text.size() < count) {
      const auto more = readSome(descriptor, count - text.size());
      if (more.empty()) {
        break;
      }

      text += more;
    }

    return text;
  }

  std::string readAll(int descriptor) {
    return readExactly(descriptor, std::numeric_limits<std::size_t>::max());
  }

  // Answers every connection to `listener` with the bytes it sends, until told to stop.
  class EchoServer {
  public:
    explicit EchoServer(FileDescriptor listener)
        : listener_(std::move(listener)),
          thread_([this] {
            serve();
          }) {}

    ~EchoServer() {
      stop();
    }

    void stop() {
      stopping_ = true;
      if (thread_.joinable()) {
        thread_.join();
      }

      listener_.reset();
    }

  private:
    void serve() {
      std::vector<std::thread> connections;

      while (!stopping_) {
        pollfd entry{.fd = listener_.get(), .events = POLLIN, .revents = 0};
        if (::poll(&entry, 1, 20) <= 0) {
          continue;
        }

        const int connection = ::accept(listener_.get(), nullptr, nullptr);
        if (connection < 0) {
          continue;
        }

        connections.emplace_back([connection] {
          // A connection accepted from a nonblocking listener may not block either, so each read waits.
          for (auto text = readSome(connection, 4096); !text.empty(); text = readSome(connection, 4096)) {
            writeAll(connection, text);
          }

          ::close(connection);
        });
      }

      for (auto& connection : connections) {
        connection.join();
      }
    }

    FileDescriptor listener_;
    std::atomic<bool> stopping_{false};
    std::thread thread_;
  };

  FileDescriptor connectLocalPort(std::uint16_t port) {
    sockaddr_in address{};
    FileDescriptor socket{::socket(AF_INET, SOCK_STREAM, 0)};

    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (::connect(socket.get(), reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0) {
      socket.reset();
    }

    return socket;
  }

  // A gateway serving one account, with a stand-in for its runtime that echoes, and a client
  // account already paired with it.
  struct Pair {
    Pair()
        : runtime_path(std::string{server.directory.path()} + "/runtime.sock"),
          runtime(listenUnix(runtime_path)),
          gateway(tests::tlsMemory(), server.state, {.host = "127.0.0.1", .port = 0, .runtime_socket = runtime_path}),
          serving([this] {
            gateway.run();
          }) {
      Endpoint endpoint;

      endpoint.host.assign("127.0.0.1");
      endpoint.port = gateway.port();
      endpoint.key = gateway.key();
      unpaired = std::string{endpoint.destination().view()};
      endpoint.secret = PairingCodes::mint(server.state.directory());
      destination = std::string{enroll(client.state, {.address = endpoint.format().view(), .name = "test client"}).view()};
    }

    ~Pair() {
      gateway.stop();
      serving.join();
    }

    // Runs a command there with `input` on its standard input, and collects what it wrote.
    struct Result {
      int status = 0;
      std::string output;
      std::string error;
    };

    Result run(const State& state, std::string_view target, std::string_view command, std::string_view input = {}, const LinkPaths* link = nullptr) const {
      int in[2];
      int out[2];
      int err[2];

      check(::pipe(in) == 0 && ::pipe(out) == 0 && ::pipe(err) == 0);
      Result result;
      // The command reads its input while it is written: more than a pipe holds must not wait
      // for a reader that has not started.
      std::thread writer{[&] {
        writeAll(in[1], input);
        ::close(in[1]);
      }};
      std::thread output{[&] {
        result.output = readAll(out[0]);
      }};
      std::thread error{[&] {
        result.error = readAll(err[0]);
      }};

      result.status = runRemote(state, {.destination = target, .command = command, .streams = {.input = in[0], .output = out[1], .error = err[1]}, .link = link});
      ::close(out[1]);
      ::close(err[1]);
      writer.join();
      output.join();
      error.join();
      for (const int descriptor : {in[0], out[0], err[0]}) {
        ::close(descriptor);
      }

      return result;
    }

    tests::Gateway server;
    tests::Gateway client;
    std::string runtime_path;
    EchoServer runtime;
    Server gateway;
    std::thread serving;
    std::string unpaired;
    std::string destination;
  };

  // The link of the client account, serving in a directory of its own.
  struct LocalLink {
    explicit LocalLink(const Pair& pair)
        : link(pair.client.state, paths()),
          serving([this] {
            link.run();
          }) {}

    ~LocalLink() {
      link.stop();
      serving.join();
    }

    [[nodiscard]] LinkPaths paths() const {
      LinkPaths result;

      result.directory.assign(directory.path());
      return result;
    }

    runtime::TemporaryDirectory directory{"/tmp/telar-link-test.XXXXXX"};
    Link link;
    std::thread serving;
  };

  void commandsRunWithTheirStreamsAndStatus() {
    const Pair pair;
    const auto result = pair.run(pair.client.state, pair.destination, "cat; echo done >&2; exit 7", "ping");

    check(result.output == "ping", "the command reads what the client sends until its end");
    check(result.error == "done\n");
    check(result.status == 7);
  }

  void commandsCarryMoreThanTheirBuffers() {
    const Pair pair;
    const std::string input(600 * 1024, 'x');
    const auto result = pair.run(pair.client.state, pair.destination, "wc -c | tr -d ' '; head -c 300000 /dev/zero | tr '\\0' y", input);

    check(result.status == 0);
    check(result.output.starts_with("614400\n"), "every byte sent reaches the command");
    check(result.output.size() == std::string_view{"614400\n"}.size() + 300000, "every byte it writes comes back");
  }

  void onlyPairedClientsAreServed() {
    const Pair pair;
    const tests::Gateway stranger;
    const auto refused = pair.run(stranger.state, pair.destination, "echo no");

    check(refused.status == connection_lost_status && refused.output.empty());
    check(refused.error.contains("not paired"), "a client the gateway does not admit is told why");

    AuthorizedClients clients = AuthorizedClients::load(pair.server.state.directory());

    check(clients.rows().size() == 1 && clients.rows()[0].name.view() == "test-client");
    check(clients.revoke("test-client") == 1);
    clients.save(pair.server.state.directory());
    check(pair.run(pair.client.state, pair.destination, "echo no").status == connection_lost_status, "a revoked client is refused at once");
  }

  // A client revoked while a command of its runs there is cut then, not once it ends.
  void aClientRevokedWhileServedIsCut() {
    const Pair pair;
    const auto started = std::chrono::steady_clock::now();
    Pair::Result result;
    std::thread running{[&] {
      result = pair.run(pair.client.state, pair.destination, "echo started; sleep 30");
    }};

    std::this_thread::sleep_for(std::chrono::seconds{1});
    {
      const StateLock lock{pair.server.state.directory()};
      auto clients = AuthorizedClients::load(pair.server.state.directory());

      check(clients.revoke("test-client") == 1);
      clients.save(pair.server.state.directory());
    }

    running.join();
    check(result.output == "started\n" && result.status != 0, "the command ran until the revocation");
    check(std::chrono::steady_clock::now() - started < std::chrono::seconds{15}, "the revoked client was cut");
  }

  void clientsRefuseAGatewayWithAnotherKey() {
    const Pair pair;
    auto endpoint = Endpoint::parse(pair.destination);

    endpoint.key.atMut(0) ^= 1U;
    const auto result = pair.run(pair.client.state, endpoint.destination().view(), "echo no");

    check(result.status == connection_lost_status && result.output.empty());
    check(result.error.contains("another key"));
  }

  void pairingCodesEnrollOnce() {
    const Pair pair;
    const tests::Gateway second;
    auto endpoint = Endpoint::parse(pair.unpaired);
    bool refused = false;

    endpoint.secret = PairingCodes::mint(pair.server.state.directory());
    check(enroll(second.state, {.address = endpoint.format().view(), .name = "second"}).view() == pair.unpaired);
    check(pair.run(second.state, pair.unpaired, "echo yes").output == "yes\n");

    const tests::Gateway third;

    try {
      static_cast<void>(enroll(third.state, {.address = endpoint.format().view(), .name = "third"}));
    } catch (const ChannelFailure&) {
      refused = true;
    }

    check(refused, "a code that enrolled a client enrolls no other");
  }

  // Connections that never start their handshake hold a few of the places of the address they
  // come from, not every place: the next one from that address is closed at once.
  void oneAddressHoldsAFewHandshakes() {
    const Pair pair;
    std::vector<FileDescriptor> idle;

    for (unsigned index = 0; index < Server::maximum_handshakes_per_source; ++index) {
      idle.push_back(connectLocalPort(pair.gateway.port()));
      check(static_cast<bool>(idle.back()));
    }

    const auto refused = connectLocalPort(pair.gateway.port());
    pollfd entry{.fd = refused.get(), .events = POLLIN, .revents = 0};
    char byte = 0;

    check(static_cast<bool>(refused));
    check(::poll(&entry, 1, 3000) == 1 && ::read(refused.get(), &byte, 1) <= 0, "a connection past its address's places is closed, not left to its handshake");
  }

  // A gateway that admits as many clients as it keeps refuses a new one without spending its
  // code: the same code pairs it once a client is revoked.
  void aFullClientListLeavesThePairingCodePending() {
    const Pair pair;
    auto clients = AuthorizedClients::load(pair.server.state.directory());

    for (std::size_t index = clients.rows().size(); index < AuthorizedClients::maximum; ++index) {
      PublicKey key{};

      key.atMut(0) = static_cast<std::uint8_t>(index);
      key.atMut(1) = 0xa5;
      clients.admit(key, std::format("filler-{}", index));
    }

    clients.save(pair.server.state.directory());
    const tests::Gateway newcomer;
    auto endpoint = Endpoint::parse(pair.unpaired);
    std::string refusal;

    endpoint.secret = PairingCodes::mint(pair.server.state.directory());
    try {
      static_cast<void>(enroll(newcomer.state, {.address = endpoint.format().view(), .name = "newcomer"}));
    } catch (const ChannelFailure& failure) {
      refusal = failure.what();
    }

    check(refusal.contains("as many clients"), "a full list is told apart from a wrong code");
    check(clients.revoke("filler-1") == 1);
    clients.save(pair.server.state.directory());
    check(enroll(newcomer.state, {.address = endpoint.format().view(), .name = "newcomer"}).view() == pair.unpaired, "the code was left pending");
  }

  void theLinkOffersAMachinesRuntimeOnALocalSocket() {
    const Pair pair;
    const LocalLink local{pair};

    check(LinkClient::running(local.paths()));
    const auto path = LinkClient::socket(local.paths(), pair.destination);

    check(path.view() == LinkClient::socket(local.paths(), pair.destination).view(), "a machine keeps one socket");
    const auto socket = connectUnix(path.view());

    check(static_cast<bool>(socket));
    writeAll(socket.get(), "hello runtime");
    check(readExactly(socket.get(), 13) == "hello runtime");

    const std::string large(300 * 1024, 'z');
    std::thread writer{[&] {
      writeAll(socket.get(), large);
    }};

    check(readExactly(socket.get(), large.size()) == large, "the socket carries more than a buffer each way");
    writer.join();
  }

  // A link that serves as many machines as it keeps gives the slot of one nothing uses to the
  // next machine, and removes the socket of the one it let go.
  void theLinkReusesTheSlotOfAMachineNothingUses() {
    const Pair pair;
    const LocalLink local{pair};
    auto endpoint = Endpoint::parse(pair.destination);
    std::vector<std::string> sockets;

    for (std::size_t index = 0; index <= Link::maximum_machines; ++index) {
      endpoint.port = static_cast<std::uint16_t>(20000 + index);
      sockets.emplace_back(LinkClient::socket(local.paths(), endpoint.destination().view()).view());
    }

    check(::access(sockets.front().c_str(), F_OK) != 0, "the socket of the machine whose slot was taken is gone");
    check(::access(sockets.back().c_str(), F_OK) == 0, "the next machine has a socket");
  }

  // Any program here may connect to a forwarded port, and each connection is one to the
  // gateway: a forward carries a few at once, and closes the next.
  void aForwardCarriesAFewConnectionsAtOnce() {
    const Pair pair;
    const LocalLink local{pair};
    auto listener = listenTcp("127.0.0.1", 0);
    const auto port = listener.port;
    EchoServer echo{std::move(listener.socket)};
    int reply[2];

    check(::pipe(reply) == 0);
    std::thread holder{[&] {
      static_cast<void>(LinkClient::forward(local.paths(), pair.destination, port, "test origin", reply[1]));
    }};
    const auto local_port = static_cast<std::uint16_t>(std::stoul(readSome(reply[0], 16)));

    {
      std::vector<FileDescriptor> carried;

      for (unsigned index = 0; index < Link::maximum_forward_connections; ++index) {
        carried.push_back(connectLocalPort(local_port));
        writeAll(carried.back().get(), "x");
        check(readExactly(carried.back().get(), 1) == "x", "a connection within the bound is carried");
      }

      const auto refused = connectLocalPort(local_port);
      pollfd entry{.fd = refused.get(), .events = POLLIN, .revents = 0};
      char byte = 0;

      check(::poll(&entry, 1, 3000) == 1 && ::read(refused.get(), &byte, 1) <= 0, "the connection past the bound is closed");
    }

    echo.stop();
    holder.join();
    for (const int descriptor : reply) {
      ::close(descriptor);
    }
  }

  void theLinkForwardsAPortUntilItClosesThere() {
    const Pair pair;
    const LocalLink local{pair};
    auto listener = listenTcp("127.0.0.1", 0);
    const auto port = listener.port;
    EchoServer echo{std::move(listener.socket)};
    int reply[2];
    int status = -1;

    check(::pipe(reply) == 0);
    std::thread holder{[&] {
      status = LinkClient::forward(local.paths(), pair.destination, port, "test origin", reply[1]);
    }};
    const auto line = readSome(reply[0], 16);
    const auto local_port = static_cast<std::uint16_t>(std::stoul(line));

    check(local_port != 0 && local_port != port, "a port taken here is forwarded on another");
    {
      const auto connection = connectLocalPort(local_port);

      check(static_cast<bool>(connection));
      writeAll(connection.get(), "through");
      check(readExactly(connection.get(), 7) == "through");
    }

    int listing[2];

    check(::pipe(listing) == 0);
    check(LinkClient::ports(local.paths(), pair.destination, listing[1]) == 0);
    ::close(listing[1]);
    const auto rows = readAll(listing[0]);

    check(rows.starts_with(std::to_string(port) + " " + std::to_string(local_port) + " "), "a forward is listed with both ports");
    check(rows.ends_with(" asked test origin\n"));

    // Once nothing listens there the gateway says so, and the forward ends for whoever held
    // it without anyone having to try the port again.
    echo.stop();
    holder.join();
    check(status == 0, "the holder is told the port closed there");
    check(!connectLocalPort(local_port), "the port is free here again");
    for (const int descriptor : {reply[0], reply[1], listing[0]}) {
      ::close(descriptor);
    }
  }

  // The watch that told one forward its port closed ends with it; the forward opened right
  // after is told just as soon, by a watch started for it.
  void aForwardOpenedRightAfterAnotherEndedIsToldItsPortClosedToo() {
    const Pair pair;
    const LocalLink local{pair};

    for (int round = 0; round < 3; ++round) {
      auto listener = listenTcp("127.0.0.1", 0);
      const auto port = listener.port;
      EchoServer echo{std::move(listener.socket)};
      int reply[2];
      std::promise<int> ended;
      auto status = ended.get_future();

      check(::pipe(reply) == 0);
      std::thread holder{[&] {
        ended.set_value(LinkClient::forward(local.paths(), pair.destination, port, "test origin", reply[1]));
      }};

      check(std::stoul(readSome(reply[0], 16)) != 0);
      echo.stop();
      const bool told = status.wait_for(std::chrono::seconds{3}) == std::future_status::ready;

      holder.join();
      check(told && status.get() == 0, "each forward is told its port closed there within the time one watch takes");
      for (const int descriptor : {reply[0], reply[1]}) {
        ::close(descriptor);
      }
    }
  }

  // The gateway reads which ports listen at most once a second. A port that opened since it
  // last read them is looked for again when a client first asks about it, so a forward to it
  // is not told at once that it closed.
  void aForwardToAPortThatJustOpenedStaysOpen() {
    const Pair pair;
    const LocalLink local{pair};
    auto first = listenTcp("127.0.0.1", 0);
    const auto first_port = first.port;
    EchoServer steady{std::move(first.socket)};
    int kept[2];

    // A forward that stays makes the gateway read its ports again and again.
    check(::pipe(kept) == 0);
    std::thread keeper{[&] {
      static_cast<void>(LinkClient::forward(local.paths(), pair.destination, first_port, "kept", kept[1]));
    }};

    check(std::stoul(readSome(kept[0], 16)) != 0);
    for (int round = 0; round < 4; ++round) {
      auto listener = listenTcp("127.0.0.1", 0);
      const auto port = listener.port;
      EchoServer echo{std::move(listener.socket)};
      int reply[2];
      std::promise<int> ended;
      auto status = ended.get_future();

      check(::pipe(reply) == 0);
      std::thread holder{[&] {
        ended.set_value(LinkClient::forward(local.paths(), pair.destination, port, "just opened", reply[1]));
      }};

      check(std::stoul(readSome(reply[0], 16)) != 0);
      const bool kept_open = status.wait_for(std::chrono::milliseconds{700}) == std::future_status::timeout;

      echo.stop();
      holder.join();
      check(kept_open, "a forward to a port that just opened lasts while the port does");
      for (const int descriptor : {reply[0], reply[1]}) {
        ::close(descriptor);
      }
    }

    steady.stop();
    keeper.join();
    for (const int descriptor : {kept[0], kept[1]}) {
      ::close(descriptor);
    }
  }

  // One watch of a held machine outlives many forwards. A port whose holder left is no longer
  // watched there, so the ports the link has asked for never outgrow the forwards it keeps,
  // however many it has opened since the watch began.
  void theLinkStopsWatchingAPortItsHolderLeft() {
    const Pair pair;
    const LocalLink local{pair};
    const auto control = local.paths().control();
    const auto ask = [&](const std::string& request) {
      auto socket = connectUnix(control.view());

      check(static_cast<bool>(socket));
      writeAll(socket.get(), request);
      check(readSome(socket.get(), 16).starts_with("ok"), "the link accepts the request");
      return socket;
    };
    const auto holder = ask("hold " + std::string{pair.destination} + "\n");
    constexpr int batches = 7;
    constexpr int batch = 10;
    // The ports stay open there to the end: only their holders leave.
    std::vector<Listener> ports;

    for (int round = 0; round < batches; ++round) {
      std::vector<telar::runtime::FileDescriptor> holders;

      for (int index = 0; index < batch; ++index) {
        ports.push_back(listenTcp("127.0.0.1", 0));
        holders.push_back(ask("forward " + std::string{pair.destination} + " " + std::to_string(ports.back().port) + " test origin\n"));
      }

      // The watch asks the gateway about the forwards it finds once in each of its turns.
      std::this_thread::sleep_for(std::chrono::milliseconds{400});
    }

    // The watch that saw them all still tells a forward its port closed there.
    auto listener = listenTcp("127.0.0.1", 0);
    const auto port = listener.port;
    EchoServer echo{std::move(listener.socket)};
    int reply[2];
    std::promise<int> ended;
    auto status = ended.get_future();

    check(::pipe(reply) == 0);
    std::thread last{[&] {
      ended.set_value(LinkClient::forward(local.paths(), pair.destination, port, "test origin", reply[1]));
    }};

    check(std::stoul(readSome(reply[0], 16)) != 0);
    echo.stop();
    const bool told = status.wait_for(std::chrono::seconds{3}) == std::future_status::ready;

    last.join();
    check(told && status.get() == 0, "a forward opened after seventy others is told its port closed there");
    for (const int descriptor : {reply[0], reply[1]}) {
      ::close(descriptor);
    }
  }

  // The forwards of a machine, as the link lists them.
  std::string forwardsOf(const LocalLink& local, std::string_view destination) {
    int listing[2];

    check(::pipe(listing) == 0);
    check(LinkClient::ports(local.paths(), destination, listing[1]) == 0);
    ::close(listing[1]);
    auto rows = readAll(listing[0]);

    ::close(listing[0]);
    return rows;
  }

  // Asks until the forwards of a machine are what is awaited, for the few seconds the gateway
  // and the link take to tell each other.
  template <typename Awaited>
  std::string awaitForwards(const LocalLink& local, std::string_view destination, Awaited awaited) {
    std::string rows;

    for (int attempt = 0; attempt < 100; ++attempt) {
      rows = forwardsOf(local, destination);
      if (awaited(rows)) {
        break;
      }

      std::this_thread::sleep_for(std::chrono::milliseconds{50});
    }

    return rows;
  }

  void aPortAMachineSharesIsForwardedToWhoeverHoldsIt() {
    const Pair pair;
    const LocalLink local{pair};
    auto listener = listenTcp("127.0.0.1", 0);
    const auto port = listener.port;
    const EchoServer echo{std::move(listener.socket)};
    const auto sharing_path = std::string{pair.server.directory.path()} + "/" + std::string{Server::sharing_socket};
    const auto prefix = std::to_string(port) + " ";

    // A program of the machine shares the port before anyone holds the machine: nothing is
    // forwarded for nobody.
    auto sharing = connectUnix(sharing_path);

    check(static_cast<bool>(sharing));
    writeAll(sharing.get(), "share " + std::to_string(port) + " exec dev server\n");
    check(readSome(sharing.get(), 3) == "ok\n");
    writeAll(sharing.get(), "share 1 nothing listens on it\n");
    check(readSome(sharing.get(), 8) == "refused\n", "a port nothing listens on is not shared");
    check(forwardsOf(local, pair.destination).empty());

    auto held = LinkClient::hold(local.paths(), pair.destination);

    check(static_cast<bool>(held));
    const auto rows = awaitForwards(local, pair.destination, [&](const std::string& text) {
      return text.starts_with(prefix);
    });

    check(rows.starts_with(prefix) && rows.ends_with(" shared exec dev server\n"), "the holder gets the port without asking for it");
    const auto local_port = static_cast<std::uint16_t>(std::stoul(rows.substr(prefix.size())));
    {
      const auto connection = connectLocalPort(local_port);

      check(static_cast<bool>(connection));
      writeAll(connection.get(), "shared");
      check(readExactly(connection.get(), 6) == "shared");
    }

    // The program that shared it leaves: the port is no longer forwarded.
    sharing.reset();
    check(awaitForwards(local, pair.destination, [](const std::string& text) {
      return text.empty();
    }).empty(),
        "a port stops being forwarded when what shared it ends");

    // Shared again, it comes back; and it goes when nothing here holds the machine any more.
    sharing = connectUnix(sharing_path);
    writeAll(sharing.get(), "share " + std::to_string(port) + " again\n");
    check(readSome(sharing.get(), 3) == "ok\n");
    check(awaitForwards(local, pair.destination, [&](const std::string& text) {
      return text.starts_with(prefix);
    }).ends_with(" shared again\n"));

    held.reset();
    check(awaitForwards(local, pair.destination, [](const std::string& text) {
      return text.empty();
    }).empty(),
        "a shared port is forwarded only while something holds its machine");
  }

  // A holder is let go when it closes its connection, also one whose request came after the
  // link first looked for it: the end of a connection is told from one with nothing to say yet.
  void theLinkLetsGoOfAHolderWhoseRequestCameLate() {
    const Pair pair;
    const LocalLink local{pair};
    const auto control = local.paths().control();
    auto listener = listenTcp("127.0.0.1", 0);
    const auto port = listener.port;
    const EchoServer echo{std::move(listener.socket)};
    const auto prefix = std::to_string(port) + " ";
    const auto listed = [&](const std::string& text) {
      return text.starts_with(prefix);
    };
    const auto none = [](const std::string& text) {
      return text.empty();
    };
    // Connects, and asks only once the link has found the connection silent.
    const auto askLate = [&](const std::string& request) {
      auto socket = connectUnix(control.view());

      check(static_cast<bool>(socket));
      std::this_thread::sleep_for(std::chrono::milliseconds{100});
      writeAll(socket.get(), request);
      check(readSome(socket.get(), 16).starts_with("ok"), "the link accepts the request");
      return socket;
    };

    auto sharing = connectUnix(std::string{pair.server.directory.path()} + "/" + std::string{Server::sharing_socket});

    check(static_cast<bool>(sharing));
    writeAll(sharing.get(), "share " + std::to_string(port) + " late holder\n");
    check(readSome(sharing.get(), 3) == "ok\n");

    auto held = askLate("hold " + std::string{pair.destination} + "\n");

    check(awaitForwards(local, pair.destination, listed).ends_with(" shared late holder\n"));
    held.reset();
    check(awaitForwards(local, pair.destination, none).empty(), "a machine is no longer held once its holder closed");

    auto forward = askLate("forward " + std::string{pair.destination} + " " + std::to_string(port) + " late holder\n");

    check(awaitForwards(local, pair.destination, listed).ends_with(" asked late holder\n"));
    forward.reset();
    check(awaitForwards(local, pair.destination, none).empty(), "a forward ends once its holder closed");
  }

  // A command that goes through the link finds, from the second on, a connection the link
  // made while the one before ran; it runs the same either way.
  void commandsThroughTheLinkRunOnAConnectionKeptReady() {
    const Pair pair;
    const LocalLink local{pair};
    const auto paths = local.paths();

    for (int round = 1; round <= 4; ++round) {
      const auto command = "cat; echo round " + std::to_string(round) + " >&2; exit " + std::to_string(round);
      const auto result = pair.run(pair.client.state, pair.destination, command, "through the link", &paths);

      check(result.output == "through the link" && result.error == "round " + std::to_string(round) + "\n" && result.status == round);
      // The connection for the next command is made behind this one's back.
      std::this_thread::sleep_for(std::chrono::milliseconds{50});
    }

    const tests::Gateway stranger;
    const auto refused = pair.run(stranger.state, pair.destination, "echo no", {}, &paths);

    check(refused.status == 0 && refused.output == "no\n", "the link runs commands as the account whose link it is, whoever asks on its socket");
  }

  void theLinkRefusesAPortNothingListensOn() {
    const Pair pair;
    const LocalLink local{pair};
    auto listener = listenTcp("127.0.0.1", 0);
    const auto port = listener.port;
    int reply[2];

    listener.socket.reset();
    check(::pipe(reply) == 0);
    check(LinkClient::forward(local.paths(), pair.destination, port, "nothing", reply[1]) == 1);
    ::close(reply[0]);
    ::close(reply[1]);
  }

  const telar::testing::Case case_commands_run_with_their_streams_and_status{"gateway.commands_run_with_their_streams_and_status", commandsRunWithTheirStreamsAndStatus};
  const telar::testing::Case case_commands_carry_more_than_their_buffers{"gateway.commands_carry_more_than_their_buffers", commandsCarryMoreThanTheirBuffers};
  const telar::testing::Case case_only_paired_clients_are_served{"gateway.only_paired_clients_are_served", onlyPairedClientsAreServed};
  const telar::testing::Case case_a_client_revoked_while_served_is_cut{"gateway.a_client_revoked_while_served_is_cut", aClientRevokedWhileServedIsCut};
  const telar::testing::Case case_clients_refuse_a_gateway_with_another_key{"gateway.clients_refuse_a_gateway_with_another_key", clientsRefuseAGatewayWithAnotherKey};
  const telar::testing::Case case_pairing_codes_enroll_once{"gateway.pairing_codes_enroll_once", pairingCodesEnrollOnce};
  const telar::testing::Case case_one_address_holds_a_few_handshakes{"gateway.one_address_holds_a_few_handshakes", oneAddressHoldsAFewHandshakes};
  const telar::testing::Case case_a_full_client_list_leaves_the_pairing_code_pending{"gateway.a_full_client_list_leaves_the_pairing_code_pending", aFullClientListLeavesThePairingCodePending};
  const telar::testing::Case case_the_link_offers_a_machines_runtime_on_a_local_socket{"gateway.the_link_offers_a_machines_runtime_on_a_local_socket", theLinkOffersAMachinesRuntimeOnALocalSocket};
  const telar::testing::Case case_the_link_reuses_the_slot_of_a_machine_nothing_uses{"gateway.the_link_reuses_the_slot_of_a_machine_nothing_uses", theLinkReusesTheSlotOfAMachineNothingUses};
  const telar::testing::Case case_a_forward_carries_a_few_connections_at_once{"gateway.a_forward_carries_a_few_connections_at_once", aForwardCarriesAFewConnectionsAtOnce};
  const telar::testing::Case case_the_link_forwards_a_port_until_it_closes_there{"gateway.the_link_forwards_a_port_until_it_closes_there", theLinkForwardsAPortUntilItClosesThere};
  const telar::testing::Case case_a_port_a_machine_shares_is_forwarded_to_whoever_holds_it{"gateway.a_port_a_machine_shares_is_forwarded_to_whoever_holds_it", aPortAMachineSharesIsForwardedToWhoeverHoldsIt};
  const telar::testing::Case case_the_link_lets_go_of_a_holder_whose_request_came_late{"gateway.the_link_lets_go_of_a_holder_whose_request_came_late", theLinkLetsGoOfAHolderWhoseRequestCameLate};
  const telar::testing::Case case_a_forward_opened_right_after_another_ended_is_told_its_port_closed_too{"gateway.a_forward_opened_right_after_another_ended_is_told_its_port_closed_too", aForwardOpenedRightAfterAnotherEndedIsToldItsPortClosedToo};
  const telar::testing::Case case_a_forward_to_a_port_that_just_opened_stays_open{"gateway.a_forward_to_a_port_that_just_opened_stays_open", aForwardToAPortThatJustOpenedStaysOpen};
  const telar::testing::Case case_the_link_stops_watching_a_port_its_holder_left{"gateway.the_link_stops_watching_a_port_its_holder_left", theLinkStopsWatchingAPortItsHolderLeft};
  const telar::testing::Case case_commands_through_the_link_run_on_a_connection_kept_ready{"gateway.commands_through_the_link_run_on_a_connection_kept_ready", commandsThroughTheLinkRunOnAConnectionKeptReady};
  const telar::testing::Case case_the_link_refuses_a_port_nothing_listens_on{"gateway.the_link_refuses_a_port_nothing_listens_on", theLinkRefusesAPortNothingListensOn};

}
