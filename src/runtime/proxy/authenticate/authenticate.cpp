module telar.runtime.proxy.authenticate;

import telar.sys.posix;
import telar.base.memory.sensitive;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.base.ds;

namespace telar::runtime {

  ProxySecret ProxySecret::generate() noexcept {
    ProxySecret secret;

    randomBytes(secret.bytes_.dataMut(), secret.bytes_.size());
    return secret;
  }

  ds::Option<ProxySecret> ProxySecret::fromHexadecimal(std::string_view text) noexcept {
    if (text.size() != hexadecimal_bytes) {
      return ds::none;
    }

    ProxySecret secret;

    for (std::size_t index = 0; index < byte_count; ++index) {
      const auto high = digit(text[index * 2]);
      const auto low = digit(text[(index * 2) + 1]);
      if (!high || !low) {
        return ds::none;
      }

      secret.bytes_.atMut(index) = static_cast<std::uint8_t>((*high << 4) | *low);
    }

    return secret;
  }

  ProxySecret::~ProxySecret() {
    eraseSensitive(bytes_.dataMut(), bytes_.size());
  }

  bool ProxySecret::matches(const ProxySecret& other) const noexcept {
    volatile unsigned difference = 0;

    for (std::size_t index = 0; index < byte_count; ++index) {
      difference = difference | (bytes_[index] ^ other.bytes_[index]);
    }

    return difference == 0;
  }

  tbc::val_a<ds::Option<std::string_view>> ProxySecret::formatHexadecimal(tbc::val_a<std::span<char>> destination) const noexcept {
    if (destination.size() < hexadecimal_bytes) {
      return ds::none;
    }

    for (std::size_t index = 0; index < byte_count; ++index) {
      destination[index * 2] = hexadecimal[bytes_[index] >> 4];
      destination[(index * 2) + 1] = hexadecimal[bytes_[index] & 15];
    }

    return std::string_view{destination.data(), hexadecimal_bytes};
  }

  tbc::val_a<ds::Option<std::string_view>> ProxySecret::formatUrl(tbc::val_a<std::span<char>> destination, std::uint16_t port) const noexcept {
    constexpr std::string_view prefix = "http://telar:";
    constexpr std::string_view address = "@127.0.0.1:";
    constexpr std::size_t port_digits = 5;
    if (destination.size() < prefix.size() + hexadecimal_bytes + address.size() + port_digits) {
      return ds::none;
    }

    auto* end = std::copy(prefix.begin(), prefix.end(), destination.data());

    formatHexadecimal({end, hexadecimal_bytes});
    end += hexadecimal_bytes;
    end = std::copy(address.begin(), address.end(), end);
    end = std::to_chars(end, destination.data() + destination.size(), port).ptr;
    return std::string_view{destination.data(), static_cast<std::size_t>(end - destination.data())};
  }

  ProxySecret::ProxySecret() noexcept {}

  ds::Option<unsigned> ProxySecret::digit(char character) noexcept {
    const auto position = hexadecimal.find(asciiLower(character));

    return position == std::string_view::npos ? ds::none : ds::Option{static_cast<unsigned>(position)};
  }

  ds::Option<ProxySecret> ProxyAuthorization::parse(std::string_view head) noexcept {
    ds::Option<ProxySecret> secret;

    while (const auto value = next(head)) {
      if (secret) {
        return ds::none;
      }

      const auto authorization = trimText(*value, " \t");
      if (authorization.size() < 7 || !asciiEqualIgnoreCase(authorization.substr(0, 5), "basic") || authorization[5] != ' ') {
        return ds::none;
      }

      SensitiveBuffer<decoded_capacity> decoded;
      const auto length = base64::decode(trimText(authorization.substr(6), " \t"), decoded.bytes());
      if (!length || *length != userinfo_prefix.size() + ProxySecret::hexadecimal_bytes) {
        return ds::none;
      }

      const std::string_view userinfo{reinterpret_cast<const char*>(decoded.bytes().data()), *length};
      if (!userinfo.starts_with(userinfo_prefix)) {
        return ds::none;
      }

      secret = ProxySecret::fromHexadecimal(userinfo.substr(userinfo_prefix.size()));
      if (!secret) {
        return ds::none;
      }
    }

    return secret;
  }

  bool ProxyAuthorization::present(std::string_view head) noexcept {
    return next(head).hasValue();
  }

