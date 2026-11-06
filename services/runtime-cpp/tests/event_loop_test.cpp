#include "check.hpp"
#include "platform/event_loop.hpp"
#include "telar_base/memory/allocator.hpp"
#include <algorithm>
#include <csignal>
#include <sys/socket.h>
#include <sys/wait.h>
#include <thread>

using namespace telar;
using namespace telar::runtime;

namespace {

std::array<FileDescriptor, 2> socketPair() {
  int descriptors[2];
  check(::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) == 0);
  return {FileDescriptor{descriptors[0]}, FileDescriptor{descriptors[1]}};
}

void interestsAndTokens(SystemAllocator &memory) {
  NativeEventLoop<SystemAllocator> poller{memory};
  auto sockets = socketPair();
  constexpr std::uint64_t token = UINT64_MAX;
  poller.watch(sockets[0].get(), token);
  poller.writeInterest(sockets[0].get(), token, true);
  const auto writable = poller.wait(std::chrono::nanoseconds::zero());
  check(std::ranges::any_of(writable, [&](const Event &event) { return event.descriptor == sockets[0].get() && event.token == token && event.kind == EventKind::writable; }));

  poller.writeInterest(sockets[0].get(), token, false);
  check(poller.wait(std::chrono::nanoseconds::zero()).empty());
  constexpr char payload = 'x';
  check(::write(sockets[1].get(), &payload, sizeof(payload)) == sizeof(payload));
  const auto readable = poller.wait(std::chrono::milliseconds{100});
  check(std::ranges::any_of(readable, [&](const Event &event) { return event.descriptor == sockets[0].get() && event.token == token && event.kind == EventKind::readable; }));

  poller.readInterest(sockets[0].get(), token, false);
  check(poller.wait(std::chrono::nanoseconds::zero()).empty());
  poller.readInterest(sockets[0].get(), token, true);
  char received = 0;
  check(::read(sockets[0].get(), &received, sizeof(received)) == sizeof(received));
  check(received == payload);
  sockets[1].reset();
  const auto closed = poller.wait(std::chrono::milliseconds{100});
  check(std::ranges::any_of(closed, [&](const Event &event) { return event.descriptor == sockets[0].get() && event.closed; }));

  poller.remove(sockets[0].get());
  check(poller.wait(std::chrono::nanoseconds::zero()).empty());
}

void replaceDescriptor(SystemAllocator &memory) {
  NativeEventLoop<SystemAllocator> poller{memory};
  auto first = socketPair();
  const auto descriptor = first[0].get();
  constexpr std::uint64_t previous_token = UINT64_MAX;
  constexpr std::uint64_t replacement_token = 1;
  poller.watch(descriptor, previous_token);
  FileDescriptor retained{::dup(descriptor)};
  check(static_cast<bool>(retained));
  first[0].reset();
  auto replacement = socketPair();
  if (replacement[0].get() != descriptor) {
    check(::dup2(replacement[0].get(), descriptor) == descriptor);
    replacement[0].reset(descriptor);
  }

  poller.watch(descriptor, replacement_token);
  constexpr char payload = 'r';
  check(::write(first[1].get(), &payload, sizeof(payload)) == sizeof(payload));
  check(::write(replacement[1].get(), &payload, sizeof(payload)) == sizeof(payload));
  const auto events = poller.wait(std::chrono::milliseconds{100});
  check(events.size() == 1);
  for (const auto &event : events) {
    check(event.descriptor == descriptor && event.token == replacement_token);
  }
  char received = 0;
  check(::read(replacement[0].get(), &received, sizeof(received)) == sizeof(received));
  check(poller.wait(std::chrono::nanoseconds::zero()).empty());
}

void signals(SystemAllocator &memory) {
  struct sigaction previous{};
  check(::sigaction(SIGUSR1, nullptr, &previous) == 0);
  {
    NativeEventLoop<SystemAllocator> poller{memory};
    poller.watchSignal(SIGUSR1);
    poller.watchSignal(SIGCHLD);
    std::thread notifier{[] { ::kill(::getpid(), SIGUSR1); }};
    notifier.join();
    bool notified = false;
    for (const auto &event : poller.wait(std::chrono::milliseconds{100})) {
      notified |= event.kind == EventKind::signal && event.descriptor == SIGUSR1;
    }
    check(notified);

    const auto child = ::fork();
    check(child >= 0);
    if (child == 0) {
      _exit(7);
    }
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
    bool reaped = false;
    while (!reaped && std::chrono::steady_clock::now() < deadline) {
      for (const auto &event : poller.wait(std::chrono::milliseconds{100})) {
        reaped |= event.kind == EventKind::signal && event.descriptor == SIGCHLD;
      }
    }
    check(reaped);
    int status = 0;
    check(::waitpid(child, &status, 0) == child);
    check(WIFEXITED(status) && WEXITSTATUS(status) == 7);
  }
  check(::sigaction(SIGUSR1, &previous, nullptr) == 0);
}

}

int main() {
  SystemAllocator memory;
  interestsAndTokens(memory);
  replaceDescriptor(memory);
  signals(memory);
}
