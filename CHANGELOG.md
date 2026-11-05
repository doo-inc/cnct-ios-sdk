# Changelog

## Unreleased — 0.1.0

- The foundation, matching the Flutter and web SDKs at 0.2.0: `Cnct`, `CnctConfig` (production
  `https://app.doo.ooo` by default, path prefixes kept, the socket origin derived), `CnctHosts`,
  `CnctChatPublicKey`, `CnctApiKey` with `CnctKeyMode` (sandbox / production), `CnctModule`,
  `CnctError` with the shared `CnctErrorCode` vocabulary, `CnctJSON`, `CnctTokenStore` with a memory
  store, and `CnctTransport` on URLSession.
- Credentials redact themselves in `print`, `po` and `dump`.
- Query values are encoded strictly, so a `+` in a phone number is not read as a space.
