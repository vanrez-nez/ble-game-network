# Proposal B — Protocol Specification v4

**Proposal ID:** b
**Baseline:** Protocol Specification v3.0.0
**Date:** 2026-03-27

---

## Glossary

| Term | Definition |
|------|-----------|
| **Recovery Host Probe** | A bounded scan period inserted before a self-elected successor commits to the host role during unexpected host recovery, used to detect whether the old host is still advertising and therefore still alive. |
| **Liveness Check** | Any mechanism by which a disconnected client determines whether the host it lost contact with is still operational before initiating recovery procedures that create a new host. |
| **Split-Brain** | A state where two or more devices simultaneously operate as host for the same session ID, each unaware of the other, resulting in divergent rosters and message routing. |
| **Departure Intent** | A host-side record that a specific peer has signaled intentional departure via the `client_leaving` control message, used to bypass reconnect grace on the subsequent disconnect callback. |
| **Acceptance Window** | A bounded time period after a successor host begins hosting during which it accepts `migration_resume` join intents. Distinguished from `migrationInProgress`, which has broader lifecycle semantics. |
| **Spec-Code Divergence** | A state where the specification defines behavior that the implementation does not execute, or the implementation executes behavior the specification does not describe. |

---

## Scope Statement

This proposal covers the Client Disconnect Decision Tree (Section 13), Unexpected Host Recovery (Section 8.2), Migration Reconnect (Section 8.4), Graceful Migration Hosting (Section 8.4 `BeginHostingMigratedSession`), and the departure signaling mechanism (Sections 6.6 and 14). It was informed by direct examination of the iOS native implementation (`love/src/modules/ble/apple/Ble.mm`), the Android native implementation (`love-android/app/src/main/java/org/love2d/android/ble/BleManager.java`), the Lua application layer (`lua/ble_net/`), the master issues backlog (`protocol-spec/backlog/issues.md`, issues I-8, I-9, I-10), and the v4 curated issues list (`protocol-spec/version-3/issues.md`, issues I-1, I-2, I-3). These constitute specification-level concerns because they involve architectural decisions about recovery ordering, wire-format consistency guarantees, and normative mechanisms that exist only in one layer (spec or code) but not both.

---

## Item 1: Reconnect-Before-Recovery Ordering with Liveness Probe for Resilient Transport

### Problem Statement

Section 13 (Client Disconnect Decision Tree) step 6 routes Resilient-transport disconnects to `BeginUnexpectedHostRecovery()` before step 7 `BeginClientReconnect()`. Section 8.2 step 3 adds the local peer to the Session Peer roster. Section 8.3 `SelectRecoverySuccessor()` then always finds at least one candidate (self), causing `BeginUnexpectedHostRecovery()` to always return true. This makes step 7 unreachable for Resilient transport.

On a transient BLE drop where the host is still alive and serving other clients, the disconnected client unilaterally elects a successor (possibly itself), starts a GATT server, and advertises the same session ID. The original host continues operating, unaware. The "first advertiser wins" rule (Section 8.4 step 3) helps scanning clients converge, but does not prevent the original host from continuing independently. This is a persistent split-brain.

Both implementations (iOS `Ble.mm` line 1650; Android `BleManager.java` line 2232) match the spec exactly: recovery before reconnect. The Android implementation has independently added an unspecified mitigation: a `recoveryHostProbeActive` flag (line 2504) that causes a self-elected successor to scan for the old host's advertisement before committing to the host role. If the old host is discovered still advertising, the client aborts recovery and reconnects as a normal client (lines 1788-1798). iOS has no equivalent mechanism (line 2918 begins hosting immediately).

This is the issue described in backlog I-9 and curated as I-1.

### Origin

Architectural constraint. The disconnect decision tree's step ordering creates an unreachable code path. The Android liveness probe is a code-to-spec divergence that partially mitigates the underlying architectural problem but is not specified, not implemented on iOS, and not complete (it only checks whether the old host is advertising, not whether it is accepting connections).

### Proposed Change

Replace Section 13 steps 6 and 7 with a three-phase approach: attempt reconnect first, then fall back to recovery only if reconnect fails or times out. Additionally, add a Recovery Host Probe to Section 8.2 for self-elected successors.

**Revised Section 13, steps 6-7:**

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

