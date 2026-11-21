module telar.remote.identity;

import telar.base.memory.sensitive;
import telar.base.text;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.sha256;
import telar.tbc;

namespace telar::remote {

  using runtime::FileDescriptor;
  using runtime::SystemError;

  namespace {

    constexpr std::string_view key_file = "identity-key.pem";
    constexpr std::string_view certificate_file = "identity-cert.pem";
    constexpr std::string_view clients_file = "authorized_clients";
    constexpr std::string_view pairing_file = "pairing";
    constexpr std::string_view port_file = "port";
    constexpr std::string_view certificate_name = "telar gateway";

    // The most a state file holds: every client or code on its line.
    constexpr std::size_t file_bytes = std::size_t{16} * 1024;

    using FileBytes = ds::Array<unsigned char, file_bytes>;

    // The text of a state file, read into `buffer`; empty when it does not exist.
    tbc::val_a<std::string_view> readText(int directory, std::string_view name, tbc::mut_a<FileBytes> buffer) {
      const auto opened = runtime::openPrivateFile(directory, name, buffer.size());
      if (!opened.file) {
        return {};
      }

      const auto bytes = buffer.viewMut().first(opened.size);

      runtime::readPrivateFileBytes(opened.file.get(), bytes);
      return std::string_view{reinterpret_cast<const char*>(bytes.data()), bytes.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the file's bytes are read as text
    }

    void writeText(int directory, std::string_view name, std::string_view text) {
      const std::span<const std::uint8_t> bytes{reinterpret_cast<const std::uint8_t*>(text.data()), text.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the text is written as the file's bytes
      if (const int error = runtime::writePrivateFile(directory, name, bytes, runtime::PrivateFileMode::replace)) {
        throw SystemError{"Write gateway state", error};
      }
    }

    // A fixed text that grows a piece at a time and says when one did not fit.
    template <std::size_t Capacity>
    class Writer {
    public:
      void append(std::string_view text) {
        if (text.size() > Capacity - length_) {
          throw std::length_error{"Gateway state exceeds its file"};
        }

        std::ranges::copy(text, bytes_.viewMut().subspan(length_).begin());
        length_ += text.size();
      }

      void appendNumber(std::uint64_t number) {
        constexpr std::size_t digits = 20;
        ds::Array<char, digits> text{};
        const auto end = std::to_chars(text.dataMut(), text.dataMut() + text.size(), number).ptr;

        append({text.data(), static_cast<std::size_t>(end - text.data())});
      }

      [[nodiscard]] std::string_view view() const noexcept {
        return {bytes_.data(), length_};
      }

    private:
      ds::Array<char, Capacity> bytes_{};
      std::size_t length_ = 0;
    };

    std::uint64_t now() noexcept {
      return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count());
    }

    PublicKey digestOf(const Secret& secret) noexcept {
      runtime::Sha256 hash;

      hash.update({reinterpret_cast<const char*>(secret.data()), secret.size()}); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the digest reads the secret's bytes
      return hash.finish();
    }

    // One pending code: the digest of its secret and the second it expires.
    struct Code {
      PublicKey digest{};
      std::uint64_t expires = 0;
    };

    struct Codes {
      ds::Array<Code, PairingCodes::maximum> rows;
      std::size_t count = 0;

      // The codes of `directory` that have not expired.
      static Codes load(int directory) {
        FileBytes buffer;
        runtime::TextFields lines{{.text = readText(directory, pairing_file, buffer), .delimiter = "\n"}};
        const auto current = now();
        Codes codes;

        while (const auto line = lines.next()) {
          const auto separator = line->find(' ');
          Code code;
          const auto expires = separator == std::string_view::npos ? ds::none : runtime::unsignedDecimal<std::uint64_t>(line->substr(separator + 1));
          if (!expires || *expires <= current || codes.count == codes.rows.size() || !parseHex(line->substr(0, separator), code.digest.viewMut())) {
            continue;
          }

          code.expires = *expires;
          codes.rows.atMut(codes.count++) = code;
        }

        return codes;
      }

      void save(int directory) const {
        Writer<file_bytes> text;

        for (const auto& code : std::span{rows}.first(count)) {
          const auto digest = keyText(code.digest);

          text.append({digest.data(), digest.size()});
          text.append(" ");
          text.appendNumber(code.expires);
          text.append("\n");
        }

        writeText(directory, pairing_file, text.view());
      }
    };

    // The characters a client's name keeps on its line; any other becomes a dash.
    bool nameCharacter(char byte) noexcept {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' || byte == '-';
    }

    bool hostCharacter(char byte) noexcept {
      return nameCharacter(byte) || byte == ':';
    }

    [[noreturn]] void invalidEndpoint() {
      throw std::invalid_argument{"Expected a gateway address, telar://HOST:PORT#KEY"};
    }

  }

