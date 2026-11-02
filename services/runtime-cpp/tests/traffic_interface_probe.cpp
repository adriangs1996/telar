#include "check.hpp"
#include "platform/private_tunnel.hpp"
#include "traffic/datagram.hpp"
#include <optional>
#include <poll.h>

using namespace telar;
using namespace telar::runtime;

static constexpr std::size_t payload_bytes = 32;
static constexpr std::size_t family_bytes = sizeof(std::uint32_t);
static constexpr std::size_t ipv4_bytes = 20;
static constexpr std::size_t udp_bytes = 8;
static constexpr std::uint16_t fixture_port = 53535;
using Packet = std::array<Byte, family_bytes + ipv4_bytes + udp_bytes + payload_bytes>;

static std::uint16_t checksum(std::span<const Byte> bytes) {
  std::uint32_t sum = 0;
  for (std::size_t offset = 0; offset < bytes.size(); offset += 2) {
    sum += traffic::NetworkPacket::word(bytes, offset);
  }
  while (sum >> 16) { sum = (sum & UINT16_MAX) + (sum >> 16); }

  return static_cast<std::uint16_t>(~sum);
}

static Packet packet() {
  Packet frame{};
  const std::uint32_t family = htonl(AF_INET);
  std::memcpy(frame.data(), &family, sizeof(family));
  const auto ip = std::span{frame}.subspan(family_bytes);
  const auto word = [&](std::size_t offset, std::uint16_t value) { ip[offset] = value >> 8; ip[offset + 1] = value; };
  ip[0] = 0x45;
  word(2, ip.size());
  ip[8] = 1;
  ip[9] = IPPROTO_UDP;
  // Loopback addresses keep this capture fixture from reaching another machine,
  // even when the host permits IP forwarding on the private interface.
  ip[12] = ip[16] = 127;
  ip[15] = ip[19] = 1;
  word(10, checksum(ip.first(ipv4_bytes)));
  word(ipv4_bytes, fixture_port);
  word(ipv4_bytes + 2, fixture_port);
  word(ipv4_bytes + 4, udp_bytes + payload_bytes);
  ::arc4random_buf(ip.data() + ipv4_bytes + udp_bytes, payload_bytes);
  ip.back() = 0;

  return frame;
}

static int run() {
  if (::geteuid() != 0) { throw std::invalid_argument{"The interface probe requires sudo"}; }
  const auto frame = packet();
  std::optional<PrivateTunnel> tunnel;
  std::printf("{\"ready\":true,\"token\":\"");
  for (const auto byte : std::span{frame}.last(payload_bytes)) { std::printf("%02x", byte); }
  std::puts("\"}");
  std::fflush(stdout);

  for (;;) {
    pollfd input{STDIN_FILENO, POLLIN, 0};
    const auto ready = ::poll(&input, 1, 30000);
    if (ready < 0 && errno == EINTR) { continue; }
    if (ready <= 0 || (input.revents & (POLLHUP | POLLERR | POLLNVAL))) { return 0; }
    std::array<char, 16> command{};
    if (!std::fgets(command.data(), command.size(), stdin)) { return 0; }
    const std::string_view action{command.data()};
    if (action == "open\n" && !tunnel) {
      tunnel.emplace();
      std::printf("{\"interface\":\"%.*s\",\"index\":%u}\n", static_cast<int>(tunnel->name().size()), tunnel->name().data(), tunnel->index());
    } else if (action == "packet\n" && tunnel) {
      const auto written = tunnel->write(frame);
      if (written != static_cast<ssize_t>(frame.size())) { throw SystemError{"Inject private-interface fixture"}; }
      std::puts("{\"sent\":true}");
    } else if (action == "close\n" && tunnel) {
      tunnel.reset();
      std::puts("{\"closed\":true}");
    } else if (action == "quit\n") {
      return 0;
    } else { throw std::invalid_argument{"Invalid interface probe command"}; }
    std::fflush(stdout);
  }
}

int main(int argc, char **argv) {
  try {
    if (argc == 2 && std::string_view{argv[1]} == "--self-test") {
      const auto frame = packet();
      const auto ip = traffic::IpPayload::decode(std::span{frame}.subspan(family_bytes));
      check(ip && !ip->ipv6 && checksum(std::span{frame}.subspan(family_bytes, ipv4_bytes)) == 0);
      const auto udp = traffic::DatagramCodec::parse(*ip);
      check(udp && udp->source_port == fixture_port && udp->destination_port == fixture_port && !udp->truncated);
      check(std::ranges::equal(udp->bytes, std::span{frame}.last(payload_bytes)) && udp->bytes.back() == 0);
      std::puts("Virtual-interface packet fixture verified");
      return 0;
    }
    if (argc != 1) { throw std::invalid_argument{"Expected no arguments, or --self-test"}; }

    return run();
  } catch (const std::exception &error) {
    std::fprintf(stderr, "telar interface probe: %s\n", error.what());
    return 1;
  }
}
