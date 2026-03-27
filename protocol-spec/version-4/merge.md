# Protocol Specification v4 -- Consolidated Merge Document

**Baseline:** Protocol Specification v3.0.0
**Input Documents:** Proposal A, Proposal B
**Date:** 2026-03-27
**Role:** Referee (neutral consolidation from first principles)

---

## Governing Principles Applied

1. **Stability over features.** Proposed changes were evaluated for whether they reduce failure modes and ambiguity rather than whether they add capability. Features were accepted only where they prevent a class of failures.
2. **Architecture before implementation.** Where a structural change eliminates the need for downstream patches, the structural change was preferred. Where both proposals addressed the same concern from different angles, the more fundamental approach was selected.
3. **Merge when strictly better.** Proposals were combined only where the result is cleaner or more general than either alone.

---

## Glossary Additions

| Term | Definition |
|------|-----------|
| **Recovery Host Probe** | A bounded scan period inserted before a self-elected successor commits to the host role during unexpected host recovery, used to detect whether the old host is still advertising. |
| **Split-Brain** | A state where two or more devices simultaneously operate as host for the same session ID, each unaware of the other, resulting in divergent rosters and irreconcilable message routing. |
| **Liveness Check** | Any mechanism by which a disconnected client determines whether the host it lost contact with is still operational before initiating recovery procedures that create a new host. |
| **recoveryHostProbeActive** | A boolean indicating that the self-elected recovery successor is currently scanning for the old host's advertisement before committing to the host role. Set to true at probe start, cleared when the probe resolves (old host found, another successor found, or timeout). |
| **Protocol Version** | The major version of the BLE Game Network Protocol, encoded as a single ASCII digit in the Room Advertisement prefix and optionally in the HELLO payload. Used for pre-connection compatibility detection. |

---

## Accepted Changes

### Change 1: Reconnect-Before-Recovery Ordering with Recovery Host Probe

**Objective:** Eliminate the class of split-brain states caused by transient BLE disconnects on Resilient transport, where the host is still alive but a disconnected client unilaterally creates a second host.

**Problem:** Section 13 (Client Disconnect Decision Tree) step 6 routes Resilient-transport disconnects through `BeginUnexpectedHostRecovery()` before step 7 `BeginClientReconnect()`. Because `SelectRecoverySuccessor()` always has at least the local peer as a candidate (Section 8.2 step 3 adds self), `BeginUnexpectedHostRecovery()` always returns true, making step 7 unreachable for Resilient transport. On a transient BLE drop where the host is still alive, the disconnected client unilaterally elects a successor, starts a GATT server, and advertises the same session ID -- creating a persistent split-brain. The Android implementation has independently deployed a partial, unspecified mitigation (a recovery host probe) that iOS lacks.

**Specification changes:**

**1a. Reverse Section 13 steps 6 and 7:**

The disconnect decision tree MUST attempt reconnection before host recovery for all transports. This eliminates the unreachable code path and ensures the less destructive action (reconnect to existing host) is tried before the more destructive action (create a new host).

```
FUNCTION OnClientDisconnected() -> void
  [steps 1-5 unchanged]

  6. If shouldEmit is true AND wasJoined is true:
     6a. Call BeginClientReconnect().
     6b. If successful, return.
  7. If shouldEmit is true AND wasJoined is true AND transport is Resilient:
     7a. Call BeginUnexpectedHostRecovery().
     7b. If successful, return.
  [steps 8-9 unchanged]
```

**1b. Add recovery escalation to OnReconnectTimeout for Resilient transport:**

When reconnect times out on Resilient transport, escalate to host recovery rather than failing the session immediately. This is the mechanism by which recovery is reached after reconnect fails.

```
FUNCTION OnReconnectTimeout() -> void

  1. If transport is Resilient:
     1a. Cancel Reconnect Timeout.
     1b. Clear reconnect scan state fields (but preserve session info
         and roster for recovery).
     1c. Stop scan.
     1d. Call BeginUnexpectedHostRecovery().
     1e. If successful, return.
     1f. If recovery fails, fall through to step 2.
  2. Call FailReconnect().
```

**1c. Add Recovery Host Probe to Section 8.2 `BeginUnexpectedHostRecovery`:**

When a self-elected successor would begin hosting, it MUST first scan for the old host's advertisement. This is the final defense against split-brain for the case where the disconnected client elected itself and reconnect timed out (e.g., the host was briefly unreachable but recovered during the reconnect window).

