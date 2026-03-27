# Protocol Specification v4 -- Proposal A

**Proposal ID:** a
**Baseline:** Protocol Specification v3.0.0
**Date:** 2026-03-27

---

## Glossary

| Term | Definition |
|------|-----------|
| **Recovery Host Probe** | A bounded scan period during which a self-elected recovery successor searches for the old host's advertisement before committing to the host role. If the old host is discovered, the client aborts recovery and reconnects as a normal client. |
| **Split-Brain** | A state in which two or more GATT servers advertise the same Session ID simultaneously, each believing itself to be the authoritative host. Clients may connect to different hosts, producing irreconcilable roster divergence. |
| **Departure Message** | A `"client_leaving"` control packet sent by a client to the host immediately before intentional disconnection, enabling the host to bypass reconnect grace. Defined in v3 Section 4.3 and Section 6.6 step 2. |
| **Connection Failure Guard** | The `connectionFailureHandled` boolean flag defined in v3 Section 6.3 step 8a and Section 13 step 1, intended to prevent dual delivery of GATT connection failure events through both the connection failure path and the disconnect decision tree. |
| **Migration Acceptance Window** | A bounded time period (default 3s) after a successor host begins hosting during which it accepts `migration_resume` join intents. Defined in v3 Section 8.4 `BeginHostingMigratedSession`. |
| **Device-Identity Guard** | The `shouldEmit` derivation sub-conditions (v3 Section 13 steps 3b and 3c) that suppress disconnect events when the disconnected device does not match the current reconnect or migration join target. |

---

## Scope Statement

This proposal covers the Client Disconnect Decision Tree (Section 13), Unexpected Host Recovery (Section 8.2), Migration Reconnect (Section 8.4), Graceful Migration roster cleanup (Section 8.4/8.5), the `client_leaving` departure message (Section 6.6), the `connectionFailureHandled` guard (Section 6.3/13), and `shouldEmit` derivation (Section 13). It was informed by: (a) line-by-line comparison of the v3 specification against the Android implementation (`BleManager.java`, 3,035 lines) and iOS implementation (`Ble.mm`, 3,427 lines); (b) the ten open GitHub issues on `vanrez-nez/ble-game-network`; (c) the v3 curated issues I-1, I-2, and I-3; and (d) the v3 curated features F-1 and F-2. All items below are specification-level concerns grounded in code-to-spec divergence, architectural constraint, or open issues that cannot be closed without a specification decision.

---

## Item 1: Recovery Host Probe -- Codify the Split-Brain Mitigation for Unexpected Host Recovery

### Problem Statement

Section 13 (Client Disconnect Decision Tree) step 6 routes Resilient-transport disconnects through `BeginUnexpectedHostRecovery()` before `BeginClientReconnect()` (step 7). As documented in curated issue I-1, `SelectRecoverySuccessor()` always has at least the local peer as a candidate (self is added in Section 8.2 step 3), so `BeginUnexpectedHostRecovery()` always returns true, making step 7 unreachable for Resilient transport. On a transient BLE drop where the host is still alive, the client unilaterally elects a successor (often itself), starts a GATT server, and advertises the same session ID -- creating a split-brain state.

The Android implementation (`BleManager.java`, lines 2497-2505) has deployed an ephemeral workaround: when a self-elected recovery successor would begin hosting, it instead scans for the old host's advertisement first (`recoveryHostProbeActive = true`). If the old host is still advertising, the client aborts recovery and reconnects as a normal client. If the old host is not found within the migration timeout, the client proceeds with hosting. This mechanism is documented only as code comments and is not present in the iOS implementation (`Ble.mm`, line 2917 -- `beginHostingAsSuccessor` proceeds immediately with no probe). The result is that the split-brain mitigation exists on one platform and not the other, with no specification authority for either behavior.

### Origin

Code-to-spec divergence (Android has undocumented behavior absent from iOS) combined with open issue I-1 (critical severity in v3 curated issues).

### Proposed Change

Add a **Recovery Host Probe** phase to Section 8.4 `BeginMigrationReconnect()` that applies when the following conditions are all true: (a) `becomingHost` is true, (b) the recovery was triggered by unexpected host loss (not graceful `session_migrating`), and (c) the self-elected successor is the local peer. Under these conditions, the successor scans for the old host's advertisement before committing to the host role.

Replace the current Section 8.4 `BeginMigrationReconnect()` step 1 with:

