# Protocol Specification v3 — Curated Features

Curated by the spec-curator agent for the v3 revision cycle. Each entry traces
to the master backlog at `backlog/features.md`. Ordered by priority.

---

## Features

### F-1. Protocol version negotiation

**Priority:** high
**Origin:** from backlog entry F-2
**Description:** The protocol has no version negotiation mechanism. `PACKET_VERSION = 1` is hardcoded and version mismatch causes silent packet drops. As the protocol evolves past v2/v3, devices running different versions will silently fail to communicate. The minimum viable specification change is a version indicator in the room advertisement so scanners can filter incompatible rooms before connecting, plus a protocol version field in the `hello` payload enabling the host to reject incompatible clients with `join_rejected("incompatible_version")`. This feature was curated for the v2 cycle but not addressed; it becomes more urgent as the spec accumulates breaking changes.
**Spec impact:** Section 3.1 (Room Advertisement — version field or prefix change from `LB1`), Section 4.1 (Packet Envelope — version semantics), Section 4.3 (Control Message Types — hello payload extension, new join_rejected reason), Section 6.5 (HELLO Handshake — version validation step)

---

### F-2. App-level room scoping via app identifier

**Priority:** medium
**Origin:** from backlog entry F-1
**Description:** The room advertisement format (Section 3.1) contains no app identifier field. All applications sharing the BLE game network protocol discover each other's rooms during scanning. Room names are truncated to 8 bytes, making application-layer filtering impractical. The spec needs an app-scoping mechanism — either an app ID field in the advertisement (requiring a format revision), per-app GATT Service UUIDs, or an app ID parameter added to the `host()`/`scan()` API with native-layer filtering. This is a wire format change that should be coordinated with F-1 (version negotiation) to avoid two separate format revisions. This feature was curated for the v2 cycle but not addressed.
**Spec impact:** Section 3.1 (Room Advertisement encoding), Section 3.3 (Advertising), Section 3.4 (Discovery), Section 6.1 (Hosting — new parameter), Section 6.2 (Scanning — new filter)
