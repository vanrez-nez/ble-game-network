# Proposal A — BLE Game Network Protocol Specification v3

**Proposal ID:** a
**Baseline:** Protocol Specification v2.0.0 (2026-03-25)
**Sources examined:** Curated issues (I-1 through I-6), curated features (F-1, F-2), backlog issues (I-7), `BleManager.java` (Android native), `Ble.mm` (iOS native), `BLEService.swift` (iOS application layer), `lua/ble_net/config.lua`, `lua/ble_net/validation.lua`, `lua/ble_net/init.lua`

---

## Glossary

| Term | Definition |
|------|-----------|
| **shouldEmit** | A boolean derived at the moment of client disconnection that controls whether the disconnect decision tree may emit events or initiate recovery procedures. |
| **Departure Message** | A client-to-host control packet sent immediately before a client intentionally leaves a session, enabling the host to bypass reconnect grace for that peer. |
| **Connection Failure** | A GATT-level event indicating that a connection attempt did not result in a connected state, distinct from a disconnection of an established connection. |
| **Migration Acceptance Window** | A bounded time period after a successor host begins hosting during which it accepts `migration_resume` join intents from peers in the migrated session. |
| **Lifecycle Event** | A platform-level signal indicating a change in application execution state (foregrounding, backgrounding, suspension, termination) that may affect BLE resource availability. |
| **Permission Category** | A platform-agnostic grouping of BLE capabilities (scan, connect, advertise) that maps to one or more OS-level permissions. |

---

## Scope Statement

This proposal covers seven specification-level changes to v2.0.0, all grounded in implementation evidence from the Android and iOS native layers, the Lua application layer, and the curated issue backlog. The items address: (1) an undefined parameter in the client disconnect decision tree that both platforms independently derived, (2) the absence of a client-to-host departure message causing unnecessary reconnect grace delays, (3) a missing GATT connection failure path in ConnectToRoom that produces asymmetric handling between platforms, (4) a notification gap in unexpected host recovery that risks network splits, (5) undefined app lifecycle triggers for Leave() that cause Resilient-mode hosts to take the unexpected-recovery path instead of graceful migration on backgrounding, (6) an undocumented migration acceptance window that both platforms implement with a hardcoded duration, and (7) a MaxClients range inconsistency between the Lua validation layer and the wire format. All items rise to specification level because they require normative decisions that cannot be made by an individual implementation without risking interoperability divergence.

---

## Item 1: Define `shouldEmit` Semantics in Client Disconnect Decision Tree

### Problem Statement

Section 13 (Client Disconnect Decision Tree) uses `shouldEmit` as a branching parameter at steps 3, 4, and 5, but the specification never defines how this value is derived. The curated issue I-2 (from backlog I-3) describes the formula as `!clientLeaving && currentGattHandle == disconnectedHandle`. However, examination of both native implementations reveals a different reality:

- **Android** (`BleManager.java`, line 1935): `shouldEmit` is passed as `!clientLeaving` only — no GATT handle comparison.
- **iOS** (`Ble.mm`, line 1633): `shouldEmit` is assigned as `!_clientLeaving` only — no peripheral reference comparison.

Neither implementation checks whether the disconnected GATT handle matches the current handle. The backlog description of the derivation is inaccurate relative to the shipped code. The specification must define the actual semantics.

The interaction with `StopClientOnly()` remains relevant even without the handle check. `StopClientOnly()` nulls the GATT reference (`clientGatt = null` on Android at line 1917, `_connectedPeripheral = nil` on iOS at line 1576) and is called in ConnectToRoom step 2. If a disconnect callback fires for the old connection after `StopClientOnly()` has run (race condition), the `clientLeaving` flag — which was reset to `false` in ConnectToRoom step 4 — will produce `shouldEmit = true`, potentially triggering spurious recovery attempts during an active reconnect or migration join. The specification must address this state.

### Origin

Code-to-spec divergence confirmed by examining both platform implementations. The curated issue I-2 correctly identified the problem but inaccurately described the derivation formula used by shipped code.

### Proposed Change