```
FUNCTION BeginMigrationReconnect() -> void

  1. If becomingHost is true AND recoveryTriggered is true:
     1a. Call StopClientOnly().
     1b. Set recoveryHostProbeActive = true.
     1c. Start BLE scan (low latency, same parameters as migration scan).
     1d. Schedule migration timeout (default 3s, Section 17).
         On timeout: go to step 1g.
     1e. On each scan result:
         - If room.sessionId matches migrationSessionId AND
           room.hostPeerId matches the old host's Peer ID:
             -> The old host is still alive. Abort recovery:
                cancel migration timeout, stop scan,
                set recoveryHostProbeActive = false,
                clear migration state,
                set hostPeerId = room.hostPeerId,
                set joinedSessionId = room.sessionId,
                call ConnectToRoom(room, migrationJoin=false).
                Return.
         - Else if room.sessionId matches migrationSessionId AND
           room.hostPeerId matches a known session member:
             -> Another peer became host first. Accept as successor:
                stop scan, set recoveryHostProbeActive = false,
                update migrationSuccessorId, connect with migrationJoin=true.
                Return.
         - Else: ignore, continue scanning.
     1f. (Scan continues until timeout or match.)
     1g. On migration timeout with recoveryHostProbeActive still true:
         -> Old host not found. Commit to hosting:
            set recoveryHostProbeActive = false,
            stop scan,
            call BeginHostingMigratedSession(migrationInfo),
            schedule new migration timeout for client connections.
            Return.
  2. Else if becomingHost is true (graceful migration):
     2a. Call StopClientOnly().
     2b. Call BeginHostingMigratedSession(migrationInfo).
  3. Else (not becoming host):
     3a. Call StopClientOnly().
     3b. Start scan to find new host's advertisement.
  4. Schedule migration timeout (default 3s, Section 17).
     On timeout: call FailMigration().

ERRORS:
  - Scan fails to start during probe -> proceed directly to
    BeginHostingMigratedSession (degrade gracefully).
  - Probe timeout fires after recovery already aborted ->
    check recoveryHostProbeActive; if false, no-op.
```

Add `recoveryHostProbeActive` and `recoveryTriggered` to the glossary in Section 1:

| Term | Definition |
|------|-----------|
| **recoveryTriggered** | A boolean indicating that the current migration was initiated by unexpected host loss (Section 8.2), not by a graceful `session_migrating` message. Determines whether the Recovery Host Probe applies. |
| **recoveryHostProbeActive** | A boolean indicating that the self-elected recovery successor is currently scanning for the old host's advertisement before committing to the host role. Set to true at probe start, cleared when the probe resolves (old host found, another successor found, or timeout). |

### Reasoning

The recovery host probe converts a unilateral, immediate self-election into a bounded observation period. This directly prevents the most common split-brain scenario: a transient BLE drop where the host is still alive. The probe reuses the existing migration scan infrastructure and the existing migration timeout, adding no new timers. The worst-case cost is one migration timeout period (3s) of delay before the new host begins serving -- acceptable given that the alternative is a session-destroying split-brain. The Android implementation has been running this pattern in production; codifying it makes it normative and closes the iOS gap.

### Known Tradeoffs

- Adds 3 seconds of latency to the self-elected successor's hosting start in the genuine host-loss case. In the target environment (small peer counts, close proximity), this delay is within the reconnect timeout window of other clients.
- Does not prevent split-brain when two non-self peers are simultaneously elected by different clients. The existing "first advertiser wins" rule (Section 8.4 step 3) remains the convergence mechanism for that case.
- The probe is only effective when the old host's advertisement is still propagating. If the old host's BLE radio was lost simultaneously with the connection (e.g., device powered off), the probe provides no benefit but also causes no harm beyond the timeout delay.

### Dependencies

None. This change is self-contained within Section 8.4 and Section 1. It complements, but does not require, any change to Section 13 step ordering.

---

## Item 2: Graceful Migration Must Remove Old Host from Successor's Roster

### Problem Statement

Section 8.2 (Unexpected Host Recovery) step 3 explicitly states "Remove old Host from Session Peer roster." The graceful migration path has no equivalent step. When the successor begins hosting via `BeginHostingMigratedSession` (Section 8.4), the old host's peer entry is never removed. `CompleteMigrationResume` (Section 8.5) step 4 emits `session_resumed` with the departed old host still in the `peers` field. No `peer_left` event is ever emitted for the old host because it was never in the new host's `connectedClients` map. The peer persists indefinitely.

Both the Android implementation (`BleManager.java` `hostWithMigrationInfo()`, line 2523) and iOS implementation (`Ble.mm` `beginHostingAsSuccessor`, line 2937) reproduce this behavior faithfully -- neither removes the old host from the roster during graceful migration. This is curated issue I-2.

### Origin

Specification gap documented in curated issue I-2 (major severity). Both implementations faithfully reproduce the spec's omission.

### Proposed Change

