#include "check.hpp"
#include "proxy/listener.hpp"
#include "proxy/port_memory.hpp"
#include <filesystem>
#include <fstream>
#include <cstring>

using namespace telar::runtime;

void testProxyResolution();
void testProxyTransport();

static void privateRecord(int directory, std::string_view name, std::string_view text) {
  check(writePrivateFile(directory, name, {reinterpret_cast<const std::uint8_t *>(text.data()), text.size()}, PrivateFileMode::replace) == 0);
}

static void testPortMemory(SystemAllocator &memory) {
  std::array<char, 64> path;
  std::strcpy(path.data(), "/tmp/telar-proxy-ports-XXXXXX");
  check(::mkdtemp(path.data()) != nullptr);
  FileDescriptor directory{::open(path.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
  check(static_cast<bool>(directory));
  const auto root = std::filesystem::path{path.data()};
  for (const auto name : {"first", "second", "legacy", "replacement"}) {
    std::filesystem::create_directory(root / name);
  }

  ProxyPortMemory known{memory, directory.get(), "/tmp/telar/runtime.sock", false};
  check(known.filename() == "proxy-port-2115767474b514fb" && !known.preferred() && known.reserved().none());
  const auto first_endpoint = (root / "first/runtime.sock").string();
  const auto second_endpoint = (root / "second/runtime.sock").string();
  ProxyPortMemory first{memory, directory.get(), first_endpoint, false};
  check(first.remember(45110));
  ProxyPortMemory second{memory, directory.get(), second_endpoint, false};
  check(!second.preferred() && second.reserved().test(10));
  check(second.remember(45111));
  privateRecord(directory.get(), "proxy-port", "45112\n");

  ProxyPortMemory restarted{memory, directory.get(), first_endpoint, true};
  check(restarted.preferred() == 45110 && restarted.reserved().test(11) && restarted.reserved().test(12));
  ProxyPortMemory legacy{memory, directory.get(), (root / "legacy/runtime.sock").string(), true};
  check(legacy.preferred() == 45112 && legacy.remember(45112));
  check(!std::filesystem::exists(root / "proxy-port"));

  std::filesystem::remove(root / "first");
  ProxyPortMemory replacement{memory, directory.get(), (root / "replacement/runtime.sock").string(), false};
  check(!replacement.reserved().test(10) && !std::filesystem::exists(root / first.filename()));
  check(replacement.reserved().test(11) && replacement.remember(45111));
  check(!std::filesystem::exists(root / second.filename()));
  ProxyPortMemory moved{memory, directory.get(), (root / "replacement/runtime.sock").string(), false};
  check(moved.preferred() == 45111);

  privateRecord(directory.get(), moved.filename(), "+4_51_00\r\nrelative/socket\r\n");
  ProxyPortMemory signed_record{memory, directory.get(), (root / "replacement/runtime.sock").string(), false};
  check(signed_record.preferred() == 45100);
  for (const auto text : {"45099\n", "45228\n", "45100_\n", "_45100\n", "45100 \n", "-45100\n", "42949672960000045100\n"}) {
    privateRecord(directory.get(), moved.filename(), text);
    ProxyPortMemory invalid{memory, directory.get(), (root / "replacement/runtime.sock").string(), false};
    check(!invalid.preferred());
  }

  const std::array<std::uint8_t, 3> contents{'n', 'e', 'w'};
  check(writePrivateFile(directory.get(), moved.filename(), contents, PrivateFileMode::create_only) == EEXIST);
  for (const auto &entry : std::filesystem::directory_iterator{root}) {
    check(!entry.path().filename().string().starts_with(".telar-write-"));
  }
  std::filesystem::remove_all(root);
}

static void testProxyListener() {
  const ProxyPortRange::Set reserved;
  auto first = ProxyListener::bind(std::nullopt, reserved);
  check(ProxyPortRange::contains(first.port()));
  sockaddr_in address{};
  socklen_t length = sizeof(address);
  check(::getsockname(first.descriptor(), reinterpret_cast<sockaddr *>(&address), &length) == 0);
  check(address.sin_addr.s_addr == htonl(INADDR_LOOPBACK) && ntohs(address.sin_port) == first.port());
  check((::fcntl(first.descriptor(), F_GETFD) & FD_CLOEXEC) != 0);
  check((::fcntl(first.descriptor(), F_GETFL) & O_NONBLOCK) != 0);

  auto second = ProxyListener::bind(first.port(), reserved);
  check(second.port() != first.port());
  const auto old_port = first.port();
  first.close();
  auto restarted = ProxyListener::bind(old_port, reserved);
  check(restarted.port() == old_port);

  FileDescriptor client{::socket(AF_INET, SOCK_STREAM, 0)};
  address.sin_port = htons(restarted.port());
  check(client && ::connect(client.get(), reinterpret_cast<const sockaddr *>(&address), sizeof(address)) == 0);
  pollfd pending{.fd = restarted.descriptor(), .events = POLLIN, .revents = 0};
  check(::poll(&pending, 1, 1000) == 1);
  auto child = restarted.accept();
  check(child && (::fcntl(child.get(), F_GETFD) & FD_CLOEXEC) != 0 && (::fcntl(child.get(), F_GETFL) & O_NONBLOCK) != 0);

  auto vacant = ProxyListener::bind(std::nullopt, reserved);
  const auto wildcard_port = vacant.port();
  vacant.close();
  FileDescriptor wildcard{::socket(AF_INET, SOCK_STREAM, 0)};
  address.sin_port = htons(wildcard_port);
  address.sin_addr.s_addr = htonl(INADDR_ANY);
  check(wildcard && ::bind(wildcard.get(), reinterpret_cast<const sockaddr *>(&address), sizeof(address)) == 0 && ::listen(wildcard.get(), 8) == 0);
  auto safe = ProxyListener::bind(wildcard_port, reserved);
  check(safe.port() != wildcard_port);
}

void testProxyNetwork() {
  SystemAllocator memory;
  testPortMemory(memory);
  testProxyListener();
  testProxyResolution();
  testProxyTransport();
}