Replace the current Section 13 preamble with an explicit derivation of `shouldEmit` and add a reconnect-guard condition. Amend Section 13 as follows:

**Section 13 — Client Disconnect Decision Tree**

```
OnClientDisconnected(device):

  DERIVE shouldEmit:
    1. If clientLeaving is true, set shouldEmit = false.
    2. Else if reconnectJoinInProgress is true AND device is not the
       device from the current reconnect attempt, set shouldEmit = false.
    3. Else if migrationJoinInProgress is true AND device is not the
       device from the current migration join attempt, set shouldEmit = false.
    4. Else set shouldEmit = true.

  Let wasJoined = clientJoined.

  1. Call StopClientOnly() to clean up GATT state.
  2. If active Migration exists:
       -> BeginMigrationReconnect(). Return.
  3. If shouldEmit AND wasJoined AND transport is Resilient:
       -> Attempt BeginUnexpectedHostRecovery().
       -> If successful, return.
  4. If shouldEmit AND wasJoined:
       -> Attempt BeginClientReconnect().
       -> If successful, return.
  5. If shouldEmit:
       -> Call FinishLeave(null).
       -> If wasJoined: emit session_ended("host_lost").
       -> Else: emit error("join_failed", detail).
  6. If none of the above returned a result:
       -> Perform silent cleanup with no events emitted.
```

FUNCTION OnClientDisconnected(device) -> void

  1. Capture wasJoined = clientJoined.
  2. Derive shouldEmit:
     2a. If clientLeaving is true -> shouldEmit = false.
     2b. Else if reconnectJoinInProgress is true AND device is not the
         GATT device for the current reconnect attempt -> shouldEmit = false.
     2c. Else if migrationJoinInProgress is true AND device is not the
         GATT device for the current migration attempt -> shouldEmit = false.
     2d. Else -> shouldEmit = true.
  3. Call StopClientOnly().
  4. If migrationInProgress is true:
     4a. Call BeginMigrationReconnect(). Return.
  5. If shouldEmit is true AND wasJoined is true AND transport is Resilient:
     5a. Call BeginUnexpectedHostRecovery().
     5b. If successful, return.
  6. If shouldEmit is true AND wasJoined is true:
     6a. Call BeginClientReconnect().
     6b. If successful, return.
  7. If shouldEmit is true:
     7a. Call FinishLeave(null).
     7b. If wasJoined is true: emit session_ended with reason "host_lost".
     7c. Else: emit error with code "join_failed" and platform-specific detail.
  8. Otherwise: silent cleanup, no events emitted.

ERRORS:
  - Disconnect callback for stale device during active join -> suppressed (step 2b/2c)
  - Disconnect during intentional leave -> suppressed (step 2a)

### Reasoning

Defining `shouldEmit` eliminates an ambiguity that forced both platform teams to independently derive behavior. The reconnect-guard conditions (steps 2b, 2c) prevent a class of race conditions where a stale disconnect callback from a previous GATT connection fires after a new connection attempt has begun. Without these guards, the disconnect for the old connection can trigger recovery logic that conflicts with the already-in-progress reconnect or migration join.

### Known Tradeoffs

The device-identity check in steps 2b and 2c requires the implementation to retain the device reference from the current join attempt in a field accessible to the disconnect callback. Both platforms already store this implicitly (Android: `clientGatt`, iOS: `_connectedPeripheral`), but the specification now makes this storage normative.

### Dependencies

None. This item is self-contained.

---

## Item 2: Add Client-to-Host Departure Control Message

### Problem Statement

Section 4.3 (Control Message Types) defines no control message in the Client -> Host direction for signaling intentional departure. Section 6.6 (Leave) defines `FinishLeave()` as a local operation that tears down GATT state but sends no notification to the host. The host receives the same `STATE_DISCONNECTED` callback for both intentional leaves and unexpected BLE drops, so every client departure enters the 10-second reconnect grace window (Section 7.2), delaying roster cleanup and holding a client slot.

This is confirmed as a real protocol gap by two independent observations:

