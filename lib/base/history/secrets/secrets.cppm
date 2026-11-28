export module telar.base.history.secrets;

import std;
import telar.base.ds;

export namespace telar::runtime {

  // What a secret found in a text is. A token is a key that stands for itself, as a provider
  // issues it (`ghp_…`, `sk-ant-…`, `AKIA…`); a structural secret is the part of a structure
  // that must not be kept: a URL's password, a private key's body, the value assigned to a
  // name like `*_TOKEN` or `password`.
  enum class SecretKind : std::uint8_t {
    token,
    structural,
  };

  struct SecretSpan {
    std::size_t begin = 0;
    std::size_t end = 0;
    SecretKind kind = SecretKind::token;
  };

  // The first secret at or after `from`, or none. The rules are fixed tables read in one pass
  // over the text, without allocating; a name is looked back at for at most 64 bytes.
  ds::Option<SecretSpan> findSecret(std::string_view text, std::size_t from = 0) noexcept;

  inline constexpr std::string_view secret_redaction = "[redacted]";

  struct SecretRedaction {
    // The bytes the redacted text took.
    std::size_t bytes = 0;
    // How many secrets were replaced, and how many of the text's bytes were tokens.
    std::size_t secrets = 0;
    std::size_t token_bytes = 0;
  };

  // `text` with each secret replaced by `[redacted]`, written into `out`; none when `out` cannot
  // hold it, which a caller treats as a text it cannot keep.
  ds::Option<SecretRedaction> redactSecrets(std::string_view text, std::span<char> out) noexcept;

}
