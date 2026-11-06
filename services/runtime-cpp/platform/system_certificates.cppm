module;

#include <cerrno>
#include <exception>
#include <array>
#include <cstdio>
#include <fcntl.h>
#include <limits.h>
#include <limits>
#include <unistd.h>


#include "telar_base/memory/allocator.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <chrono>
#include <concepts>
#include <cstdint>
#include <span>
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#include <algorithm>
#endif
#if (defined(__linux__))
#include <atomic>
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#include <csignal>
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__))
#endif


#if defined(__linux__)


#include <cstdlib>
#include <memory>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509.h>


#endif

#if defined(__APPLE__)


#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <memory>


#endif


#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#include <CoreFoundation/CoreFoundation.h>
#endif
#if (defined(__APPLE__))
#include <Security/Security.h>
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#include <memory>
#endif
#if (defined(__APPLE__))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <cstdlib>
#endif
#if (!(defined(__APPLE__)))
#include <memory>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/err.h>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/pem.h>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/x509.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif

export module telar.runtime.platform.system_certificates;

export import telar.platform;


#if (defined(__linux__))
export import telar.platform;
#endif


#if defined(__linux__)

export import telar.platform;


#endif

#if defined(__APPLE__)

export import telar.platform;


#endif


#if (defined(__APPLE__))

#endif
#if (!(defined(__APPLE__)))

#endif

// Interface: platform/descriptor_path.cppm
export {
namespace telar::runtime {

inline std::array<char, PATH_MAX> descriptorPath(int descriptor) {
  std::array<char, PATH_MAX> path{};
#if defined(__APPLE__)
  if (::fcntl(descriptor, F_GETPATH, path.data()) != 0) {
    throw SystemError{"Resolve open file path"};
  }
#else
  std::array<char, sizeof("/proc/self/fd/") + std::numeric_limits<int>::digits10 + 1> link{};
  std::snprintf(link.data(), link.size(), "/proc/self/fd/%d", descriptor);
  const auto length = ::readlink(link.data(), path.data(), path.size());
  if (length < 0) {
    throw SystemError{"Resolve open file path"};
  }
  if (static_cast<std::size_t>(length) >= path.size()) {
    throw SystemError{"Open file path exceeds its limit", ENAMETOOLONG};
  }
#endif
  return path;
}

}
}