Add a step to `BeginHostingMigratedSession` (Section 8.4) that removes the old host from the session peer roster, mirroring Section 8.2 step 3:

```
FUNCTION BeginHostingMigratedSession(migrationInfo) -> void

  1. Start GATT server with migrated session info
     (sessionId, roomName, maxClients, membershipEpoch).
  1a. Cancel the migration timeout scheduled by BeginMigrationReconnect()
      step 4. The successor is now hosting; the migration timeout applies
      to the reconnecting-client path, not the hosting path.
  1b. Remove the old host's Peer ID from the Session Peer roster.
      Increment membershipEpoch. If the old host is not in the roster,
      this step is a no-op (idempotent with Section 8.2 step 3 for
      unexpected recovery paths that already removed it).
  2. Set migrationAcceptanceActive = true.
  3. Begin advertising the room.
  4. Start Heartbeat timer.
  5. Emit hosted event.
  6. Schedule Migration Acceptance Window timer (default 3s, Section 17).
  7. On Migration Acceptance Window expiry:
     a. Set migrationAcceptanceActive = false.
     b. Any subsequent join with intent="migration_resume" is
        rejected with "migration_mismatch" per Section 6.5 step 3e.

ERRORS:
  - GATT server fails to start -> emit error, session is lost.
  - No peers connect within acceptance window -> window expires,
    host continues operating with current roster. Peers arriving
    later with fresh join intent are accepted normally.
```

Additionally, update `CompleteMigrationResume` (Section 8.5) to note that the old host should already have been removed from the roster by this point, and that the `peers` field in the `session_resumed` event must not include the old host.

### Reasoning

This is a parity fix. The unexpected recovery path correctly removes the old host; the graceful path omits it. The result is that clients receiving `roster_snapshot` after graceful migration see a ghost peer that will never connect, never time out, and never emit `peer_left`. The fix is a single roster mutation that mirrors existing logic.

### Known Tradeoffs

None significant. The old host has already departed. Removing it from the roster is the correct representation of reality. The idempotency guard ensures no harm when the unexpected recovery path has already performed the removal.

### Dependencies

None. This change is self-contained within Section 8.4 and Section 8.5.

---

## Item 3: `shouldEmit` Derivation -- Reconcile Spec with Both Implementations

### Problem Statement

Section 13 (Client Disconnect Decision Tree) steps 3a-3d define `shouldEmit` with three sub-conditions:
- 3a: If `clientLeaving` is true, `shouldEmit` = false.
- 3b: If `reconnectJoinInProgress` is true AND the disconnected device is not the GATT device for the current reconnect attempt, `shouldEmit` = false.
- 3c: If `migrationJoinInProgress` is true AND the disconnected device is not the GATT device for the current migration attempt, `shouldEmit` = false.
- 3d: Else `shouldEmit` = true.

Neither implementation follows this derivation:

- **Android** (`BleManager.java`, line 1974): Passes `!clientLeaving` as `shouldEmit` directly. Steps 3b and 3c (device-identity guards) are not implemented. The function signature is `onClientDisconnected(boolean wasJoined, boolean shouldEmit)` -- the v2 parameterized signature, not the v3 zero-argument signature.
- **iOS** (`Ble.mm`, line 1633): Uses `BOOL shouldEmit = !_clientLeaving;` inline. Steps 3b and 3c are not implemented. The function is the CoreBluetooth delegate `didDisconnectPeripheral:error:`, which inherently receives the peripheral parameter.

The device-identity guards (steps 3b/3c) exist in the spec to handle a specific scenario: during a reconnect or migration join, a disconnect callback fires for the *previous* (stale) GATT device, not the current join target. Without these guards, the stale disconnect would be processed as a genuine host loss, potentially triggering recovery or emitting spurious events. However, on Android, `onConnectionStateChange` is associated with a specific `BluetoothGatt` object, and the implementation already checks `gatt == clientGatt` before dispatching. On iOS, the delegate checks `peripheral != _connectedPeripheral` at the entry point (line 1629). Both platforms perform the identity check at the callback routing level, making the spec-level derivation redundant in practice.

### Origin

Code-to-spec divergence on both platforms. The spec defines behavior that no implementation follows, and both implementations achieve the same correctness guarantee through a different mechanism (callback-level device identity filtering).

### Proposed Change

Restructure Section 13 steps 2-3 to separate the two concerns:

1. **Callback-level routing requirement** (normative): The implementation MUST ensure that `OnClientDisconnected()` is only invoked for the device currently associated with the active client connection. Disconnect callbacks for stale devices (from previous connections, prior to `StopClientOnly()` cleanup) MUST be discarded at the callback routing level. This may be achieved by comparing the callback's device handle against the current client GATT reference, or by any equivalent mechanism that produces the same filtering.