```
FUNCTION BeginUnexpectedHostRecovery() -> bool
  [steps 1-7 unchanged]

  7a. If becomingHost is true:
      7a-i.   Set recoveryHostProbeActive = true.
      7a-ii.  Start BLE scan for Recovery Host Probe Duration
              (default 1.5s, Section 17).
      7a-iii. On each scan result during probe:
              - If room.sessionId matches current session AND
                room.hostPeerId matches the old host's Peer ID:
                  -> The old host is still alive.
                  -> Set recoveryHostProbeActive = false.
                  -> Cancel probe timer. Stop scan.
                  -> Clear migration state.
                  -> Attempt BeginClientReconnect() to the old host.
                  -> If reconnect begins, return true.
                  -> If reconnect fails, proceed to step 8 (start hosting).
              - If room.sessionId matches current session AND
                room.hostPeerId matches a different known session member:
                  -> Another peer has already become successor.
                  -> Set recoveryHostProbeActive = false.
                  -> Accept this peer as successor
                     (per Section 8.4 step 3 convergence rule).
                  -> Return true.
              - Otherwise: ignore (not relevant).
      7a-iv.  On probe timer expiry:
              -> Old host not found. Proceed to step 8.
              -> Set recoveryHostProbeActive = false.

  8. [existing step 8: Call StartMigration(info).]
  [steps 9-11 unchanged]
```

**1d. New constant in Section 17:**

| Constant | Default | Purpose |
|----------|---------|---------|
| Recovery Host Probe Duration | 1.5s | Max time a self-elected successor scans for the old host before committing to the host role |

**Rationale:** Both proposals identified the same root cause and agreed that a recovery host probe is necessary. They diverged on the architectural approach: Proposal A placed the probe in `BeginMigrationReconnect()` while leaving Section 13's step ordering unchanged; Proposal B reversed the step ordering in Section 13 and placed the probe in `BeginUnexpectedHostRecovery()`. Proposal B's approach is architecturally superior because it eliminates the root cause (an unreachable code path) rather than mitigating a symptom. Reversing the step ordering makes both steps reachable and ensures the less destructive action (reconnect) is attempted first. The probe is then a secondary defense for the specific case where a self-elected successor would create a second host. The 1.5-second probe duration (Proposal B) was chosen over the 3-second migration timeout reuse (Proposal A) because it is purpose-built and shorter, reducing latency in the genuine host-loss case.

**Known tradeoffs:**
- Increased recovery latency in the genuine host-loss case: up to 10s (reconnect timeout) + 1.5s (probe) before the successor begins hosting.
- The probe is advertisement-based, not connection-based. A host that has stopped advertising but is still serving connected clients will not be detected. This is acceptable because a non-advertising host is functionally unreachable for reconnection.
- v3 clients in a mixed session will use the old ordering (recovery before reconnect). The probe mitigates this for self-elected successors regardless of ordering.

**Traces to:** Curated issue I-1 (critical), backlog I-9, Proposal A Item 1, Proposal B Items 1 and 5.

---

### Change 2: Graceful Migration Must Remove Old Host from Successor's Roster

**Objective:** Eliminate stale-peer entries that persist indefinitely after graceful migration, where the departed old host remains in the roster with no mechanism for removal.

**Problem:** Section 8.2 (Unexpected Host Recovery) step 3 explicitly removes the old host from the roster, but Section 8.4 `BeginHostingMigratedSession` has no equivalent step. The old host's peer entry persists forever: no `peer_left` event is emitted, no timeout applies, and `session_resumed` includes the departed peer. Both implementations have independently corrected this (iOS and Android both remove the old host in their graceful migration hosting paths).

**Specification change:**

Add an old-host removal step to `BeginHostingMigratedSession` (Section 8.4) as the first operation, before the GATT server is started:

```
FUNCTION BeginHostingMigratedSession(migrationInfo) -> void

  1. Remove the old host's Peer ID from the Session Peer roster.
     Increment membershipEpoch. If the old host's Peer ID is not in the
     roster, this is a no-op (idempotent with Section 8.2 step 3 for
     paths that already performed the removal).
  2. Start GATT server with migrated session info
     (sessionId, roomName, maxClients, membershipEpoch).
  2a. Cancel the migration timeout scheduled by BeginMigrationReconnect().
      The successor is now hosting; the migration timeout applies
      to the reconnecting-client path, not the hosting path.
  3. Set migrationAcceptanceActive = true.
  4. Begin advertising the room.
  5. Start Heartbeat timer.
  6. Emit hosted event.
  7. Schedule Migration Acceptance Window timer (default 3s, Section 17).
  8. On Migration Acceptance Window expiry:
     8a. Set migrationAcceptanceActive = false.
     8b. Any subsequent join with intent="migration_resume" is
         rejected with "migration_mismatch" per Section 6.5 step 3e.

ERRORS:
  - GATT server fails to start -> emit error, session is lost.
  - No peers connect within acceptance window -> window expires,
    host continues operating with current roster. Peers arriving
    later with fresh join intent are accepted normally.
  - Old host Peer ID not found in roster -> no-op for removal.
```

Additionally, update `CompleteMigrationResume` (Section 8.5) to note that the `peers` field in the `session_resumed` event MUST NOT include the old host, as it should already have been removed by this point.

**Rationale:** Both proposals identified the same gap and proposed the same fix. The unexpected and graceful migration paths have the same requirement (old host must be removed from roster when successor begins hosting), but only the unexpected path specifies it. This is a one-step documentation correction that aligns the spec with both implementations and with the behavior already required by the unexpected recovery path. Removal is placed as step 1 (before GATT server start) to ensure the roster is clean before any new hosting operations.

**Known tradeoffs:** None. This is a parity fix. The old host has departed; removing it from the roster is the correct representation.

**Traces to:** Curated issue I-2 (major), backlog I-8, Proposal A Item 2, Proposal B Item 2.

---

### Change 3: Simplify `shouldEmit` Derivation -- Extract Callback Routing Requirement

**Objective:** Align the `shouldEmit` derivation in Section 13 with how both implementations actually achieve correctness, by separating the callback-routing concern from the decision-tree logic.

**Problem:** Section 13 steps 3b and 3c define device-identity guards within the `shouldEmit` derivation: if a reconnect or migration join is in progress and the disconnected device does not match the current join target, `shouldEmit` is set to false. Neither implementation follows this derivation. Both platforms (Android via `gatt == clientGatt` check; iOS via `peripheral != _connectedPeripheral` check) filter stale disconnect callbacks at the callback routing level, before the decision tree is ever entered. The spec-level guards are redundant when callback routing is correct, and no implementor has adopted them.

**Specification changes:**

**3a. Add a callback-level routing REQUIREMENT above the Section 13 decision tree:**

> REQUIREMENT: The implementation MUST ensure that `OnClientDisconnected()` is only invoked for the device currently associated with the active client connection. Disconnect callbacks for stale devices (from previous connections, prior to `StopClientOnly()` cleanup) MUST be discarded at the callback routing level. This may be achieved by comparing the callback's device handle against the current client GATT reference, or by any equivalent mechanism that produces the same filtering.

**3b. Simplify the `shouldEmit` derivation to:**

```
  3. Derive shouldEmit:
     3a. If clientLeaving is true -> shouldEmit = false.
     3b. Else -> shouldEmit = true.
```

Remove steps 3b and 3c from the current decision tree. Update the "Key invariants" note to remove the reference to device-identity guards within `shouldEmit` and instead reference the callback routing REQUIREMENT.

**Rationale:** The device-identity guards in steps 3b/3c solve a real problem (stale disconnect callbacks from previous connections), but they solve it at the wrong abstraction layer. Both implementations correctly solve it at the callback routing layer, where device identity is naturally available and filtering is cheaper and more reliable. Extracting the requirement and simplifying the derivation aligns the spec with how both implementations actually achieve correctness, without losing the safety guarantee.

**Known tradeoffs:** An implementation that cannot filter at the callback routing level would lose the safety net of steps 3b/3c. No known BLE platform delivers anonymous disconnect callbacks, so this is a theoretical concern.

**Traces to:** Proposal A Item 3 (unique to Proposal A).

---

### Change 4: Replace `connectionFailureHandled` Flag with Platform-Concern Requirement

**Objective:** Remove a prescribed mechanism that no implementation uses, while preserving the safety requirement it was designed to enforce.

**Problem:** Section 13 step 1 defines a `connectionFailureHandled` guard flag; Section 6.3 step 8a sets it. The intent is to prevent dual delivery on platforms where a GATT connection failure is delivered as both a connection failure event and a disconnect callback. Neither implementation has this field. Android achieves correctness through handler-thread serialization. iOS has no dual-delivery concern (separate callback structures). The flag prescribes a mechanism that is unnecessary on both platforms.