1. The iOS application layer (`BLEService.swift`, lines 526–565) implements a `.leave` packet type at the application layer, including a cooperative delay to allow the packet to transmit before teardown. This application-layer workaround proves the need exists.
2. Curated issue I-1 (from backlog I-1, sourced from GitHub issue #1) identifies this as a critical specification gap.

### Origin

Spec gap confirmed by code analysis (iOS application-layer workaround) and GitHub issue #1.

### Proposed Change

Add a `"client_leaving"` control message type to Section 4.3 and amend the Leave procedure to send it.

**Addition to Section 4.3 (Control Message Types table):**

| MsgType | Direction | Payload | Purpose |
|---------|-----------|---------|---------|
| `"client_leaving"` | Client -> Host | Empty | Client signals intentional departure |

**Amend Section 6.6 (Leave) — client path:**

FUNCTION Leave() -> void

  1. If hosting with Resilient transport and clients exist:
     1a. Attempt BeginGracefulMigration().
     1b. If successful, return.
  2. If connected as client and clientJoined is true:
     2a. Send `client_leaving` control packet (from=localPeerID, to=hostPeerID, type="client_leaving", payload=empty).
     2b. Set clientLeaving = true.
     2c. Schedule a departure delay of 100ms.
     2d. On departure delay expiry: call FinishLeave(null).
     2e. Return.
  3. Call FinishLeave(reason=null for client, "host_left" for host).

ERRORS:
  - Write failure on client_leaving send -> proceed with FinishLeave immediately (best-effort delivery).

**Addition to Section 14 (Host Client-Disconnect Decision Tree):**

Add a handler for the `client_leaving` control message on the host side:

FUNCTION OnClientLeavingReceived(sourceDeviceKey, packet) -> void

  1. Let peerId = packet.fromPeerId. If empty, ignore.
  2. Look up peerId in connected clients. If not found, ignore.
  3. If peerId is in reconnect grace, cancel grace timer for peerId.
  4. Remove peerId from connected clients map.
  5. Remove peerId from Session Peer roster. Increment membershipEpoch.
  6. Emit peer_left event with reason "left".
  7. Send peer_left control (reason="left") to all remaining connected clients.
  8. Broadcast roster_snapshot to all connected clients.
  9. Update advertisement (peer count changed).

ERRORS:
  - client_leaving from unknown device -> silently ignored (step 2).

**Amend Section 7.2 (Host Reconnect Grace):**

Add to the beginning of `BeginPeerReconnectGrace`:

> Before entering reconnect grace, check whether a `client_leaving` message was received from this peer within the current heartbeat interval. If so, skip reconnect grace and proceed directly to removal (steps 5–9 of `OnClientLeavingReceived`).

### Reasoning

This change eliminates the 10-second reconnect grace delay for every intentional client departure. It converts a class of delayed cleanups into immediate ones. The departure delay (100ms) in the client path provides a brief window for the BLE write to complete before the GATT teardown begins, matching the pattern already used by the iOS application layer (which uses 560ms, but 100ms is sufficient at the protocol level since only a single control packet is in flight).

The message name `"client_leaving"` is chosen over `"leave"` to avoid collision with the application-layer concept and to maintain the directional naming convention used by other control messages (`peer_joined`, `peer_left`, `session_migrating`).

### Known Tradeoffs

1. **Best-effort delivery.** BLE writes are not guaranteed. If the `client_leaving` message fails to deliver, the host falls back to the existing reconnect grace path. This is acceptable — the grace window is the safety net, not the primary path.
2. **100ms departure delay.** This adds latency to the client-side leave operation. Applications that call Leave() during shutdown must account for this delay. The delay can be shortened but not eliminated if the message is to have any chance of delivery.
3. **Message ordering.** If the host receives the BLE disconnect event before the `client_leaving` message is processed (possible under BLE stack timing), the host may still enter reconnect grace briefly. The guard in BeginPeerReconnectGrace mitigates this but does not eliminate it entirely.

### Dependencies

None. This item is self-contained and backward-compatible. Hosts that do not recognize `client_leaving` will silently ignore the control message (unknown control types are not errors in the current spec) and proceed with the existing reconnect grace path.

---

## Item 3: Add GATT Connection Failure Path to ConnectToRoom

### Problem Statement

Section 6.3 (ConnectToRoom) step 7 defines behavior "On GATT connected" but specifies no step for GATT connection failure. The two platform implementations handle this gap differently:

- **iOS** (`Ble.mm`, lines 1611–1624): Implements an explicit `didFailToConnectPeripheral` callback that calls `stopClientOnly()` and emits a `join_failed` error event. This is a clean, defined path.
- **Android** (`BleManager.java`, line 1935): Has no equivalent explicit handler. When a GATT connection attempt fails, Android fires `onConnectionStateChange` with `STATE_DISCONNECTED` and a non-zero status code. This is routed through the same `onClientDisconnected` path as a normal disconnect, which — depending on the `clientJoined` and `shouldEmit` state — may trigger reconnect logic, recovery logic, or silent cleanup. The behavior is non-deterministic relative to the spec.

During reconnect, this asymmetry is particularly problematic. If `ConnectToRoom` is called from `OnScanResultDuringReconnect` and the GATT connection fails, the Android path may re-trigger reconnect (since `shouldEmit = true` and `wasJoined = true`), while iOS emits `join_failed` and terminates. Neither behavior is specified.

This is curated issue I-4 (from backlog I-2, sourced from GitHub issue #3).

### Origin

Code-to-spec divergence. The two platform implementations have irreconcilable behavior for the same scenario because the specification does not define the expected behavior.

### Proposed Change

Add step 8 to ConnectToRoom in Section 6.3 for the GATT connection failure case, and define how this interacts with reconnect and migration join states.

**Amend Section 6.3 (ConnectToRoom), add after step 7:**

FUNCTION ConnectToRoom(room, migrationJoin) -> void

  1. If already connected to the same room/session/host and not leaving, return (duplicate join guard).
  2. Stop scan. Call StopClientOnly() to clean up prior connection.
  3. Store session info: joinedRoomId, joinedSessionId, hostPeerId, transport, maxClients.
  4. Set clientLeaving = false, clientJoined = false.
  5. If not migrationJoin and not reconnect join, reset Session Peer roster.
  6. Connect to the Room's BLE device via GATT Client with autoConnect=false.
  7. On GATT connected:
     a. Request MTU (desired: 185, minimum: 23).
     b. Discover services.
     c. Find Message Characteristic.
     d. Enable notifications via CCCD descriptor write.
     e. Call CompleteLocalJoin().
  8. On GATT connection failure:
     a. Call StopClientOnly().
     b. If reconnectJoinInProgress is true:
        i.  Set reconnectJoinInProgress = false.
        ii. Resume reconnect scan (do not call FailReconnect — the reconnect timeout is still running and may find the host again).
     c. Else if migrationJoinInProgress is true:
        i.  Set migrationJoinInProgress = false.
        ii. Resume migration scan (do not call FailMigration — the migration timeout is still running and may find the successor again).
     d. Else (fresh join):
        i.  Call FinishLeave(null).
        ii. Emit join_failed event with reason "connection_failed" and platform-specific detail.

ERRORS:
  - GATT connection failure during fresh join -> session_ended not emitted (client was never joined); join_failed emitted instead.
  - GATT connection failure during reconnect -> reconnect scan resumes; failure is transient until reconnect timeout expires.
  - GATT connection failure during migration -> migration scan resumes; failure is transient until migration timeout expires.

### Reasoning

The proposed handling distinguishes between fresh join (where failure is terminal and the application should be notified) and reconnect/migration (where failure is transient and the existing timeout mechanism should be allowed to run). This matches the iOS `didFailToConnectPeripheral` behavior for fresh joins while providing a better reconnect path than either platform currently implements.

Resuming the scan after a failed reconnect/migration connection attempt rather than immediately failing gives the protocol a retry opportunity within the existing timeout window. The host may have temporarily been unreachable (e.g., Android BLE stack congestion), and a second scan result may succeed.

### Known Tradeoffs

1. **Resume-scan behavior is new.** Neither platform currently resumes scanning after a failed GATT connection during reconnect. Implementing this requires the scan to be restartable mid-reconnect, which both platforms support but neither currently does in this code path.
2. **No explicit retry limit.** The proposed change relies on the reconnect/migration timeout as the only bound on retries. In pathological BLE environments, the client may repeatedly fail and retry within the timeout window. This is bounded by the timeout but may produce unnecessary BLE traffic.

### Dependencies

Interacts with Item 1 (shouldEmit definition). The reconnect-guard conditions in Item 1 (steps 2b, 2c) protect against stale disconnect callbacks that may fire for the failed connection attempt after the scan has resumed.

---

## Item 4: Add Cross-Client Notification After Unexpected Host Recovery

### Problem Statement

Section 8.2 (BeginUnexpectedHostRecovery) defines successor election as a purely local operation. When the elected successor becomes the new host and starts advertising, it sends no notification to the remaining clients. Each remaining client independently runs successor election using its own local roster state. If clients have different `membership_epoch` values (e.g., one client received a `roster_snapshot` that another missed), they may elect different successors, causing a network split.

The convergence fallback (Section 8.3) handles the case where a successor does not begin advertising, but it does not address the case where multiple clients each believe they are the successor and begin advertising simultaneously.

This is curated issue I-3 (from backlog I-5, sourced from GitHub issue #5).

### Origin

Architectural constraint. The spec was written assuming that all clients would have identical roster state at the moment of host loss. In practice, roster snapshots can be lost or delayed (BLE notification delivery is not guaranteed), producing divergent election inputs.

### Proposed Change

Amend Section 8.2 to require the new host to broadcast a `session_migrating` notification after successfully starting its GATT server. Amend Section 8.4 to define how remaining clients handle this notification during unexpected recovery.

**Amend Section 8.2 (BeginUnexpectedHostRecovery), add after step 9:**

FUNCTION BeginUnexpectedHostRecovery() -> boolean

  1. If transport is not Resilient, return false.
  2. If no valid session info, return false.
  3. Remove old Host from Session Peer roster. Add self.
  4. Remove any peers known to be in reconnect grace from the candidate set.
  5. Let successor = SelectRecoverySuccessor(oldHostID).
  6. If no successor, return false.
  7. Create MigrationInfo. Set becomingHost = (successor == localPeerID).
  8. Call StartMigration(info).
  9. Call BeginMigrationReconnect().
  10. If becomingHost is true AND GATT server started successfully:
      a. Encode migration payload: sessionId|localPeerID|maxClients|roomName|membershipEpoch.
      b. This payload is embedded in the Room Advertisement (same session ID, new host peer ID).
      c. Remaining clients discover the new host via scan and connect with join_intent=migration_resume.
  11. Return true.

ERRORS:
  - GATT server fails to start -> successor is treated as failed; convergence fallback applies (Section 8.3).

**Amend Section 8.4 (Migration Reconnect) — client-side scan behavior during unexpected recovery:**

When a client is scanning for the successor during unexpected recovery and discovers a Room advertisement with:
- The same session ID as the current session, AND
- A host Peer ID matching the expected successor

the client connects with `join_intent=migration_resume`. Upon receiving `hello_ack` and `roster_snapshot` from the new host, the client calls `CompleteMigrationResume()`.

When a client discovers a Room advertisement with:
- The same session ID, AND
- A host Peer ID that does NOT match the locally elected successor but IS a valid session member

the client cancels its own successor election, accepts the advertising peer as the new host, and connects with `join_intent=migration_resume`. This resolves divergent elections by treating the first advertising successor as authoritative.

FUNCTION OnScanResultDuringMigration(room) -> void

  1. If room.sessionId does not match the current session ID, ignore.
  2. If room.hostPeerId matches the locally elected successor:
     2a. Connect to room with migrationJoin=true.
  3. Else if room.hostPeerId is a known session member (present in local roster):
     3a. Accept this peer as the new successor.
     3b. Update migration info with new successor.
     3c. Connect to room with migrationJoin=true.
  4. Else: ignore (unknown advertiser, possibly a different session).

ERRORS:
  - Connection to non-elected successor fails -> resume scan, migration timeout still applies.

### Reasoning

This change resolves the divergent election problem by establishing a "first advertiser wins" rule. Rather than requiring all clients to agree on a successor before anyone starts hosting, the protocol allows independent elections and then converges on whichever successor actually starts advertising first. This is more robust than requiring synchronized election because it tolerates the roster-state divergence that causes the problem in the first place.

The approach avoids adding a new control message for notification (which the new host could not reliably deliver anyway, since remaining clients are not yet connected to it). Instead, it relies on the Room Advertisement as the notification mechanism — which is the same mechanism already used for discovery.

### Known Tradeoffs

1. **Dual-host risk.** If two clients both believe they are the successor and both start GATT servers, two rooms with the same session ID will be advertising simultaneously. The "first discovered wins" rule resolves this for scanning clients, but the losing host will continue advertising until its own migration timeout expires with no clients connecting. The spec should acknowledge this transient state but it is self-resolving.
2. **Security.** Any session member could start advertising with the session ID. There is no authentication of the successor. This is an existing limitation of the protocol, not introduced by this change.

### Dependencies

None. This item refines the existing migration reconnect flow without introducing new message types.

---

## Item 5: Define App Lifecycle Triggers for Leave()

### Problem Statement

Section 6.6 (Leave) defines the procedure but provides no guidance on when the platform layer should auto-invoke it. When a Resilient-mode host goes to background (app switch, screen lock, incoming call), the OS may tear down the BLE connection without the protocol layer having an opportunity to send `session_migrating`. Clients fall into the unexpected-host-recovery path (Section 8.2) instead of the graceful migration path (Section 8.1), resulting in a worse user experience and higher failure probability.

The iOS application layer (`BLEService.swift`, lines 269–280) already tracks `UIApplication.applicationState` and has background-time-remaining logic, confirming that lifecycle handling is necessary for production behavior. However, this logic exists only at the application layer and is not part of the protocol specification. The Android native layer (`BleManager.java`) has no lifecycle handling at all.

This is curated issue I-5 (from backlog I-4, sourced from GitHub issue #4).

### Origin

Architectural constraint. BLE is a system-managed resource on both iOS and Android. The OS can and does terminate BLE connections when applications are backgrounded. The specification was written assuming continuous foreground execution.

### Proposed Change

Add a new Section 6.7 defining lifecycle events and their mapping to protocol actions.

**New Section 6.7 — Application Lifecycle Integration**

The protocol layer must register for platform-level application lifecycle events and invoke protocol actions in response. The following table defines the required mappings:

| Lifecycle Event | Condition | Protocol Action |
|----------------|-----------|----------------|
| App entering background | Hosting with Resilient transport AND at least one connected client | Invoke Leave() (triggers graceful migration via Section 6.6 step 1) |
| App entering background | Hosting with Reliable transport | Invoke Leave() (sends session_ended, tears down) |
| App entering background | Connected as client | No automatic action (client reconnect handles any resulting disconnect) |
| App will terminate | Any active session | Invoke Leave() with no departure delay (immediate teardown) |

FUNCTION OnAppLifecycleChanged(newState) -> void

  1. If newState is "background" or "inactive":
     1a. If hosting is true AND transport is Resilient AND connected client count > 0:
         i. Invoke Leave(). This triggers BeginGracefulMigration() per Section 6.6 step 1.
     1b. Else if hosting is true:
         i. Invoke Leave(). This sends session_ended and tears down.
     1c. If connected as client: no automatic action.
  2. If newState is "terminating":
     2a. Invoke Leave() with immediate teardown (skip departure delay).
  3. If newState is "foreground":
     3a. No automatic action. If the session was lost during background, the client disconnect decision tree (Section 13) will have already handled it.

ERRORS:
  - Leave() fails during background transition -> emit error("leave_failed", detail). Session may enter unexpected recovery on the client side.
  - Insufficient background execution time for graceful migration -> migration may be interrupted by OS. Clients fall back to unexpected host recovery.

**Platform mapping (informative, not normative):**

| Lifecycle Event | Android | iOS |
|----------------|---------|-----|
| App entering background | `onPause()` or `onStop()` in Activity | `applicationDidEnterBackground` or `willResignActive` |
| App will terminate | `onDestroy()` in Activity | `applicationWillTerminate` |
| App entering foreground | `onResume()` in Activity | `applicationDidBecomeActive` |

### Reasoning

This change makes graceful migration the normative path for the most common cause of host loss (app backgrounding), rather than an exceptional path triggered only by explicit user action. The iOS application layer already implements a version of this at the wrong layer — promoting it to the specification ensures consistent behavior across platforms and applications.

The decision to not auto-invoke Leave() for backgrounded clients is deliberate. Clients benefit from maintaining their session state during brief background transitions (e.g., receiving a phone call). If the BLE connection drops, the existing reconnect mechanism handles it. Auto-leaving on background would cause unnecessary session disruption for clients.

### Known Tradeoffs

1. **OS execution time.** On iOS, `applicationDidEnterBackground` provides limited background execution time (approximately 5–30 seconds, varying by OS version). The 400ms migration departure delay (Section 8.1 step 7) fits within this window, but the full migration cycle (clients reconnecting to the new host) will not complete before the original host is suspended. This is acceptable — the clients use the migration reconnect mechanism which is independent of the original host's execution.
2. **Android variability.** Android does not guarantee BLE teardown on backgrounding. Some devices maintain BLE connections indefinitely in background. The proposed lifecycle handling will invoke Leave() on `onPause()`/`onStop()` even when the BLE connection would have survived. This is a conservative choice that prioritizes consistent behavior over opportunistic session preservation.
3. **Game-specific overrides.** Some games may want to maintain hosting in background (e.g., a turn-based game where the host role is not latency-sensitive). The spec does not provide an opt-out mechanism for this auto-leave behavior. This could be addressed in a future revision with a configuration flag.

### Dependencies

None. This item builds on the existing Leave() and graceful migration mechanisms without modifying them.

---

## Item 6: Define Migration Acceptance Window Duration

### Problem Statement

Section 6.5 step 3e defines a rejection condition: "If `joinIntent` is `migration_resume` and the host is not in a migration-acceptance state: send `join_rejected('migration_mismatch')`." However, the specification never defines:

1. When the migration-acceptance state begins.
2. When the migration-acceptance state ends.
3. What duration bounds the window.

The Android implementation (`BleManager.java`, lines 2599–2602) hardcodes the acceptance window to `MIGRATION_TIMEOUT_MS` (3000ms). After hosting begins, a delayed handler sets `migrationInProgress = false` after 3 seconds. This value is not documented in Section 17 (Timeouts, Intervals, and Limits).

Section 8.5 (CompleteMigrationResume) defines that the client sets its local `membershipEpoch` from the migration control message, but does not define when the new host should stop accepting `migration_resume` intents and begin treating all new connections as fresh joins.

### Origin

Code-to-spec divergence. Both platforms implement a bounded acceptance window, but the duration is undocumented and its relationship to other timeouts (Migration Timeout, Reconnect Timeout) is not specified.

### Proposed Change

Add the Migration Acceptance Window to Section 17 and define its start/end conditions in Section 8.4.

**Addition to Section 17 (Timeouts, Intervals, and Limits):**

| Constant | Default | Purpose |
|----------|---------|---------|
| Migration Acceptance Window | 3s | Duration after successor begins hosting during which `migration_resume` join intents are accepted |

**Amend Section 8.4 (Migration Reconnect) — host-side acceptance:**

When the successor begins hosting a migrated session:

FUNCTION BeginHostingMigratedSession(migrationInfo) -> void

  1. Start GATT server with migrated session info (sessionId, roomName, maxClients, membershipEpoch).
  2. Set migrationAcceptanceActive = true.
  3. Begin advertising the room.
  4. Start Heartbeat timer.
  5. Emit hosted event.
  6. Schedule Migration Acceptance Window timer (default 3 seconds).
  7. On Migration Acceptance Window expiry:
     7a. Set migrationAcceptanceActive = false.
     7b. Any subsequent join with intent=migration_resume is rejected with "migration_mismatch".

ERRORS:
  - GATT server fails to start -> emit error, session is lost.
  - No peers connect within acceptance window -> window expires, host continues operating with empty roster (peers that arrive later with fresh join intent are accepted normally).

### Reasoning

Tying the acceptance window to 3 seconds — the same value as Migration Timeout — ensures that any client that has not found and connected to the new host within its own migration timeout will also have been excluded from the acceptance window. This creates a clean temporal boundary: peers that make it through migration are accepted; peers that don't have their migration time out and receive `session_ended`.

The explicit flag (`migrationAcceptanceActive`) replaces the overloaded `migrationInProgress` flag used by the Android implementation. `migrationInProgress` serves double duty as both "I am currently migrating" and "I am accepting migration joins," which produces confusing semantics when the successor's own migration state completes but the acceptance window is still open.

### Known Tradeoffs

1. **Window too short.** In congested BLE environments, 3 seconds may not be enough for all clients to discover the new host and complete the GATT connection + HELLO handshake. However, matching it to Migration Timeout ensures consistency — if a client's migration times out, the acceptance window is also expired.
2. **Window too long.** A 3-second acceptance window means the new host will accept stale migration_resume intents for 3 seconds even if all expected peers have already connected. This is a minor inefficiency with no correctness impact.

### Dependencies

None. This item documents existing implementation behavior and adds it to the specification constants table.

---

## Item 7: MaxClients Range Harmonization

### Problem Statement

The specification defines three related constraints on `MaxClients`:

- Section 3.1 (Room Advertisement): `MaxClients` field is "ASCII digit '1'-'7'", a single character.
- Section 6.1 step 5 (Hosting): "Clamp *maxClients* to range [1, 7]."
- The wire format physically cannot represent values outside this range (single ASCII digit).

The Lua validation layer (`lua/ble_net/config.lua`, line 18) defines `max_clients = 8` as the upper bound. The `validation.lua` module uses this value to validate user input:

```lua
-- config.lua line 18
max_clients = 8,

-- validation.lua line 74
if integer < limits.min_clients or integer > limits.max_clients then
  return nil, "out_of_range"
end
```

This permits a value of 8 to pass Lua-layer validation and reach the native layer, where it is silently clamped to 7 by both implementations:

- Android (`BleManager.java`, line 1076): `maxClients = Math.max(1, Math.min(maxClientsParam, 7));`
- iOS (`Ble.mm`, line 1293): `_maxClients = MAX(1, MIN(maxClients, 7));`

The user-facing behavior is that setting `max_clients = 8` silently becomes 7 with no error or warning. This is curated as backlog issue I-7.

### Origin

Code-to-spec divergence between the Lua application layer and the wire format constraint. The native layer is correct; the Lua layer is overly permissive.

### Proposed Change

The specification already correctly defines the range as [1, 7]. No specification text change is required. However, the spec should add an explicit statement that application-layer validation must not accept values outside the wire-representable range.

**Amend Section 6.1 step 5:**

Current: "Clamp *maxClients* to range [1, 7]."

Proposed: "Validate *maxClients* is in range [1, 7]. If outside this range, clamp to the nearest bound. Application-layer validation should reject values outside [1, 7] before they reach the protocol layer, rather than relying on silent clamping."

This is a non-breaking clarification. The code fix (changing `config.lua` line 18 from `8` to `7`) is an implementation task, not a spec change, but the spec text should make the expectation clear.

FUNCTION ValidateMaxClients(value) -> integer

  1. If value < 1, set value = 1.
  2. If value > 7, set value = 7.
  3. Return value.

ERRORS:
  - Value outside [1, 7] -> clamped silently at protocol layer. Application layers should surface this as a validation error before reaching the protocol layer.

### Reasoning

Silent clamping is a source of user confusion. The specification should state the expectation that validation happens at the application layer, not just at the protocol layer. This prevents a class of bugs where the application layer and the protocol layer disagree on valid ranges.

### Known Tradeoffs

Adding "should" language for application-layer validation is advisory, not normative. Implementations that only validate at the native layer will still produce correct wire behavior. The advisory language helps but does not enforce consistency.

### Dependencies

None. This item is a documentation clarification with no behavioral change to the protocol.

---

*End of proposal.*
