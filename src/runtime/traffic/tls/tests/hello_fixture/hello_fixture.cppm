export module telar.runtime.traffic.tls.tests.hello_fixture;

import std;
import telar.base.ds;

// ClientHello records built field by field, for the cases a TLS library would never send.
export namespace telar::runtime::tls_test {

  using Extension = std::pair<std::uint16_t, std::vector<std::uint8_t>>;

  inline void appendWord(std::vector<std::uint8_t>& output, std::size_t value) {
    output.push_back(static_cast<std::uint8_t>(value >> 8));
    output.push_back(static_cast<std::uint8_t>(value));
  }

  // A TLS 1.3 ClientHello record with one cipher suite and the extensions given.
  inline std::vector<std::uint8_t> helloRecord(std::span<const Extension> extensions) {
    std::vector<std::uint8_t> listed;

    for (const auto& [kind, body] : extensions) {
      appendWord(listed, kind);
      appendWord(listed, body.size());
      listed.insert(listed.end(), body.begin(), body.end());
    }

    std::vector<std::uint8_t> body{3, 3};

    body.resize(body.size() + 32, 0x5a);
    body.insert(body.end(), {0, 0, 2, 0x13, 0x01, 1, 0});
    appendWord(body, listed.size());
    body.insert(body.end(), listed.begin(), listed.end());
    std::vector<std::uint8_t> record{22, 3, 1};

    appendWord(record, body.size() + 4);
    record.insert(record.end(), {1, 0, static_cast<std::uint8_t>(body.size() >> 8), static_cast<std::uint8_t>(body.size())});
    record.insert(record.end(), body.begin(), body.end());
    return record;
  }

  // A server_name extension body listing each of `names` as a host_name entry.
  inline std::vector<std::uint8_t> serverNames(std::span<const std::string_view> names) {
    std::vector<std::uint8_t> entries;

    for (const auto name : names) {
      entries.push_back(0);
      appendWord(entries, name.size());
      entries.insert(entries.end(), name.begin(), name.end());
    }

    std::vector<std::uint8_t> extension;

    appendWord(extension, entries.size());
    extension.insert(extension.end(), entries.begin(), entries.end());
    return extension;
  }

  inline Extension serverName(std::string_view name) {
    const ds::Array names{name};

    return {0, serverNames(names)};
  }

  inline Extension protocols() {
    return {16, {0, 3, 2, 'h', '2'}};
  }

  // An encrypted_client_hello extension; its payload is never read.
  inline Extension encryptedHello() {
    return {0xfe0d, {0, 0, 1, 0, 1, 0x7f, 0, 0, 0, 0}};
  }

}