**Specification changes:**

**4a. Remove `connectionFailureHandled` from Section 13 step 1 and Section 6.3 step 8a.**

**4b. Replace with a REQUIREMENT block:**

> REQUIREMENT: On platforms where GATT connection failure may be delivered as both a connection failure event and a subsequent disconnect callback, the implementation MUST ensure that the disconnect decision tree (Section 13) does not process the same underlying failure event twice. This may be achieved by a guard flag, by callback-level deduplication, by thread serialization that allows the first handler to modify state before the second fires, or by any equivalent mechanism. The specific mechanism is implementation-defined.

**4c. Simplify the existing REQUIREMENT at the end of Section 6.3 to reference the new REQUIREMENT rather than prescribing the flag.**

**Rationale:** The `connectionFailureHandled` flag solves a real platform concern but prescribes a mechanism that neither platform uses. Mandating an unused flag degrades the spec's credibility. Replacing it with a platform-concern statement preserves the safety requirement while allowing each platform to use its natural correctness mechanism.

**Known tradeoffs:** The spec no longer provides a reference mechanism for the dual-delivery guard. Implementors on new platforms must design their own solution. The REQUIREMENT block alerts them to the concern.

**Traces to:** Proposal A Item 4 (unique to Proposal A).

---

### Change 5: Strengthen "First Advertiser Wins" Normative Language

**Objective:** Ensure the migration convergence rule is implemented uniformly across all migration paths and platforms, preventing session-loss failures caused by partial implementations.

**Problem:** Section 8.4 `OnScanResultDuringMigration` step 3 defines the "first advertiser wins" rule as the primary convergence mechanism for divergent successor elections. iOS does not implement step 3 (it only accepts the exact elected successor). Android implements step 3 only during unexpected host recovery, not during graceful migration. The rule is the only convergence mechanism the protocol has; without uniform implementation, divergent elections produce permanent session splits.

**Specification change:**

Strengthen `OnScanResultDuringMigration` step 3 with explicit preconditions and a normative requirement:

```
FUNCTION OnScanResultDuringMigration(room) -> void

  1. If room.sessionId does not match the current session ID, ignore.
  2. If room.hostPeerId matches the locally elected successor:
     2a. Connect to room with migrationJoin=true.
  3. Else if room.hostPeerId is a known session member
     (present in the local roster at time of host loss):
     3a. Accept this peer as the new successor.
     3b. Update migration info with new successor identity.
     3c. Connect to room with migrationJoin=true.
  4. Else: ignore (unknown advertiser, not a session member).

REQUIREMENT: Step 3 MUST be evaluated on all migration scan paths,
including both graceful migration (triggered by session_migrating)
and unexpected host recovery (triggered by host loss detection).
The distinction between graceful and unexpected migration does not
affect the convergence rule. An implementation that evaluates step 3
only on one path violates this requirement. This is a correctness
requirement for the migration protocol's convergence guarantee,
not an optimization.

ERRORS:
  - Connection to accepted successor fails -> resume scan.
    Migration timeout still applies.
```

**Rationale:** Both proposals identified the same gap and agreed on strengthening the normative language. Proposal B's version was preferred because it adds explicit preconditions (step 3 applies to both graceful and unexpected paths) and a clear statement that omitting step 3 constitutes a protocol violation. The spec already defines this behavior; this change makes it unambiguous that partial implementation is non-compliant.

**Known tradeoffs:** Step 3 is primarily a safety net for graceful migration (the departing host designates the successor, so divergent elections should be rare). Making it mandatory adds minimal implementation cost (one additional conditional in the scan handler).

**Traces to:** Proposal A Item 8, Proposal B Item 4, backlog I-10.

---

### Change 6: Protocol Version Negotiation

**Objective:** Prevent cross-version connection failures by enabling pre-connection version detection in the Room Advertisement and definitive version rejection during the HELLO handshake.

**Problem:** The Room Advertisement uses a hardcoded `"LB1"` prefix with no version semantics. The Packet Envelope defines `Version = 1` with silent drop on mismatch, but there is no mechanism for a scanner to determine protocol compatibility before connecting, and no mechanism for a host to reject a client based on protocol version. As the protocol evolves through breaking changes (v2 -> v3 -> v4), incompatible clients waste BLE resources connecting to hosts they cannot interoperate with.