2. **`shouldEmit` derivation** (simplified): Given the callback routing requirement above, the `shouldEmit` derivation reduces to:

```
  3. Derive shouldEmit:
     3a. If clientLeaving is true -> shouldEmit = false.
     3b. Else -> shouldEmit = true.
```

Remove steps 3b and 3c from the current decision tree. Add the callback-level routing requirement as a REQUIREMENT block above the decision tree, adjacent to the existing REQUIREMENT about connection failure routing (Section 6.3).

### Reasoning

The device-identity guards in steps 3b/3c solve a real problem (stale disconnect callbacks), but they solve it at the wrong layer. Both implementations correctly solve it at the callback routing layer -- where the device identity is naturally available and where the filtering is cheaper and more reliable. The spec-level derivation adds complexity that every implementor ignores because it is unnecessary once callback routing is correct. Extracting the callback routing requirement as a normative statement and simplifying `shouldEmit` aligns the spec with how both implementations actually achieve correctness.

### Known Tradeoffs

- An implementation that cannot filter at the callback routing level (e.g., a platform that delivers disconnect callbacks without device context) would lose the protection of steps 3b/3c. This is a theoretical concern; no known BLE platform delivers anonymous disconnect callbacks.
- The simplified derivation relies on the callback routing requirement being implemented correctly. If an implementation fails to filter stale callbacks, the simplified `shouldEmit` provides no safety net. The current spec's steps 3b/3c would catch such failures -- but at the cost of a derivation that no one implements.

### Dependencies

None. This change is self-contained within Section 13.

---

## Item 4: `connectionFailureHandled` Guard Is Not Implemented -- Simplify or Remove

### Problem Statement

Section 13 step 1 defines a `connectionFailureHandled` guard: if the flag is true, clear it and return without executing the disconnect tree. Section 6.3 `ConnectToRoom` step 8a sets this flag. The intent is to prevent dual delivery on platforms (notably Android) where a GATT connection failure is delivered as both a connection failure event and a subsequent disconnect callback.

Neither the Android implementation nor the iOS implementation has a `connectionFailureHandled` field. A `grep` for `connectionFailureHandled` across both native codebases returns zero results.

The Android implementation routes connection failures from `onServicesDiscovered` and characteristic lookup through `onClientDisconnected(false, true)` directly (lines 1999, 2007, 2014). The GATT `onConnectionStateChange` with `STATE_DISCONNECTED` also routes through `onClientDisconnected(clientJoined, !clientLeaving)` (line 1974). Both paths lead to the same function, and the `wasJoined=false` argument in the failure path causes the disconnect tree to take the "emit error" branch (step 8c) rather than the recovery branch. This works because Android's `handler.post()` serializes all callbacks onto the same thread, so the two events do not race.

The iOS implementation does not call `onClientDisconnected` from service discovery failure at all -- it handles the error inline in `didDiscoverServices:` and `didDiscoverCharacteristics:`. The CoreBluetooth `didDisconnectPeripheral:` fires separately. There is no dual-delivery concern.

### Origin

Code-to-spec divergence on both platforms. The spec defines a guard flag that no implementation uses. Both platforms achieve correctness through platform-specific means (thread serialization on Android, separate callback structure on iOS).

### Proposed Change

Remove `connectionFailureHandled` from Section 13 step 1 and from Section 6.3 step 8a. Replace with a REQUIREMENT block that states the implementation concern without mandating a specific mechanism:

> REQUIREMENT: On platforms where GATT connection failure may be delivered as both a connection failure event and a subsequent disconnect callback, the implementation MUST ensure that the disconnect decision tree (Section 13) does not process the same underlying failure event twice. This may be achieved by a guard flag, by callback-level deduplication, by thread serialization that allows the first handler to modify state before the second fires, or by any equivalent mechanism. The specific mechanism is implementation-defined.

Remove `connectionFailureHandled` from the glossary (Section 1) if it was previously listed. The existing REQUIREMENT block at the end of Section 6.3 (`ConnectToRoom`) about connection failure routing should be retained but simplified to reference the new REQUIREMENT instead of prescribing the flag.

### Reasoning

The `connectionFailureHandled` flag solves a real platform concern (Android dual delivery), but it prescribes a mechanism that neither platform uses. Android achieves correctness through handler-thread serialization. iOS has no dual-delivery concern. Mandating a specific flag that no one implements degrades the spec's credibility and confuses implementors who read the spec and find no corresponding code. Replacing the flag with a platform concern statement preserves the safety requirement without mandating a mechanism.

### Known Tradeoffs

