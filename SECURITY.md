# Security Policy

## Supported versions

Security fixes are provided for the latest published MoMoWhisper release. Older builds may no longer receive fixes.

## Reporting a vulnerability

Use GitHub Private Vulnerability Reporting or a private Security Advisory for this repository. If private reporting is unavailable, open a minimal public issue asking the maintainers for a private contact channel.

Do not include API keys, meeting audio, transcripts, customer names, private paths, or working exploit details in a public issue.

Please include:

- The affected MoMoWhisper version and operating-system version.
- The relevant feature and permission state.
- Reproduction steps using synthetic data.
- Expected and observed behavior.
- Your assessment of impact.

## Release safety

Download public builds only from this repository's GitHub Releases. A normal-distribution macOS build should be Developer ID signed, notarized by Apple, and accompanied by SHA-256 checksums. A Release may include an explicitly approved artifact labeled `unsigned` only as a Beta exception with checksums, an unambiguous Gatekeeper warning, and manual-open instructions. Such an artifact is ad-hoc signed, has not been screened by Apple's notary service, and must never be described as Apple-verified or production-ready. A checksum detects a mismatched download but does not establish publisher identity or software safety; never bypass a warning that says the app will damage the Mac or contains malware.

Windows packages are explicitly labeled Beta until Authenticode signing and Windows 10/11 compatibility verification are complete. Verify the published SHA-256 checksum before running an unsigned Beta and expect Microsoft Defender SmartScreen to identify an unknown publisher.

API keys are stored in macOS Keychain, but configured third-party endpoints remain outside the project's trust boundary. Users should verify endpoint ownership, TLS configuration, retention terms, and account security before sending meeting text.