**Specification changes:**

**6a. Room Advertisement (Section 3.1):**

Change the prefix from `"LB1"` to `"LB"` followed by a single ASCII digit representing the major protocol version. For v4, the prefix is `"LB4"`.

```
Offset  Length  Field
0       2       Prefix          "LB" (literal)
2       1       ProtoVersion    ASCII digit: major protocol version ('4' for v4)
3       6       SessionID       6-char hex
9       6       HostPeerID      6-char hex
15      1       Transport       'r' = Reliable, 's' = Resilient
16      1       MaxClients      ASCII digit '1'-'7'
17      1       PeerCount       ASCII digit '0'-'9'
18      0-8     RoomName        UTF-8, variable length
```

Total: 18-26 bytes (unchanged).

**6b. Discovery (Section 3.4):**

`DecodeRoom` checks for prefix `"LB"` and extracts the version digit. Rooms with an unrecognized protocol version are still reported to the application (for display purposes) but flagged as `incompatible = true`. The `room_found` event (Section 12) gains a `proto_version` field (integer).

```
FUNCTION DecodeRoom(advertisementData) -> Room or null

  1. Extract candidate payload string per platform (manufacturer data,
     service data, or local name).
  2. If payload does not start with "LB", return null.
  3. Let protoVersion = parseInt(payload[2]).
     If not a digit, return null.
  4. If payload length < 18, return null.
  5. Decode remaining fields per Section 3.1 layout (offset 3 onward).
  6. If protoVersion != CURRENT_PROTOCOL_VERSION:
     set room.incompatible = true.
  7. Return Room with all fields including protoVersion.

ERRORS:
  - Malformed payload -> return null.
```

**6c. HELLO payload (Section 4.3):**

Extend the HELLO payload to include a protocol version field:

```
session_id|join_intent|proto_version
```

Where `proto_version` is a decimal integer string (e.g., `"4"`). For backward compatibility, a missing third field is treated as version 1.

**6d. HELLO validation (Section 6.5):**

Add a validation step after step 3e:

```
3f. If proto_version is present and does not match the host's
    protocol version: send join_rejected("incompatible_version")
    to device, disconnect device, return.
```

Add `"incompatible_version"` to the `join_rejected` reasons table in Section 4.3.

**6e. Event update (Section 12):**

Add `proto_version` (integer) to the `room_found` event fields.

**Rationale:** Version negotiation prevents the most common cross-version failure: a client discovering and attempting to join an incompatible host. The advertisement-level indicator enables pre-connection filtering; the HELLO-level field provides definitive rejection. This is an architectural change that eliminates a class of failures, not a feature addition. The wire format is unchanged in size (the prefix was already 3 bytes). This feature has been carried since the v2 cycle (F-1) and is well-motivated now that v4 introduces breaking behavioral changes (reconnect-before-recovery ordering, probe mechanism).

**Known tradeoffs:**
- **Breaking change:** `"LB4"` prefix means v3 scanners will not recognize v4 rooms (they check for `"LB1"`). This is intentional: v3 and v4 are not interoperable due to the behavioral changes in this revision.
- Single-digit version space (0-9) is sufficient for foreseeable evolution.
- A v4 host rejecting a v1 client on version mismatch is a behavior change from v3.

**Traces to:** Curated feature F-1, Proposal A Item 9.

---

### Change 7: BLE Availability Check -- Replace Undefined Assertion

**Objective:** Replace the undefined "Assert BLE is available and permissions granted" with a testable procedure that produces consistent behavior across implementations.

**Problem:** Sections 6.1, 6.2, and 6.3 begin with "Assert BLE is available and permissions granted" without defining what permissions are required, what "available" means, how to handle denial, or whether checks are per-operation or upfront. This was explicitly deferred in v3 (changelog item 10). The ambiguity has caused crashes on Android 12+ where runtime permissions must be explicitly granted.

**Specification changes:**

**7a. Add Section 6.0: BLE Availability Check:**

```
FUNCTION AssertBleAvailable(operation) -> bool

  1. Query the platform BLE radio state.
  2. If state is "unsupported":
     2a. Emit error("ble_unavailable", "BLE hardware not available").
     2b. Return false.
  3. If state is "off":
     3a. Emit radio event with state "off".
     3b. Emit error("ble_unavailable", "Bluetooth is turned off").
     3c. Return false.
  4. If state is "unauthorized":
     4a. Emit radio event with state "unauthorized".
     4b. Emit error("ble_unavailable", "Bluetooth permission denied").
     4c. Return false.
  5. If state is "resetting":
     5a. Emit error("ble_unavailable", "Bluetooth is resetting").
     5b. Return false.
  6. Return true.

ERRORS:
  - Platform does not expose radio state -> treat as available
    (proceed optimistically; failures will surface at GATT level).
```