// Interface: platform/event_loop.cppm
export {
#if defined(__APPLE__)
#endif

namespace telar::runtime {

enum class EventKind {
  readable,
  writable,
  signal
};

struct Event {
  EventKind kind;
  int descriptor;
  std::uint64_t token;
  bool closed;
};

#if defined(__APPLE__)
class Kqueue {
public:
  Kqueue();

  template <Allocator Memory>
  inline explicit Kqueue(Memory &) : Kqueue() {}
  void watch(int descriptor, std::uint64_t token);
  void readInterest(int descriptor, std::uint64_t token, bool enabled);
  void writeInterest(int descriptor, std::uint64_t token, bool enabled);
  void remove(int descriptor) noexcept;
  void watchSignal(int signal_number);
  std::span<const Event> wait(std::chrono::nanoseconds timeout);

private:
  void change(const struct kevent &event);

  FileDescriptor queue_;
  static constexpr std::size_t batch_capacity = 128;
  std::array<struct kevent, batch_capacity> kernel_events_{};
  std::array<Event, batch_capacity> events_{};
};

#endif

template <typename Poller>
concept EventLoop = requires(Poller &poller, int descriptor, std::uint64_t token, std::chrono::nanoseconds timeout) {
  { poller.watch(descriptor, token) } -> std::same_as<void>;
  { poller.readInterest(descriptor, token, true) } -> std::same_as<void>;
  { poller.writeInterest(descriptor, token, true) } -> std::same_as<void>;
  { poller.remove(descriptor) } noexcept -> std::same_as<void>;
  { poller.wait(timeout) } -> std::same_as<std::span<const Event>>;
};

#if defined(__APPLE__)
template <Allocator Memory>
using NativeEventLoop = Kqueue;

static_assert(EventLoop<Kqueue>);
#endif

}

#if defined(__linux__)
namespace telar::runtime {
namespace linux_signals {

struct Registration {
  std::atomic<int> destination{0};
  std::atomic<unsigned> writers{0};
  std::atomic<bool> pending{false};
};

static_assert(std::atomic<int>::is_always_lock_free && std::atomic<unsigned>::is_always_lock_free && std::atomic<bool>::is_always_lock_free);
inline std::array<Registration, NSIG> registrations;

inline void notify(int number) noexcept {
  const int saved_error = errno;
  auto &registration = registrations[number];
  registration.writers.fetch_add(1);
  const auto destination = registration.destination.load();
  if (destination > 0 && !registration.pending.exchange(true)) {
    const auto value = static_cast<unsigned char>(number);
    ssize_t count;
    do {
      count = ::write(destination - 1, &value, sizeof(value));
    } while (count < 0 && errno == EINTR);
  }
  registration.writers.fetch_sub(1);
  errno = saved_error;
}

}

template <Allocator Memory>
class Epoll {
  struct Interest {
    std::uint64_t token = 0;
    std::uint32_t mask = 0;
    std::uint32_t generation = 0;
    bool installed = false;
  };

public:
  inline explicit Epoll(Memory &memory) : queue_(::epoll_create1(EPOLL_CLOEXEC)), interests_(AllocatorRef<Interest, Memory>{memory}) {
    if (!queue_) {
      throw SystemError{"Create runtime event queue"};
    }
  }

  inline ~Epoll() {
    for (int number = 1; number < NSIG; ++number) {
      if (signals_[number]) {
        auto &registration = linux_signals::registrations[number];
        registration.destination.store(0);
        ::sigaction(number, &previous_signals_[number], nullptr);
        while (registration.writers.load() != 0) {
          ::sched_yield();
        }
      }
    }
  }

  Epoll(const Epoll &) = delete;
  Epoll &operator=(const Epoll &) = delete;

  inline void watch(int descriptor, std::uint64_t token) {
    if (descriptor >= 0 && static_cast<std::size_t>(descriptor) < interests_.size()) {
      auto &interest = interests_[descriptor];
      interest.mask = 0;
      ++interest.generation;
    }
    readInterest(descriptor, token, true);
  }

  inline void readInterest(int descriptor, std::uint64_t token, bool enabled) {
    change(descriptor, token, EPOLLIN, enabled);
  }

  inline void writeInterest(int descriptor, std::uint64_t token, bool enabled) {
    change(descriptor, token, EPOLLOUT, enabled);
  }

  inline void remove(int descriptor) noexcept {
    if (descriptor < 0 || static_cast<std::size_t>(descriptor) >= interests_.size()) {
      return;
    }

    auto &interest = interests_[descriptor];
    ::epoll_ctl(queue_.get(), EPOLL_CTL_DEL, descriptor, nullptr);
    interest.installed = false;
    interest.mask = 0;
    ++interest.generation;
  }

  inline void watchSignal(int number) {
    if (number <= 0 || number >= NSIG || number == SIGKILL || number == SIGSTOP) {
      throw SystemError{"Invalid runtime signal", EINVAL};
    }
    if (signals_[number]) {
      return;
    }
    auto &registration = linux_signals::registrations[number];
    if (registration.destination.load() != 0) {
      throw SystemError{"Runtime signal already has an event queue", EBUSY};
    }

    if (!signal_reader_) {
      int descriptors[2];
      if (::pipe2(descriptors, O_CLOEXEC | O_NONBLOCK) != 0) {
        throw SystemError{"Create runtime signal pipe"};
      }
      signal_reader_.reset(descriptors[0]);
      signal_writer_.reset(descriptors[1]);
      watch(signal_reader_.get(), 0);
    }

    struct sigaction action{};
    action.sa_handler = &linux_signals::notify;
    action.sa_flags = SA_RESTART;
    ::sigemptyset(&action.sa_mask);
    int unclaimed = 0;
    if (!registration.destination.compare_exchange_strong(unclaimed, signal_writer_.get() + 1)) {
      throw SystemError{"Runtime signal already has an event queue", EBUSY};
    }
    registration.pending.store(false);
    if (::sigaction(number, &action, &previous_signals_[number]) != 0) {
      registration.destination.store(0);
      throw SystemError{"Register runtime signal"};
    }
    signals_[number] = true;
  }

  inline std::span<const Event> wait(std::chrono::nanoseconds timeout) {
    timeout = std::max(timeout, std::chrono::nanoseconds::zero());
    const auto seconds = std::chrono::duration_cast<std::chrono::seconds>(timeout);
    const timespec duration{.tv_sec = seconds.count(), .tv_nsec = (timeout - seconds).count()};
#if defined(__GLIBC__)
    const auto count = ::epoll_pwait2(queue_.get(), kernel_events_.data(), kernel_events_.size(), &duration, nullptr);
#else
    // musl declares no epoll_pwait2; the kernel call takes the mask's size.
    const auto count = static_cast<int>(::syscall(SYS_epoll_pwait2, queue_.get(), kernel_events_.data(), kernel_events_.size(), &duration, nullptr, 0));
#endif
    if (count < 0) {
      if (errno == EINTR) {
        return {};
      }
      throw SystemError{"Wait for runtime event"};
    }

    std::size_t produced = 0;
    for (int index = 0; index < count; ++index) {
      const auto &event = kernel_events_[index];
      const auto descriptor = static_cast<int>(static_cast<std::uint32_t>(event.data.u64));
      const auto &interest = interests_[descriptor];
      if (!interest.installed || event.data.u64 >> descriptor_bits != interest.generation) {
        continue;
      }
      if (signal_reader_ && descriptor == signal_reader_.get()) {
        std::array<unsigned char, batch_capacity> pending;
        const auto ignored = ::read(descriptor, pending.data(), pending.size());
        (void)ignored;
        for (int number = 1; number < NSIG; ++number) {
          if (signals_[number] && linux_signals::registrations[number].pending.exchange(false)) {
            events_[produced++] = {EventKind::signal, number, 0, false};
          }
        }
        continue;
      }

      const bool closed = (event.events & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) != 0;
      if ((interest.mask & EPOLLIN) && ((event.events & EPOLLIN) || closed)) {
        events_[produced++] = {EventKind::readable, descriptor, interest.token, closed};
      }
      if ((interest.mask & EPOLLOUT) && ((event.events & EPOLLOUT) || closed)) {
        events_[produced++] = {EventKind::writable, descriptor, interest.token, closed};
      }
    }

    return std::span<const Event>{events_}.first(produced);
  }

private:
  inline void change(int descriptor, std::uint64_t token, std::uint32_t kind, bool enabled) {
    if (descriptor < 0 || ::fcntl(descriptor, F_GETFD) < 0) {
      throw SystemError{"Invalid runtime event descriptor", EBADF};
    }
    if (static_cast<std::size_t>(descriptor) >= interests_.size()) {
      interests_.resize(static_cast<std::size_t>(descriptor) + 1);
    }

    auto &interest = interests_[descriptor];
    if (interest.token != token) {
      ++interest.generation;
    }
    const auto mask = enabled ? interest.mask | kind : interest.mask & ~kind;
    if (mask == 0) {
      remove(descriptor);
      interest.token = token;
      return;
    }

    epoll_event event{};
    event.events = mask | EPOLLRDHUP;
    event.data.u64 = (static_cast<std::uint64_t>(interest.generation) << descriptor_bits) | static_cast<std::uint32_t>(descriptor);
    auto operation = interest.installed ? EPOLL_CTL_MOD : EPOLL_CTL_ADD;
    if (::epoll_ctl(queue_.get(), operation, descriptor, &event) != 0) {
      if (operation != EPOLL_CTL_MOD || errno != ENOENT || ::epoll_ctl(queue_.get(), EPOLL_CTL_ADD, descriptor, &event) != 0) {
        throw SystemError{"Register runtime event"};
      }
    }

    interest.token = token;
    interest.mask = mask;
    interest.installed = true;
  }

  static constexpr unsigned descriptor_bits = 32;
  static constexpr std::size_t batch_capacity = 128;
  static_assert(NSIG - 1 <= batch_capacity);
  FileDescriptor queue_;
  Vector<Interest, Memory> interests_;
  FileDescriptor signal_reader_;
  FileDescriptor signal_writer_;
  std::array<struct sigaction, NSIG> previous_signals_{};
  std::array<bool, NSIG> signals_{};
  std::array<epoll_event, batch_capacity> kernel_events_{};
  std::array<Event, batch_capacity * 3> events_{};
};

static_assert(EventLoop<Epoll<SystemAllocator>>);

}
namespace telar::runtime {
template <Allocator Memory>
using NativeEventLoop = Epoll<Memory>;
}
#endif
}

