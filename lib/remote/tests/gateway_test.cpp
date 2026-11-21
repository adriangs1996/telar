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
      destination = std::string{enroll(client.state, endpoint.format().view(), "test client").view()};
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

    Result run(const State& state, std::string_view target, std::string_view command, std::string_view input = {}) const {
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

      result.status = runRemote(state, {.destination = target, .command = command, .streams = {.input = in[0], .output = out[1], .error = err[1]}});
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
    check(enroll(second.state, endpoint.format().view(), "second").view() == pair.unpaired);
    check(pair.run(second.state, pair.unpaired, "echo yes").output == "yes\n");

    const tests::Gateway third;

    try {
      static_cast<void>(enroll(third.state, endpoint.format().view(), "third"));
    } catch (const ChannelFailure&) {
      refused = true;
    }

    check(refused, "a code that enrolled a client enrolls no other");
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
    check(rows.ends_with(" test origin\n"));

    // Once nothing listens there, the next connection finds the gateway refusing the port, and
    // the forward ends for whoever held it.
    echo.stop();
    {
      const auto connection = connectLocalPort(local_port);

      check(readSome(connection.get(), 1).empty());
    }

    holder.join();
    check(status == 0, "the holder is told the port closed there");
    for (const int descriptor : {reply[0], reply[1], listing[0]}) {
      ::close(descriptor);
    }
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
  const telar::testing::Case case_clients_refuse_a_gateway_with_another_key{"gateway.clients_refuse_a_gateway_with_another_key", clientsRefuseAGatewayWithAnotherKey};
  const telar::testing::Case case_pairing_codes_enroll_once{"gateway.pairing_codes_enroll_once", pairingCodesEnrollOnce};
  const telar::testing::Case case_the_link_offers_a_machines_runtime_on_a_local_socket{"gateway.the_link_offers_a_machines_runtime_on_a_local_socket", theLinkOffersAMachinesRuntimeOnALocalSocket};
  const telar::testing::Case case_the_link_forwards_a_port_until_it_closes_there{"gateway.the_link_forwards_a_port_until_it_closes_there", theLinkForwardsAPortUntilItClosesThere};
  const telar::testing::Case case_the_link_refuses_a_port_nothing_listens_on{"gateway.the_link_refuses_a_port_nothing_listens_on", theLinkRefusesAPortNothingListensOn};

}