**Revised Section 7.1 BeginClientReconnect — add recovery escalation on timeout for Resilient transport:**

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

**New step in Section 8.2 BeginUnexpectedHostRecovery, after step 7:**

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
              - If room matches a different known session member
                advertising the same session ID:
                  -> Another peer has already become successor.
                  -> Set recoveryHostProbeActive = false.
                  -> Accept this peer as successor
                     (per existing Section 8.4 step 3).
                  -> Return true.
              - Otherwise: ignore (not relevant).
      7a-iv.  On probe timer expiry:
              -> Old host not found. Proceed to step 8.
              -> Set recoveryHostProbeActive = false.
  8. [existing step 8: Call StartMigration(info).]

  [steps 9-11 unchanged, renumbered as 9-12]
```

**New constant in Section 17:**

| Constant | Default | Purpose |
|----------|---------|---------|
| Recovery Host Probe Duration | 1.5s | Max time a self-elected successor scans for the old host before committing to the host role |

### Reasoning

This change prevents the class of split-brain states caused by transient BLE drops on Resilient transport. By attempting reconnect first, the common case (transient drop, host still alive) is handled without creating a second host. Recovery is escalated to only when reconnect fails, which is the strong signal that the host is genuinely lost. The probe provides a final safety check for self-elected successors. This matches what the Android implementation already does (partially) and extends it to a complete, cross-platform mechanism.

### Known Tradeoffs

- **Increased recovery latency.** A client on Resilient transport now waits up to the Reconnect Timeout (10s) before escalating to recovery, plus an additional 1.5s for the probe. In a genuine host-loss scenario, this delays session continuity. The current behavior (immediate recovery) is faster but incorrectly assumes every disconnect is a host loss.
- **Backward incompatibility.** v3 clients will still use recovery-before-reconnect ordering. Mixed v3/v4 clients in the same Resilient session may exhibit inconsistent behavior during transient drops. The probe mitigates this for self-elected successors regardless of the disconnect tree ordering.
- **Probe is advertisement-based, not connection-based.** The probe checks whether the old host is advertising, not whether it is accepting connections. An old host that has stopped advertising but is still serving connected clients will not be detected. This is an acceptable limitation because a host that stops advertising is functionally unreachable for reconnection anyway.

### Dependencies

None. This change is self-contained. It formalizes a mechanism already partially deployed in Android and extends it to iOS.

---

## Item 2: Old Host Removal Step in Graceful Migration Hosting Path

### Problem Statement

Section 8.2 (Unexpected Host Recovery) step 3 explicitly states "Remove old Host from Session Peer roster." Section 8.4 `BeginHostingMigratedSession` has no equivalent step. When the successor begins hosting a gracefully migrated session, the old host's peer entry remains in the roster. `CompleteMigrationResume` (Section 8.5 step 4) emits `session_resumed` with the departed old host still in the `peers` field. No `peer_left` event is emitted for the old host because it was never in the new host's `connectedClients` map. The stale peer persists indefinitely.

Both implementations have independently corrected this. iOS (`Ble.mm` line 2963-2969, `beginHostingAsSuccessor`) calls `removeSessionPeer:` on the old host with a comment explicitly referencing "mirroring spec Section 8.2 step 3." Android (`BleManager.java` lines 2548-2551, `hostWithMigrationInfo`) does the same. The spec is behind both implementations.

This is backlog issue I-8, curated as I-2.

### Origin

Document-level inconsistency. The unexpected and graceful migration paths have the same requirement (the old host must be removed from the roster when the successor begins hosting) but only the unexpected path specifies it. Both implementations recognized and corrected this independently.

### Proposed Change

Add a roster cleanup step to `BeginHostingMigratedSession` (Section 8.4):

```
FUNCTION BeginHostingMigratedSession(migrationInfo) -> void

  1. Remove the old host's Peer ID from the Session Peer roster.
     Increment membershipEpoch.
  2. Start GATT server with migrated session info
     (sessionId, roomName, maxClients, membershipEpoch).
  2a. Cancel the migration timeout scheduled by BeginMigrationReconnect()
      step 3. The successor is now hosting; the migration timeout applies
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
  - Old host Peer ID not found in roster -> no-op for removal
    (may have been removed by a prior unexpected recovery attempt
    before graceful migration was received).