#if defined(__linux__)
// Interface: platform/linux/system_certificates.cppm
export {
namespace telar::runtime {

class SystemCertificates {
  struct FreeEncoded {
    inline void operator()(unsigned char *bytes) const noexcept { OPENSSL_free(bytes); }
  };

  // telar links its own OpenSSL, whose default bundle path matches only some
  // distributions. These are the bundles Go's crypto/x509 looks for, in order.
  static constexpr std::array bundles{
    "/etc/ssl/certs/ca-certificates.crt",                // Debian, Ubuntu, Gentoo and others
    "/etc/pki/tls/certs/ca-bundle.crt",                  // Fedora, RHEL 6
    "/etc/ssl/ca-bundle.pem",                            // openSUSE
    "/etc/pki/tls/cacert.pem",                           // OpenELEC
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", // CentOS, RHEL 7
    "/etc/ssl/cert.pem",                                 // Alpine
  };

  inline static const char *bundle() noexcept {
    const auto *path = std::getenv(X509_get_default_cert_file_env());
    if (path != nullptr && path[0] != '\0') {
      return path;
    }

    for (const auto *candidate : bundles) {
      if (::access(candidate, R_OK) == 0) {
        return candidate;
      }
    }

    return bundles.back();
  }

public:
  template <typename Consumer>
  inline static void read(Consumer &&consume) {
    const auto *path = bundle();
    const std::unique_ptr<BIO, decltype(&BIO_free)> file{BIO_new_file(path, "r"), &BIO_free};
    if (!file) {
      throw SystemError{"Open system certificate bundle", EACCES};
    }

    std::size_t count = 0;
    for (;;) {
      const std::unique_ptr<X509, decltype(&X509_free)> certificate{PEM_read_bio_X509_AUX(file.get(), nullptr, nullptr, nullptr), &X509_free};
      if (!certificate) {
        if (!BIO_eof(file.get()) || count == 0) {
          throw SystemError{"Read system certificate bundle", EINVAL};
        }
        ERR_clear_error();
        return;
      }
      ++count;
      if (X509_check_trust(certificate.get(), X509_TRUST_SSL_SERVER, 0) == X509_TRUST_REJECTED) {
        continue;
      }

      unsigned char *encoded = nullptr;
      const auto length = i2d_X509(certificate.get(), &encoded);
      const std::unique_ptr<unsigned char, FreeEncoded> bytes{encoded};
      if (length <= 0 || encoded == nullptr) {
        throw SystemError{"Encode system certificate", EINVAL};
      }
      consume(std::span<const std::uint8_t>{bytes.get(), static_cast<std::size_t>(length)});
    }
  }
};

}
}