  KeyText keyText(const PublicKey& key) noexcept {
    KeyText text{};

    static_cast<void>(runtime::encodeLowerHex(key.view(), text.viewMut()));
    return text;
  }

  SecretText secretText(const Secret& secret) noexcept {
    SecretText text{};

    static_cast<void>(runtime::encodeLowerHex(secret.view(), text.viewMut()));
    return text;
  }

  bool parseHex(std::string_view text, std::span<std::uint8_t> bytes) noexcept {
    constexpr int hexadecimal = 16;

    if (text.size() != bytes.size() * 2) {
      return false;
    }

    for (std::size_t index = 0; index < bytes.size(); ++index) {
      const auto digits = text.substr(index * 2, 2);
      const auto value = runtime::parseExact<std::uint8_t>(digits, hexadecimal);
      if (!value || digits.front() == '+' || digits.front() == '-') {
        return false;
      }

      bytes[index] = *value;
    }

    return true;
  }

  bool sameBytes(std::span<const std::uint8_t> left, std::span<const std::uint8_t> right) noexcept {
    if (left.size() != right.size()) {
      return false;
    }

    unsigned difference = 0;

    for (std::size_t index = 0; index < left.size(); ++index) {
      difference |= static_cast<unsigned>(left[index] ^ right[index]);
    }

    return difference == 0;
  }

  Endpoint Endpoint::parse(std::string_view text) {
    if (!text.starts_with(scheme)) {
      invalidEndpoint();
    }

    text.remove_prefix(scheme.size());
    const auto fragment = text.find('#');
    if (fragment == std::string_view::npos) {
      invalidEndpoint();
    }

    auto authority = text.substr(0, fragment);
    auto keys = text.substr(fragment + 1);
    Endpoint endpoint;
    std::string_view host = authority;
    std::string_view port;

    // An IPv6 address stands in brackets, so that its colons are not read as the port's.
    if (authority.starts_with('[')) {
      const auto closing = authority.find(']');
      if (closing == std::string_view::npos) {
        invalidEndpoint();
      }

      host = authority.substr(1, closing - 1);
      authority.remove_prefix(closing + 1);
      if (!authority.empty() && !authority.starts_with(':')) {
        invalidEndpoint();
      }

      port = authority.empty() ? authority : authority.substr(1);
    } else if (const auto colon = authority.rfind(':'); colon != std::string_view::npos) {
      host = authority.substr(0, colon);
      port = authority.substr(colon + 1);
    }

    if (host.empty() || host.size() > host_bytes || !std::ranges::all_of(host, hostCharacter)) {
      invalidEndpoint();
    }

    endpoint.host.assign(host);
    if (!port.empty()) {
      const auto number = runtime::unsignedDecimal<std::uint16_t>(port);
      if (!number || *number == 0 || port.contains('_')) {
        invalidEndpoint();
      }

      endpoint.port = *number;
    }

    const auto separator = keys.find('.');
    if (!parseHex(keys.substr(0, separator), endpoint.key.viewMut())) {
      invalidEndpoint();
    }

    if (separator != std::string_view::npos) {
      Secret secret{};
      if (!parseHex(keys.substr(separator + 1), secret.viewMut())) {
        invalidEndpoint();
      }

      endpoint.secret = secret;
    }

    return endpoint;
  }

  Endpoint::Text Endpoint::format() const {
    return write(true);
  }

  Endpoint::Text Endpoint::destination() const {
    return write(false);
  }