- Removing the prescribed mechanism means the spec no longer provides a "reference implementation" for the dual-delivery guard. An implementor on a new platform must design their own solution. This is acceptable because the guard is inherently platform-specific.
- If a future platform has a dual-delivery concern that is not solved by thread serialization or callback structure, the implementor must recognize and solve it without spec guidance on mechanism. The REQUIREMENT block alerts them to the concern.

### Dependencies

None. This change affects Section 6.3 and Section 13 only.

---

## Item 5: `client_leaving` Departure Message Is Not Implemented on Either Platform

### Problem Statement

Section 6.6 (Leave) step 2 specifies that a client connected with `clientJoined = true` must send a `"client_leaving"` control packet before disconnecting, then set `clientLeaving = true` and wait up to 100ms for the write callback. Section 14 (`OnClientLeavingReceived`) specifies that the host records a departure intent and uses it within 2 seconds to bypass reconnect grace on the subsequent disconnect.

Neither the Android implementation nor the iOS implementation sends the `client_leaving` message. Android's `leave()` method (line 2827) checks for graceful migration, then calls `leaveInternal()` which sends `session_ended` if hosting, then calls `finishLeave()` -- at no point is `client_leaving` sent. iOS's `leaveSession` (line 3141) follows the same pattern: checks for graceful migration, then calls `finishLeave:` with a reason string.

Neither platform implements `OnClientLeavingReceived` on the host side. Android's `handleHostControlPacket` (line 1339) handles `"hello"` and `"roster_request"` only. There is no departure intent map, no departure intent expiry, and no check in `OnHostClientDisconnected`.

The `client_leaving` message was added to the spec in v3 changelog item 2. The v3 spec explicitly notes backward compatibility: "A v2 host that receives the unknown `'client_leaving'` control type will silently ignore it." However, neither platform has implemented the v3 behavior. The message exists only in the spec.

### Origin

Code-to-spec divergence on both platforms. The v3 spec change (changelog item 2) was merged into the specification but never implemented. This is not a platform limitation; the implementation simply was not updated to match the spec revision.

### Proposed Change

Retain the `client_leaving` message specification in its current form (Section 4.3, Section 6.6 step 2, Section 14 `OnClientLeavingReceived`). No specification change is needed. However, add an **implementation status note** at the end of Section 6.6 step 2 and Section 14:

> NOTE: This mechanism was introduced in v3.0.0. Implementations that have not yet adopted it fall back to the reconnect grace path for all client departures, which is the v2-compatible behavior. The grace timer serves as the fallback for all cases where the departure message is not sent, not received, or not processed.

This note is informative, not normative. It acknowledges the current implementation gap without weakening the normative requirement. The alternative -- removing the `client_leaving` message from the spec -- would be a regression from v3.

Additionally, flag the following as an implementation gap that must be closed before v4 can claim compliance:
- Android `leave()` must send `client_leaving` before `finishLeave()`.
- iOS `leaveSession` must send `client_leaving` before `finishLeave:`.
- Both hosts must implement `OnClientLeavingReceived` and departure intent checking in `OnHostClientDisconnected`.

### Reasoning

The `client_leaving` message solves a real problem: without it, intentional client departures cause a 10-second reconnect grace period during which the host holds the peer's slot, prevents cleanup, and delays `peer_left` notification to other clients. The mechanism is correctly designed and carries backward compatibility. The problem is entirely an implementation gap, not a spec problem. The spec should retain the requirement; the implementation must catch up.

### Known Tradeoffs

- The informative note may be read as softening the normative requirement. The note must be clearly marked as informative.
- Retaining a requirement that no implementation follows creates a compliance gap. This is preferable to removing a correctly designed mechanism and reverting to v2 behavior where all departures are indistinguishable from crashes.

### Dependencies

None. This is a documentation-level addition to existing spec sections.

---

## Item 6: iOS Disconnect Tree Uses Full `FinishLeave` Instead of `FinishLeaveClient`

### Problem Statement

Section 13 (Client Disconnect Decision Tree) steps 8a and 9a specify calling `FinishLeaveClient()` -- the client-only teardown that preserves host state. Section 6.6 defines `FinishLeaveClient()` as: (1) call `StopClientOnly()`, (2) clear client-side dedup, (3) clear client-side fragment assemblies, (4) set `clientJoined = false`, (5) set `clientLeaving = true`. The postcondition explicitly states: "Host state (GATT server, host timers, host session info) is unaffected."

The Android implementation (`BleManager.java`, line 2917) correctly implements `finishLeaveClient()` as a client-only teardown.

The iOS implementation (`Ble.mm`, line 1666) calls `[self finishLeave:nil]` in the disconnect tree -- the full teardown that stops advertising, closes the GATT server, clears all host maps, and resets session identifiers. This means that on iOS, if a device is simultaneously hosting and experiences a client disconnect (e.g., it is a migration successor that also had a client connection to the old host), the full `finishLeave` destroys the host's GATT server and active session.