  ds::Option<std::string_view> ProxyAuthorization::next(std::string_view& head) noexcept {
    auto line_end = head.find("\r\n");
    if (line_end == std::string_view::npos) {
      head = {};
      return ds::none;
    }

    head.remove_prefix(line_end + 2);
    while (!head.empty()) {
      line_end = head.find("\r\n");
      const auto line = head.substr(0, line_end);
      const auto colon = line.find(':');
      if (colon != std::string_view::npos && asciiEqualIgnoreCase(line.substr(0, colon), "proxy-authorization")) {
        return line.substr(colon + 1);
      }

      head.remove_prefix(line_end == std::string_view::npos ? head.size() : line_end + 2);
    }

    return ds::none;
  }

  tbc::val_static<std::string_view> ProxyRejection::response() const noexcept {
    if (reason == Reason::invalid_target) {
      return "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
    }

    return "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"telar\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
  }

  template <Allocator Memory>
  tbc::val_a<ProxyDecision> authenticateProxy(const ProxySecret& secret, bool anonymous_tunnels, const ProxyHostPolicy<Memory>& policy, tbc::val_a<std::string_view> head) noexcept {
    if (anonymous_tunnels && !ProxyAuthorization::present(head)) {
      const auto target = ProxyTarget::parse(head);
      if (!target) {
        return ProxyRejection{ProxyRejection::Reason::invalid_target};
      }

      if (policy.contains(target->hostname)) {
        return ProxyRejection{ProxyRejection::Reason::invalid_authorization};
      }

      return ProxyAdmission{.target = *target, .authenticated = false};
    }

    const auto presented = ProxyAuthorization::parse(head);
    if (!presented) {
      return ProxyRejection{ProxyRejection::Reason::invalid_authorization};
    }

    if (!secret.matches(*presented)) {
      return ProxyRejection{ProxyRejection::Reason::unknown_credential};
    }

    const auto target = ProxyTarget::parse(head);
    if (!target) {
      return ProxyRejection{ProxyRejection::Reason::invalid_target};
    }

    return ProxyAdmission{.target = *target, .authenticated = true};
  }

  ds::Option<ProxySecret> ProxySecretFile::load(Memory& memory, int directory) {
    ErasingAllocator sensitive{memory};
    ds::Vec<unsigned char, decltype(sensitive)> bytes{sensitive};
    if (!readPrivateFile(directory, filename, bytes, maximum_file_bytes)) {
      return ds::none;
    }

    std::string_view text{reinterpret_cast<const char*>(bytes.data()), bytes.size()};

    while (!text.empty() && (text.back() == '\r' || text.back() == '\n')) {
      text.remove_suffix(1);
    }

    const auto secret = ProxySecret::fromHexadecimal(text);
    if (!secret) {
      throw SystemError{"Invalid proxy secret", EINVAL};
    }

    return secret;
  }

  template <Allocator Memory>
  ProxySecret ProxySecretFile::ensure(Memory& memory, int directory) {
    if (const auto existing = load(memory, directory)) {
      return *existing;
    }

    const auto secret = ProxySecret::generate();
    SensitiveBuffer<ProxySecret::hexadecimal_bytes + 1> line;

    secret.formatHexadecimal({reinterpret_cast<char*>(line.bytes().data()), ProxySecret::hexadecimal_bytes});
    line.bytes().back() = '\n';
    const auto failure = writePrivateFile(directory, filename, line.bytes(), PrivateFileMode::create_only);
    if (failure != 0) {
      throw SystemError{"Create proxy secret", failure};
    }

    return secret;
  }

  template tbc::val_a<ProxyDecision> authenticateProxy<Memory>(const ProxySecret& secret, bool anonymous_tunnels, const ProxyHostPolicy<Memory>& policy, tbc::val_a<std::string_view> head) noexcept;
  template tbc::val_a<ProxyDecision> authenticateProxy<ConcurrentMemory>(const ProxySecret& secret, bool anonymous_tunnels, const ProxyHostPolicy<ConcurrentMemory>& policy, tbc::val_a<std::string_view> head) noexcept;
  template ProxySecret ProxySecretFile::ensure<Memory>(Memory& memory, int directory);
  template ProxySecret ProxySecretFile::ensure<ConcurrentMemory>(ConcurrentMemory& memory, int directory);

}