  Endpoint::Text Endpoint::write(bool with_secret) const {
    Writer<text_bytes> text;
    const bool bracketed = host.view().contains(':');
    const auto key_text = keyText(key);

    text.append(scheme);
    text.append(bracketed ? "[" : "");
    text.append(host.view());
    text.append(bracketed ? "]:" : ":");
    text.appendNumber(port);
    text.append("#");
    text.append({key_text.data(), key_text.size()});
    if (with_secret && secret) {
      const auto secret_text = secretText(*secret);

      text.append(".");
      text.append({secret_text.data(), secret_text.size()});
    }

    Text result;

    result.assign(text.view());
    return result;
  }

  State State::open(const runtime::EnvironmentSource& environment) {
    Writer<PATH_MAX - 1> path;

    if (const auto explicit_path = environment.lookup("TELAR_GATEWAY_STATE"); explicit_path.starts_with('/')) {
      path.append(explicit_path);
    } else {
      const auto found = runtime::cli::findXdgDirectory(environment, "XDG_STATE_HOME", "/.local/state");
      if (found.base.empty()) {
        throw SystemError{"Find the gateway state directory: set HOME or XDG_STATE_HOME", ENOENT};
      }

      path.append(found.base);
      path.append(found.suffix);
      path.append("/telar/gateway");
    }

    State state;

    state.path_.assign(path.view());
    runtime::createPrivateDirectory(state.path_.view());
    ds::Array<char, PATH_MAX> terminated{};

    std::ranges::copy(state.path_.view(), terminated.viewMut().begin());
    state.directory_.reset(::open(terminated.data(), runtime::combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC, O_NOFOLLOW))); // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    if (!state.directory_) {
      throw SystemError{"Open the gateway state directory"};
    }