Platform-specific permission categories (informative, not normative):

| Category | Android | iOS |
|----------|---------|-----|
| Scan | `BLUETOOTH_SCAN` (API 31+) or `ACCESS_FINE_LOCATION` (API < 31) | Automatic with `CBCentralManager` |
| Connect | `BLUETOOTH_CONNECT` (API 31+) or `BLUETOOTH` (API < 31) | Automatic with `CBCentralManager` |
| Advertise | `BLUETOOTH_ADVERTISE` (API 31+) or `BLUETOOTH` (API < 31) | Automatic with `CBPeripheralManager` |

The normative requirement is that `AssertBleAvailable()` returns false and emits an error event when the radio state precludes the requested operation. How the platform determines that state is implementation-defined.

**7b. Update Sections 6.1, 6.2, and 6.3 step 1:**

Replace "Assert BLE is available and permissions granted" with:

> 1. Call AssertBleAvailable("host" | "scan" | "join"). If false, return.

**7c. Add `"resetting"` to the `radio` event state values in Section 12:**

The `radio` event state set becomes: `"on"`, `"off"`, `"unauthorized"`, `"unsupported"`, `"resetting"`.

**7d. Add `"ble_unavailable"` to the error codes table in Section 12:**

| Code | Detail | Context |
|------|--------|---------|
| `ble_unavailable` | Descriptive string per AssertBleAvailable | BLE radio state precludes the requested operation |

**Rationale:** This replaces an undefined assertion with a testable procedure. Two implementors reading this will produce compatible behavior: both check radio state, both emit the same error event structure, both return false on the same conditions. The platform-specific permission details remain informative because they change with OS versions and cannot be normatively specified without creating a maintenance burden. Permission request flows (how to prompt the user) are intentionally excluded -- that is application-level UX, not protocol-level behavior.