```

### Reasoning

This eliminates a class of stale-roster bugs across all migration paths. The fix is minimal (one step) and matches what both implementations already do. The spec should reflect the actual required behavior rather than leaving one path underspecified.

### Known Tradeoffs

None. Both implementations already execute this step. This is a documentation correction that aligns the spec with existing correct behavior.

### Dependencies

None.

---

## Item 3: Unimplemented v3 Departure Signaling — Spec-Code Divergence Resolution

### Problem Statement

v3 Change 2 added the `client_leaving` control message to the spec (Section 4.3, Section 6.6 step 2, Section 14). Neither the iOS nor Android implementation sends this message or handles it on the host side.

**Client side:** iOS (`Ble.mm` line 3195) sets `_clientLeaving = YES` during `Leave()` but does not encode or enqueue any `client_leaving` control packet. Android (`BleManager.java` line 2879) sets `clientLeaving = true` but likewise sends no message.

**Host side:** iOS (`Ble.mm` lines 2087-2104) handles `hello` and `roster_request` in `handleHostReceivedPacket:` but has no case for `client_leaving`. Android (`BleManager.java` lines 1339-1352) handles `hello` and `roster_request` in `handleHostControlPacket` but has no case for `client_leaving`.

The spec defines `OnClientLeavingReceived` (Section 14) with a departure intent mechanism including a 2-second expiry (Section 17), but this entire flow has no implementation on either platform. Every intentional client departure enters the 10-second reconnect grace window. The spec says this is resolved; the code says it is not.

This gap also affects the `Departure Send Timeout` (100ms, Section 17) and `Departure Intent Expiry` (2s, Section 17), which have no implementation counterpart.

### Origin

Code-to-spec divergence. The spec was updated in v3 but the implementation was not. The spec claims this issue is resolved (backlog I-1 status: "resolved"), but both platforms lack the implementation. GitHub issue #1 remains open.

### Proposed Change

Add the following normative note to Section 6.6 step 2 and Section 14 `OnClientLeavingReceived`:

> **Implementation status note:** The `client_leaving` mechanism is fully specified but has no implementation on either platform as of v4. The specification retains this mechanism as normative. Implementations MUST implement the `client_leaving` send path (Section 6.6 step 2a-c) and the host-side departure intent handling (Section 14 `OnClientLeavingReceived` and `OnHostClientDisconnected` step 3b) to be v4-compliant. Until implemented, all client departures traverse the 10-second reconnect grace path, which is functionally correct but slower. The backward compatibility guarantee (Section 4.3 `client_leaving backward compatibility` note) remains valid: implementations that send `client_leaving` interoperate with hosts that do not handle it, and vice versa.

Additionally, add a new Section 18 or equivalent:

**Section 18: Implementation Compliance Notes**

> The following v3-specified mechanisms are not yet implemented on either platform and require implementation for v4 compliance:
>
> 1. **`client_leaving` departure message** (Section 6.6 step 2, Section 14). Send path and host-side handling.
> 2. **Application lifecycle integration** (Section 6.7 `OnAppLifecycleChanged`). Neither platform registers for lifecycle events or invokes `Leave()` on background/termination.
> 3. **Migration Acceptance Window flag** (Section 8.4 `BeginHostingMigratedSession` steps 3, 7-8). `migrationAcceptanceActive` is not implemented. Android reuses `migrationInProgress` with different lifecycle semantics.
>
> These are implementation gaps, not specification gaps. The spec definitions are retained as normative. New implementations MUST implement all three mechanisms.

### Reasoning

The specification is a standard. When the standard says a behavior exists and the implementations do not execute it, this must be surfaced explicitly. The alternative — removing these mechanisms from the spec because they are not implemented — would be worse: it would reintroduce the problems they were designed to solve (I-1 departure signaling, I-4 lifecycle handling). The correct resolution is to retain the spec language and mark the implementation gap explicitly so that the gap can be tracked and closed.

### Known Tradeoffs

- **Adding an implementation compliance section is unusual for a protocol spec.** It mixes normative language with implementation status tracking. However, the alternative — pretending the spec and code are aligned when they are not — is more harmful.
- **This does not fix the implementation.** It only ensures the spec accurately represents the state of the world. The actual implementation work is a separate concern.

### Dependencies

None. This item is informational and does not change any normative behavior.

---

## Item 4: Migration Convergence — Platform-Asymmetric "First Advertiser Wins" Implementation

### Problem Statement

Section 8.4 `OnScanResultDuringMigration` step 3 defines the "first advertiser wins" rule: if a scanning client discovers a room with the correct session ID hosted by a known session member who is *not* the locally elected successor, the client accepts that peer as the new successor and connects to it. This is the primary convergence mechanism for divergent successor elections.

iOS (`Ble.mm` lines 3122-3135, `onScanResultDuringMigration:`) does not implement step 3. It only accepts the exact elected successor. If two clients elect different successors, each will only connect to their own elected successor, never converging.

Android (`BleManager.java` lines 1813-1822) implements step 3, but only when `recoveryTriggered == true` (line 1813). This means the "first advertiser wins" rule applies during unexpected host recovery but NOT during graceful migration. In a graceful migration with divergent elections (theoretically impossible since the departing host designates the successor, but relevant if the migration message is lost and some clients fall back to local election), the rule does not apply.

This is backlog issue I-10.

### Origin

Code-to-spec divergence, platform-asymmetric. The spec defines uniform behavior. One platform does not implement it at all; the other implements it conditionally.

### Proposed Change

Add explicit preconditions to `OnScanResultDuringMigration` step 3 that clarify when the "first advertiser wins" rule applies, and strengthen the normative language:

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
only on one path violates this requirement.

ERRORS:
  - Connection to accepted successor fails -> resume scan.
    Migration timeout still applies.
```