iOS also calls `[self finishLeave:nil]` in `failReconnect` (line 2837), where the spec calls for `FinishLeaveClient()` (Section 7.1 step 4).

### Origin

Code-to-spec divergence on iOS. The `FinishLeaveClient()` procedure was introduced in v3 changelog item 4. The Android implementation adopted it; the iOS implementation did not.

### Proposed Change

No specification change needed. The v3 specification correctly defines `FinishLeaveClient()` and its call sites. This item is raised to document the divergence for the referee's awareness and to confirm that the spec's `FinishLeaveClient()` definition is complete and unambiguous enough for the iOS implementation to adopt.

Confirm the following spec language remains in Section 6.6:

> `FinishLeaveClient()` is used instead of `FinishLeave(null)` at the following call sites:
> - Section 13 (Client Disconnect Decision Tree), steps 8a and 9a.
> - Section 7.1 `FailReconnect()`, step 4.
> - Section 6.3 `ConnectToRoom` step 8e.

No additional spec clarification is needed. The definition and call sites are explicit.

### Reasoning

This is not a spec problem -- it is an implementation deficiency that the spec already addresses correctly. However, the v4 cycle should confirm that the spec's distinction between `FinishLeaveClient()` and `FinishLeave()` is sufficiently clear that the iOS implementation can be updated without ambiguity. If the referee determines the spec language is already adequate, this item requires no spec action. If any ambiguity is identified, a clarification should be added.

### Known Tradeoffs

None. The spec is correct; the implementation needs to catch up.

### Dependencies

None.

---

## Item 7: `migrationAcceptanceActive` Is Not Implemented -- Confirm or Defer

### Problem Statement

Section 8.4 `BeginHostingMigratedSession` step 2 sets `migrationAcceptanceActive = true` and step 7 schedules a timer to set it to false after 3 seconds. Section 6.5 step 3e rejects `migration_resume` join intents when the host is not in a migration-acceptance state.

Neither the Android implementation nor the iOS implementation has a `migrationAcceptanceActive` field. A search for `migrationAcceptanceActive` or `migrationAcceptance` across both native codebases returns zero results. GitHub issue #10 notes that this feature is "deferred" in the implementation.

Without this bounded window, a successor host accepts `migration_resume` join intents indefinitely. In practice, this is low-severity because: (a) migration-resume joins carry a session ID that must match, providing some protection against stale joins; and (b) the reconnect timeout (10s) on the client side means clients stop attempting migration-resume within 10 seconds.

### Origin

Code-to-spec divergence on both platforms. The v3 spec change (changelog item 7) was merged into the specification but never implemented on either platform.

### Proposed Change

Retain the `migrationAcceptanceActive` specification in its current form. Add an informative note to Section 8.4 `BeginHostingMigratedSession`:

> NOTE: The Migration Acceptance Window bounds the period during which `migration_resume` join intents are accepted. Without this window, stale migration-resume attempts arriving after the window would succeed. In practice, the Reconnect Timeout (10s) on the client side limits the effective exposure. Implementations SHOULD implement the acceptance window; implementations that omit it MUST NOT accept migration-resume joins from peers not in the migrated session's roster.

This preserves the normative requirement while acknowledging the practical fallback.

### Reasoning

The acceptance window is a defense-in-depth measure. The primary protection (session ID matching and client-side reconnect timeout) limits the exposure. The window adds a tighter bound that is architecturally clean but practically non-critical. The spec should keep the requirement but acknowledge the implementation status.

### Known Tradeoffs

- The SHOULD language is weaker than the current implicit MUST. This reflects the implementation reality: the feature has been deferred on both platforms without observable issues.

### Dependencies

None.

---

## Item 8: iOS `onScanResultDuringMigration` Missing "First Advertiser Wins" Rule

### Problem Statement

Section 8.4 `OnScanResultDuringMigration` step 3 defines the "first advertiser wins" convergence rule: if a scanning client during migration discovers a room with the same session ID and a host Peer ID that is a known session member (but not the locally elected successor), the client accepts that peer as the new successor. This rule was added in v3 changelog item 6 to resolve divergent successor elections.

The Android implementation (`BleManager.java`, line 1814) correctly implements this rule:
```java
if (recoveryTriggered && isKnownSessionMember(room.hostPeerId)) {
    // accept first advertiser
}
```

The iOS implementation (`Ble.mm`, line 3123) only checks for the locally elected successor:
```objc
if ([room.hostPeerId isEqualToString:_migrationSuccessorId] &&
    [room.sessionId isEqualToString:_migrationSessionId])
```

