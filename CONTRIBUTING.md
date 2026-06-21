# Contributing to GenieMax

Thanks for your interest! This project is a local-first, MIT-licensed health-analytics engine.

## Ground rules
- **Parity is the bar.** The algorithms are deterministic. Keep `swift test` green — a change that alters a golden
  value must update the fixture *with justification*, not silently.
- **No personal data, ever.** Don't commit real health records, API keys, tokens, account ids, or device identifiers.
  Test fixtures must be synthetic or time-shifted + de-identified.
- **No device-transport / connection code.** This package interprets data you already have; it is not a tool to
  connect to or control someone else's device. Keep that boundary.
- **Hygiene + clarity.** Match the surrounding style. Small, focused PRs. Explain *why* in the description.

## Workflow
1. Fork, branch from `main`.
2. `swift test` (and add tests for new behavior — golden vectors where output is deterministic).
3. Open a PR. CI runs the Swift suite + a secret scan.

## Reporting issues
Use GitHub Issues. For anything security-sensitive, follow [SECURITY.md](SECURITY.md) instead of a public issue.

This is wellness/experimental software, not a medical device. By contributing you agree your contributions are
licensed under the project's [MIT License](LICENSE).