### Reasoning

The "first advertiser wins" rule is the only convergence mechanism the protocol has for divergent successor elections. If it does not work uniformly, divergent elections produce persistent session splits with no resolution. The spec already defines this behavior; this change strengthens the normative language to prevent partial implementations.

### Known Tradeoffs

- **Graceful migration with the correct successor designated should not produce divergent elections.** Step 3 is therefore a safety net for graceful migration, not a primary mechanism. Making it mandatory for graceful migration adds implementation cost for a rare scenario. However, the cost is minimal (one additional `if` check in the scan handler) and the safety benefit is non-trivial.

### Dependencies

None. This change clarifies existing normative language.

---

## Item 5: Recovery Host Probe Formalization as Normative Mechanism

### Problem Statement

The Android implementation (`BleManager.java` lines 2498-2505) contains a mechanism not described in the specification: when a client self-elects as successor during unexpected host recovery, it scans for the old host's advertisement before starting its own GATT server. If the old host is still advertising, the client aborts recovery and reconnects to the old host as a normal client (lines 1788-1798). If the probe times out, the client proceeds with hosting (lines 2756-2761).

iOS has no equivalent mechanism. When a self-elected successor calls `beginHostingAsSuccessor` (line 2920), it immediately starts the GATT server with no probe.

This mechanism directly addresses the split-brain problem described in Item 1 but is unspecified, platform-specific, and incomplete. It has no defined timeout constant, no interaction with the migration timeout, and no handling of the case where the old host is found but has a different session ID (host restarted).

### Origin

Code-to-spec divergence. The Android implementation has evolved past what the spec describes. This mechanism should be formalized or removed — having it on one platform but not the other creates inconsistent behavior in mixed-platform sessions.

### Proposed Change

This item is dependent on Item 1. If Item 1 is accepted, the Recovery Host Probe is formalized as part of the revised `BeginUnexpectedHostRecovery` procedure (Item 1, step 7a). If Item 1 is rejected, this item proposes an independent formalization:

Add to Section 8.2, between current steps 9 and 10:

```
  9a. If becomingHost is true:
      9a-i.   Set recoveryHostProbeActive = true.
      9a-ii.  Start BLE scan. Schedule Recovery Host Probe timer
              (default 1.5s, Section 17).
      9a-iii. During scan, if old host's advertisement is discovered
              (same session ID, old host's Peer ID):
              -> Cancel probe timer. Stop scan.
              -> Set recoveryHostProbeActive = false.
              -> Clear migration state.
              -> Call BeginClientReconnect().
              -> Return true (recovery aborted in favor of reconnect).
      9a-iv.  On probe timer expiry:
              -> Set recoveryHostProbeActive = false.
              -> Stop scan.
              -> Proceed to step 10 (begin hosting).
```

Additionally, add the `Recovery Host Probe Duration` constant to Section 17 (same as Item 1).