If the iOS client elected successor A but successor B starts advertising first, the iOS client ignores B and waits for A. If A never advertises (e.g., A also elected B and is scanning), the iOS client times out and the session is lost. The Android client would accept B immediately.

### Origin

Code-to-spec divergence on iOS. GitHub issue #10 notes that this v3 change has been applied on Android but not iOS.

### Proposed Change

No specification change needed. Section 8.4 step 3 correctly defines the "first advertiser wins" rule. This item documents the iOS implementation gap.

However, strengthen the normative language of step 3 with a clarifying note:

> REQUIREMENT: The "first advertiser wins" rule (step 3) is essential for convergence when multiple peers independently elect different successors. An implementation that omits this step will fail to converge when the locally elected successor does not advertise, even if another valid successor is advertising. This is not an optimization -- it is a correctness requirement for the migration protocol's convergence guarantee.

### Reasoning

The "first advertiser wins" rule is the primary convergence mechanism for divergent elections. The spec already defines it correctly; the iOS implementation simply hasn't adopted it. Adding a normative note emphasizing that this is a correctness requirement (not an optimization) may prevent future implementations from treating it as optional.

### Known Tradeoffs

None. The spec is correct. The note adds emphasis without changing semantics.

### Dependencies

None.

---

## Item 9: Protocol Version Negotiation

### Problem Statement

Section 3.1 (Room Advertisement) uses a hardcoded `"LB1"` prefix with no version semantics beyond "starts with LB1." Section 4.1 (Packet Envelope) defines `Version = 1` with "Version mismatch causes the Packet to be silently dropped." There is no mechanism for a scanner to determine whether a discovered room uses a compatible protocol version before connecting, and no mechanism for a host to reject a client based on protocol version during the HELLO handshake.

As the protocol evolves through v2, v3, and now v4, the risk of version mismatch increases. A v3 client scanning for rooms will discover and attempt to join a v2 host's room. The connection will succeed at the GATT level, but the HELLO handshake may fail silently or behave unexpectedly because the v3 client sends a `join_intent` field that the v2 host does not parse. A v2 client joining a v3 host will succeed because the v3 spec's HELLO changes are backward-compatible, but a v4 client with breaking changes would not.

This is curated feature F-1, carried from the v2 cycle.

### Origin

Open feature F-1 (high priority, curated for v2 and v3 but not addressed). Architectural constraint: the protocol has evolved through three major versions with no forward/backward compatibility mechanism.

### Proposed Change

Add a protocol version field to the Room Advertisement and to the HELLO handshake.

**Room Advertisement (Section 3.1):** Change the prefix from `"LB1"` to `"LB"` followed by a single-character version indicator. The version indicator is an ASCII digit representing the major protocol version. For v4, this is `"LB4"`. Previous versions used `"LB1"` regardless of spec version; this change makes the prefix carry version semantics.

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

**Discovery (Section 3.4):** `DecodeRoom` checks for prefix `"LB"` and extracts the version digit. Rooms with an unrecognized version are still reported to the application (for display purposes) but are flagged as `incompatible = true`. The application SHOULD NOT attempt to join incompatible rooms. The `room_found` event (Section 12) gains a `proto_version` field (integer).

**HELLO payload (Section 4.3):** Extend the hello payload to include a protocol version field:
```
session_id|join_intent|proto_version
```
Where `proto_version` is a decimal integer string (e.g., `"4"`). For backward compatibility, a missing third field is treated as version 1.

**HELLO validation (Section 6.5):** Add a validation step after step 3d:
```
3f. If proto_version is present and does not match the host's protocol version:
    send join_rejected("incompatible_version") to device, disconnect, return.
```

Add `"incompatible_version"` to the `join_rejected` reasons table.

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
  - Malformed payload (non-hex session ID, invalid transport char, etc.)
    -> return null.