#endif

#if defined(__APPLE__)
// Interface: platform/macos/system_certificates.cppm
export {
namespace telar::runtime {

class SystemCertificates {
public:
  template <typename Consumer>
  inline static void read(Consumer &&consume) {
    for (const auto path : keychains) {
      readKeychain(path, consume);
    }
  }

private:
  using Resource = std::unique_ptr<const void, decltype(&CFRelease)>;

  template <typename Consumer>
  inline static void readKeychain(const char *path, Consumer &consume) {
    SecKeychainRef opened = nullptr;
    if (SecKeychainOpen(path, &opened) != errSecSuccess) {
      throw SystemError{"Open system certificate keychain", EACCES};
    }
    const Resource keychain{opened, &CFRelease};
    const void *search_items[]{opened};
    const Resource search{CFArrayCreate(kCFAllocatorDefault, search_items, 1, &kCFTypeArrayCallBacks), &CFRelease};
    if (!search) {
      throw std::bad_alloc{};
    }

    const void *keys[]{kSecClass, kSecMatchSearchList, kSecMatchLimit, kSecReturnRef, kSecUseAuthenticationUI};
    const void *values[]{kSecClassCertificate, search.get(), kSecMatchLimitAll, kCFBooleanTrue, kSecUseAuthenticationUISkip};
    const Resource query{CFDictionaryCreate(kCFAllocatorDefault, keys, values, std::size(keys), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks), &CFRelease};
    if (!query) {
      throw std::bad_alloc{};
    }

    CFTypeRef matched = nullptr;
    const auto status = SecItemCopyMatching(static_cast<CFDictionaryRef>(query.get()), &matched);
    const Resource result{matched, &CFRelease};
    if (status == errSecItemNotFound) {
      return;
    }
    if (status != errSecSuccess || !result || CFGetTypeID(result.get()) != CFArrayGetTypeID()) {
      throw SystemError{"Read system certificate keychain", EIO};
    }

    const auto certificates = static_cast<CFArrayRef>(result.get());
    for (CFIndex index = 0; index < CFArrayGetCount(certificates); ++index) {
      const auto item = CFArrayGetValueAtIndex(certificates, index);
      if (item == nullptr || CFGetTypeID(item) != SecCertificateGetTypeID()) {
        throw SystemError{"Invalid system certificate entry", EINVAL};
      }
      const auto certificate = static_cast<SecCertificateRef>(const_cast<void *>(item));
      const Resource encoded{SecCertificateCopyData(certificate), &CFRelease};
      if (!encoded) {
        throw std::bad_alloc{};
      }
      const auto data = static_cast<CFDataRef>(encoded.get());
      consume(std::span<const std::uint8_t>{CFDataGetBytePtr(data), static_cast<std::size_t>(CFDataGetLength(data))});
    }
  }

  static constexpr std::array<const char *, 2> keychains{
      "/System/Library/Keychains/SystemRootCertificates.keychain",
      "/Library/Keychains/System.keychain"};
};

}
}

#endif

// Interface: platform/system_certificates.cppm
export {
#if defined(__APPLE__)
#else
#endif
}