### Reasoning

This formalizes an existing Android-only mitigation as a cross-platform requirement. Without this, iOS clients on Resilient transport will create split-brain states on transient BLE drops while Android clients in the same session will not — producing unpredictable behavior that depends on which platform happens to self-elect as successor.

### Known Tradeoffs

- **Adds 1.5 seconds of latency to recovery when the client self-elects as successor.** In a genuine host-loss scenario, this delays session continuity. This is the same tradeoff as Item 1 and is acceptable given that the alternative is a split-brain.
- **Does not help when a non-self peer is elected as successor.** The probe only applies when `becomingHost` is true. If the client elects a different peer as successor, it immediately starts scanning for that peer's advertisement, with no probe. This is acceptable because the split-brain risk is specific to self-election (the client starting its own GATT server).

### Dependencies

If Item 1 is accepted, this item is subsumed by Item 1's revised `BeginUnexpectedHostRecovery` procedure. If Item 1 is rejected, this item stands independently as a narrower fix that addresses the self-election split-brain without changing the disconnect tree ordering.

---

## Item 6: Permissions Assertion — Minimal Structured Replacement

### Problem Statement

Sections 6.1, 6.2, and 6.3 all begin with "Assert BLE is available and permissions granted" without defining what permissions are required, what "available" means beyond the `radio` event states, how to handle denial, or whether checks are per-operation or upfront. This was explicitly deferred in v3 (changelog item 10) and is curated as I-3.

The Lua application layer (`lua/ble_net/init.lua` lines 503-513) checks `ble.state()` for `"unsupported"`, `"unauthorized"`, and `"off"` and emits user-facing messages, but this is not connected to the protocol layer's assertion in any specified way. The native layers perform platform-specific permission checks (Android runtime permissions, iOS `CBManagerAuthorization`) but these are implementation details not reflected in the spec.

### Origin

Document-level incompleteness, explicitly deferred from v3.

### Proposed Change

Replace "Assert BLE is available and permissions granted" in Sections 6.1, 6.2, and 6.3 with a reference to a new procedure:

**New Section 6.0: BLE Availability Check**

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

**Platform permission categories (informative):**

| Category | Android | iOS |
|----------|---------|-----|
| Scan | `BLUETOOTH_SCAN` (API 31+) or `ACCESS_FINE_LOCATION` (API < 31) | Automatic with `CBCentralManager` |
| Connect | `BLUETOOTH_CONNECT` (API 31+) or `BLUETOOTH` (API < 31) | Automatic with `CBCentralManager` |
| Advertise | `BLUETOOTH_ADVERTISE` (API 31+) or `BLUETOOTH` (API < 31) | Automatic with `CBPeripheralManager` |

The platform-specific permission table is informative, not normative. The normative requirement is that `AssertBleAvailable()` returns false and emits an error event when the radio state precludes the requested operation. How the platform determines that state is implementation-defined.

Sections 6.1, 6.2, and 6.3 step 1 become:

> 1. Call AssertBleAvailable("host" | "scan" | "join"). If false, return.

### Reasoning

This replaces an undefined assertion with a testable procedure. Two implementors reading this will produce compatible behavior: both check radio state, both emit the same error event structure, both return false on the same conditions. The platform-specific permission details remain informative because they change with OS versions and cannot be normatively specified without creating a maintenance burden.

### Known Tradeoffs

- **Does not define permission request flows.** The spec defines what happens when permissions are denied but does not define how to request them. This is intentional: permission request UX is application-specific and platform-specific. The protocol layer's responsibility is to detect denial and surface it via events.
- **"Resetting" state is new.** The v3 `radio` event defines states `"on"`, `"off"`, `"unauthorized"`, `"unsupported"`. Both iOS (`CBManagerStatePoweredOn/Off/Unauthorized/Unsupported/Resetting`) and Android (`STATE_ON/OFF/TURNING_ON/TURNING_OFF`) have transient states that map to "resetting." Adding this state to the check procedure without adding it to Section 12's `radio` event states creates an inconsistency. This should be resolved by adding `"resetting"` to the `radio` event state set, but that is a minor wire-level change.

### Dependencies

Requires adding `"resetting"` to the `radio` event state values in Section 12 if the "resetting" check (step 5) is accepted.
