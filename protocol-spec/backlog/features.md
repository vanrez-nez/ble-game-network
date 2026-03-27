# Protocol Specification — Master Features Backlog

Living document maintained by the spec-issues agent. Contains all known
feature requests and enhancements sourced from GitHub issues and codebase
analysis. Items here are unfiltered — the spec-curator agent selects which
ones enter a revision cycle.

---

## Features

<!-- Entries are added and updated by the spec-issues agent. -->

### F-1. App-level room scoping via app identifier

**Source:** GitHub issue #2 — Room discovery has no app-level scoping — different apps see each other's rooms
**Status:** new
**Priority:** high
**Origin:** feature request
**Summary:** The room advertisement format (Section 3.1) contains no app identifier field. All applications sharing the BLE game network protocol discover each other's rooms during scanning. Room names are truncated to 8 bytes, making Lua-layer filtering impractical. The spec needs an app-scoping mechanism — either an app ID field in the advertisement (requiring a format revision, e.g., `LB2` prefix), per-app GATT Service UUIDs, or an app ID parameter added to the `host()`/`scan()` API with native-layer filtering. This is a new protocol field that changes the wire format.
**Spec sections affected:** Section 3.1 (Room Advertisement encoding), Section 3.3 (Advertising), Section 3.4 (Discovery), Section 6.1 (Hosting — new parameter), Section 6.2 (Scanning — new filter)

---

### F-2. Protocol version negotiation

**Source:** GitHub issue #6 — feat: protocol version negotiation for room compatibility checks
**Status:** new
**Priority:** high
**Origin:** feature request
**Summary:** The protocol has no version negotiation mechanism. `PACKET_VERSION = 1` is hardcoded and version mismatch causes silent packet drops with no error event. As the protocol evolves, devices running different versions will silently fail to communicate. The feature has three tiers: (1) a version indicator in the room advertisement so scanners can filter incompatible rooms before connecting; (2) a protocol version field in the `hello` payload enabling the host to reject incompatible clients with `join_rejected("incompatible_version")`; (3) longer-term capability flags for feature-level negotiation between minor versions. Tier 1 requires a change to the advertisement wire format; tier 2 extends the hello payload; tier 3 is a new handshake extension.
**Spec sections affected:** Section 3.1 (Room Advertisement — version field), Section 4.1 (Packet Envelope — version semantics), Section 4.3 (Control Message Types — hello payload extension, new join_rejected reason), Section 6.5 (HELLO Handshake — version validation step)