```

### Reasoning

Version negotiation prevents the most common cross-version failure: a client discovering and connecting to an incompatible host, wasting BLE resources and time on a connection that cannot succeed. The advertisement-level version indicator allows pre-connection filtering; the HELLO-level version field provides a definitive rejection for cases where the advertisement was ambiguous or cached. The change is wire-format compatible in the sense that the prefix is still 3 bytes and the total advertisement length is unchanged.

### Known Tradeoffs

- **Breaking change**: Changing `"LB1"` to `"LB4"` means v3 scanners will not recognize v4 rooms (they check for `"LB1"` prefix). This is intentional: v3 and v4 are not interoperable. However, it means a mixed-version deployment cannot discover rooms across versions. In the target environment (games where all players update together), this is acceptable.
- The single-digit version character limits the version space to 0-9. This is sufficient for the foreseeable evolution of the protocol. If more than 10 major versions are needed, the prefix length can be extended.
- Adding `proto_version` to the HELLO payload is a backward-compatible extension (missing field = version 1), but a v4 host rejecting a v1 client on version mismatch is a behavior change from v3 where the host would accept it.

### Dependencies

This change should be coordinated with Item 10 (app-level scoping) if both are accepted, as both modify the Room Advertisement format. Implementing them together avoids two separate format revisions.

---

## Item 10: App-Level Room Scoping via App Identifier

### Problem Statement

Section 3.1 (Room Advertisement) contains no application identifier. All applications sharing the BLE game network protocol discover each other's rooms during scanning. Room names are truncated to 8 bytes, making application-layer filtering impractical. A chess game and a card game running the same protocol on nearby devices will see each other's rooms, confusing users and wasting scan resources.

This is curated feature F-2, carried from the v2 cycle.

### Origin

Open feature F-2 (medium priority, curated for v2 and v3 but not addressed). Architectural constraint: the single GATT Service UUID means all protocol-compliant apps are indistinguishable at the BLE layer.

### Proposed Change

Add a 2-byte application identifier to the Room Advertisement, placed immediately after the protocol version field:

```
Offset  Length  Field
0       2       Prefix          "LB" (literal)
2       1       ProtoVersion    ASCII digit: major protocol version
3       2       AppID           2-char hex app identifier (00-FF)
5       6       SessionID       6-char hex
11      6       HostPeerID      6-char hex
17      1       Transport       'r' = Reliable, 's' = Resilient
18      1       MaxClients      ASCII digit '1'-'7'
19      1       PeerCount       ASCII digit '0'-'9'
20      0-6     RoomName        UTF-8, variable length (reduced from 0-8)
```

Total: 20-26 bytes (unchanged maximum).

The `AppID` is a 1-byte value encoded as 2 hex characters. Value `"00"` means "no app scoping" (backward compatible, matches all apps). Values `"01"` through `"FF"` are application-specific identifiers.

**Host API (Section 6.1):** `Host(roomName, maxClients, transport, appId)` gains an optional `appId` parameter. Default: `"00"`.

**Scan API (Section 6.2):** `Scan(appId)` gains an optional `appId` parameter. When provided and non-zero, the native layer filters scan results to only emit `room_found` for rooms with a matching `AppID`. When omitted or `"00"`, all rooms are reported (current behavior).

**Discovery (Section 3.4):** `DecodeRoom` extracts the `AppID` field. If the scanner has an active `appId` filter and the room's `AppID` does not match, the room is not reported.

```
FUNCTION Host(roomName, maxClients, transport, appId) -> void

  1. Assert BLE is available and permissions granted.
  2. Call Leave() to clean up any existing session.
  3. Let sessionId = GenerateShortID().
  4. Let roomName = NormalizeRoomName(roomName).
  5. Validate maxClients is in range [1, 7]. Clamp if outside.
  6. Let appId = appId or "00". Validate is 2-char hex. Default "00".
  7. Initialize membershipEpoch to 0.
  8. Open GATT Server.
  9. Create Service with Message Characteristic and CCCD.
  10. Add Service to GATT Server.
  11. On service added successfully:
      a. Call AdvertiseRoom() (includes appId in advertisement).
      b. Start Heartbeat timer.
      c. Emit hosted event with sessionId, local Peer ID, transport.

ERRORS:
  - Invalid appId format -> clamp to "00" (no scoping).
```

### Reasoning

App-level scoping eliminates cross-application room pollution at the BLE layer, before any GATT connection is established. The 2-hex-character encoding uses only 2 bytes of advertisement space, reducing the maximum room name from 8 to 6 characters -- a minimal cost. The `"00"` default preserves backward compatibility: apps that do not set an `appId` see all rooms and are seen by all apps, exactly as today.

### Known Tradeoffs

- Reduces maximum room name length from 8 to 6 characters. In the target environment (game names are short), this is acceptable.
- The 1-byte (256 values) app ID space is small. Applications must coordinate to avoid collisions. For the target use case (a small number of games using the protocol), this is sufficient. A registry mechanism is out of scope for the protocol spec.
- Backward incompatible with v3: a v3 scanner will attempt to parse the `AppID` bytes as part of the SessionID, producing garbled results. This is acceptable only if coordinated with the version negotiation change (Item 9), which causes v3 scanners to reject v4 advertisements at the prefix level.

### Dependencies

**Requires Item 9** (Protocol Version Negotiation). The advertisement format change is only safe if v3 scanners can identify and ignore v4 advertisements via the version prefix. Without version negotiation, deploying app scoping would silently corrupt room discovery for v3 clients.
