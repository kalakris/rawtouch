# Security

RawTouch holds the Accessibility permission so that it can post scroll
events, and it reads reports from HID devices that claim to speak the
raw touch protocol. Anything that lets a device, a file, or another
process turn that into more than scrolling (posting other input,
reading input, running code) is a security problem worth reporting, as
is anything wrong with how releases are signed, notarized or attested.

## Reporting a vulnerability

Use **Report a vulnerability** on this repository's
[Security tab](https://github.com/kalakris/rawtouch/security), which
reaches the maintainer privately. Please do not open a public issue for
it. Include the RawTouch version (**About RawTouch**), your macOS
version, and how to reproduce.

This is a single-maintainer project; expect a reply within a week or so.

## Supported versions

Fixes go into the newest release only.

To check that a download is the one this repository built, see
[Verify a download](README.md#verify-a-download).