**Known tradeoffs:**
- Does not define permission request flows. The protocol layer detects denial and surfaces it; requesting permissions is application-specific.
- The `"resetting"` state is new (not in v3's radio event). Both iOS and Android have transient states that map to it. Adding it closes a gap where a transient radio state would fall through to "available."

**Traces to:** Curated issue I-3 (minor), backlog I-6, Proposal B Item 6.

---

## Rejected Changes

### Rejected: `client_leaving` Implementation Status Notes (Proposal A Item 5, Proposal B Item 3)

**What was proposed:** Both proposals identified that the `client_leaving` departure message (v3 Change 2) is fully specified but not implemented on either platform. Proposal A proposed adding informative notes to the affected sections. Proposal B proposed a new Section 18 ("Implementation Compliance Notes") tracking all unimplemented v3 mechanisms.

**Rejection reason: Architectural mismatch.** A protocol specification defines normative requirements. Whether implementations comply is a separate concern tracked in the issue backlog and GitHub issues. Adding implementation status tracking to the spec document mixes concerns: the spec's authority comes from defining what MUST be done, not from tracking what HAS been done. The `client_leaving` mechanism is correctly specified, correctly designed, and carries backward compatibility. The implementation gap is an implementation concern, not a specification gap. Both the master backlog (I-1 resolution note) and GitHub issue #1 already track this gap. No spec change is warranted.

---

### Rejected: Implementation Compliance Section (Proposal B Item 3, Section 18 portion)

**What was proposed:** A new Section 18 cataloging all v3-specified mechanisms not yet implemented on either platform, including `client_leaving`, application lifecycle integration, and `migrationAcceptanceActive`.

**Rejection reason: Architectural mismatch.** Same reasoning as above. A specification is not an implementation tracker. Mixing normative language with implementation status degrades the spec's role as a standard. The backlog and issue tracker serve this function.

---

### Rejected: iOS `FinishLeave` vs. `FinishLeaveClient` Divergence (Proposal A Item 6)

**What was proposed:** Document the iOS implementation's use of full `FinishLeave()` where the spec calls for `FinishLeaveClient()`.

**Rejection reason: Redundancy.** The proposal itself states "No specification change needed. The v3 specification correctly defines `FinishLeaveClient()` and its call sites." The spec is correct and unambiguous. Implementation bugs are not spec items.

---

### Rejected: Weaken `migrationAcceptanceActive` to SHOULD (Proposal A Item 7)

**What was proposed:** Add an informative note to Section 8.4 changing the Migration Acceptance Window from an implicit MUST to a SHOULD, on the grounds that neither platform has implemented it and the reconnect timeout provides a practical fallback.

**Rejection reason: Stability -- weakening normative language degrades the spec's authority.** The Migration Acceptance Window is a correctly designed defense-in-depth mechanism. The fact that implementations have not caught up is not a reason to relax the requirement. The spec should define the correct behavior; implementations should converge toward it. Weakening to SHOULD signals that the mechanism is optional, which it is not if the protocol is to have bounded migration-resume acceptance.

---

### Rejected: App-Level Room Scoping via App Identifier (Proposal A Item 10)

**What was proposed:** Add a 2-byte application identifier to the Room Advertisement to filter cross-application room discovery.

**Rejection reason: Complexity cost not justified by benefit.** This is a feature, not a stability fix. It modifies the wire format, adds API surface (appId parameter to Host and Scan), reduces maximum room name length from 8 to 6 characters, and introduces a 256-value ID space with no coordination mechanism. The target environment (small game sessions in close proximity with coordinated updates) has not demonstrated that cross-app room pollution is a material problem. The version negotiation change (Change 6) already provides cross-version isolation. Cross-app isolation within the same version can be revisited in v5 if the problem materializes.

---

## Summary of Specification Section Changes

| Section | Change | Source |
|---------|--------|--------|
| 1. Glossary | Add Recovery Host Probe, Split-Brain, Liveness Check, recoveryHostProbeActive, Protocol Version | Changes 1, 6 |
| 3.1 Room Advertisement | Change prefix from `"LB1"` to `"LB" + version digit`; document new layout | Change 6 |
| 3.4 Discovery | Update DecodeRoom to extract version; handle incompatible rooms | Change 6 |
| 4.3 Control Message Types | Extend HELLO payload with proto_version field; add `incompatible_version` to join_rejected reasons | Change 6 |
| 6.0 BLE Availability Check (new) | Define `AssertBleAvailable()` procedure | Change 7 |
| 6.1 Hosting | Replace assertion with `AssertBleAvailable("host")` call | Change 7 |
| 6.2 Scanning | Replace assertion with `AssertBleAvailable("scan")` call | Change 7 |
| 6.3 Joining | Replace assertion with `AssertBleAvailable("join")` call; remove `connectionFailureHandled` from step 8a; simplify REQUIREMENT block | Changes 4, 7 |
| 6.5 HELLO Handshake | Add step 3f for protocol version validation | Change 6 |
| 7.1 Client Reconnect | Revise `OnReconnectTimeout()` to escalate to recovery for Resilient transport | Change 1 |
| 8.2 Unexpected Host Recovery | Add Recovery Host Probe (step 7a) for self-elected successors | Change 1 |
| 8.4 Migration Reconnect | Add old-host removal as step 1 of `BeginHostingMigratedSession`; strengthen `OnScanResultDuringMigration` step 3 normative language | Changes 2, 5 |
| 8.5 CompleteMigrationResume | Note that peers field must not include old host | Change 2 |
| 12. Event Types | Add `proto_version` to `room_found` event; add `"resetting"` to `radio` event states; add `ble_unavailable` error code | Changes 6, 7 |
| 13. Client Disconnect Decision Tree | Remove step 1 (`connectionFailureHandled`); simplify `shouldEmit` derivation (remove steps 3b/3c); add callback routing REQUIREMENT; reverse steps 6 and 7 | Changes 1, 3, 4 |
| 17. Timeouts | Add Recovery Host Probe Duration (1.5s) | Change 1 |

---

## Version Note for v4.0.0

**Version:** 4.0.0
**Version Note:** Major -- breaking changes to Room Advertisement prefix (`"LB1"` -> `"LB4"`), HELLO payload (proto_version field), Client Disconnect Decision Tree (reconnect-before-recovery ordering, simplified shouldEmit, removed connectionFailureHandled), Recovery Host Probe for split-brain prevention, graceful migration roster cleanup, strengthened migration convergence requirement, protocol version negotiation, and BLE availability check procedure relative to v3.0.0.