    return state;
  }

  int State::directory() const noexcept {
    return directory_.get();
  }

  std::string_view State::path() const noexcept {
    return path_.view();
  }

  ds::Option<std::uint16_t> State::port() const {
    FileBytes buffer;
    const auto number = runtime::unsignedDecimal<std::uint16_t>(runtime::trimText(readText(directory_.get(), port_file, buffer), " \n"));

    return number && *number != 0 ? number : ds::none;
  }

  void State::recordPort(std::uint16_t port) const {
    Writer<port_file.size() + Endpoint::port_digits + 1> text;

    text.appendNumber(port);
    text.append("\n");
    writeText(directory_.get(), port_file, text.view());
  }

  Identity Identity::loadOrCreate(int directory) {
    constexpr unsigned attempts = 2;

    for (unsigned attempt = 0; attempt < attempts; ++attempt) {
      runtime::SensitiveBuffer<runtime::PemDocument::maximum_bytes> key_bytes;
      ds::Array<unsigned char, runtime::PemDocument::maximum_bytes> certificate_bytes{};
      const auto key = runtime::openPrivateFile(directory, key_file, runtime::PemDocument::maximum_bytes);
      const auto certificate = runtime::openPrivateFile(directory, certificate_file, runtime::PemDocument::maximum_bytes);
      if (key.file && certificate.file) {
        const auto key_span = std::span<std::uint8_t>{key_bytes.bytes()}.first(key.size);
        const auto certificate_span = certificate_bytes.viewMut().first(certificate.size);

        runtime::readPrivateFileBytes(key.file.get(), key_span);
        runtime::readPrivateFileBytes(certificate.file.get(), certificate_span);
        Identity identity{.pair = runtime::CertificatePair::parse(key_span, certificate_span)};

        identity.key = runtime::publicKeyDigest(identity.pair.certificate.get());
        return identity;
      }

      // The first gateway process of an account makes the identity; one that loses the race to
      // another reads what the winner published.
      const StateLock lock{directory};

      if (runtime::openPrivateFile(directory, certificate_file, runtime::PemDocument::maximum_bytes).file) {
        continue;
      }

      const auto pair = runtime::CertificatePair::selfSigned(certificate_name, runtime::CertificatePair::private_lifetime);
      const runtime::PemDocument key_document{pair.key.get()};
      const runtime::PemDocument certificate_document{pair.certificate.get()};

      if (const int error = runtime::writePrivateFile(directory, key_file, key_document.bytes(), runtime::PrivateFileMode::replace)) {
        throw SystemError{"Publish the gateway key", error};
      }

      if (const int error = runtime::writePrivateFile(directory, certificate_file, certificate_document.bytes(), runtime::PrivateFileMode::replace)) {
        throw SystemError{"Publish the gateway certificate", error};
      }
    }

    throw SystemError{"Read the gateway identity", EIO};
  }

  AuthorizedClients AuthorizedClients::load(int directory) {
    FileBytes buffer;
    runtime::TextFields lines{{.text = readText(directory, clients_file, buffer), .delimiter = "\n"}};
    AuthorizedClients clients;

    while (const auto line = lines.next()) {
      const auto separator = line->find(' ');
      Client client;
      if (clients.count_ == clients.rows_.size() || !parseHex(line->substr(0, separator), client.key.viewMut())) {
        continue;
      }

      const auto name = separator == std::string_view::npos ? std::string_view{} : line->substr(separator + 1);

      client.name.assign(name.substr(0, std::min(name.size(), name_bytes)));
      clients.rows_.atMut(clients.count_++) = client;
    }

    return clients;
  }

  bool AuthorizedClients::admits(const PublicKey& key) const noexcept {
    bool found = false;

    // Every row is compared, so the time taken does not say which one matched.
    for (const auto& client : rows()) {
      found = sameBytes(client.key.view(), key.view()) || found;
    }

    return found;
  }

  std::span<const AuthorizedClients::Client> AuthorizedClients::rows() const noexcept {
    return std::span{rows_}.first(count_);
  }

  void AuthorizedClients::admit(const PublicKey& key, std::string_view name) {
    ds::Array<char, name_bytes> clean{};
    const auto length = std::min(name.size(), clean.size());

    std::ranges::transform(name.substr(0, length), clean.viewMut().begin(), [](char byte) {
      return nameCharacter(byte) ? byte : '-';
    });

    const std::string_view cleaned{clean.data(), length};

    for (std::size_t index = 0; index < count_; ++index) {
      if (rows_[index].key == key) {
        rows_.atMut(index).name.assign(cleaned);
        return;
      }
    }

    if (count_ == rows_.size()) {
      throw std::length_error{"The gateway already admits as many clients as it keeps; revoke one first"};
    }

    Client client{.key = key};

    client.name.assign(cleaned.empty() ? std::string_view{"client"} : cleaned);
    rows_.atMut(count_++) = client;
  }

  std::size_t AuthorizedClients::revoke(std::string_view selector) noexcept {
    std::size_t kept = 0;
    const auto before = count_;

    for (std::size_t index = 0; index < before; ++index) {
      const auto text = keyText(rows_[index].key);
      if (selector == std::string_view{text.data(), text.size()} || selector == rows_[index].name.view()) {
        continue;
      }

      rows_.atMut(kept++) = rows_[index];
    }

    count_ = kept;
    return before - kept;
  }

  void AuthorizedClients::save(int directory) const {
    Writer<file_bytes> text;

    for (const auto& client : rows()) {
      const auto key = keyText(client.key);

      text.append({key.data(), key.size()});
      text.append(" ");
      text.append(client.name.view());
      text.append("\n");
    }

    writeText(directory, clients_file, text.view());
  }

  StateLock::StateLock(int directory)
      : file_(runtime::openLockFile(directory, "lock")) {
    if (!file_ || ::flock(file_.get(), LOCK_EX) != 0) {
      throw SystemError{"Lock the gateway state"};
    }
  }

  Secret PairingCodes::mint(int directory) {
    const StateLock lock{directory};
    auto codes = Codes::load(directory);
    if (codes.count == codes.rows.size()) {
      throw std::length_error{"Too many pairing codes are pending; wait for one to expire"};
    }

    Secret secret{};

    runtime::randomBytes(secret.dataMut(), secret.size());
    codes.rows.atMut(codes.count++) = {
        .digest = digestOf(secret),
        .expires = now() + static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(lifetime).count()),
    };

    codes.save(directory);
    return secret;
  }

  bool PairingCodes::redeem(int directory, const Secret& secret) {
    const StateLock lock{directory};
    auto codes = Codes::load(directory);
    const auto digest = digestOf(secret);
    std::size_t kept = 0;
    bool found = false;

    for (std::size_t index = 0; index < codes.count; ++index) {
      if (!found && sameBytes(codes.rows[index].digest.view(), digest.view())) {
        found = true;
        continue;
      }

      codes.rows.atMut(kept++) = codes.rows[index];
    }

    if (found) {
      codes.count = kept;
      codes.save(directory);
    }

    return found;
  }

}
