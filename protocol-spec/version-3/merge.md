# Consolidated Specification — BLE Game Network Protocol v3

**Baseline:** Protocol Specification v2.0.0 (2026-03-25)
**Inputs:** Proposal A, Proposal B
**Curated Issues Addressed:** I-1, I-2, I-3, I-4, I-5
**Date:** 2026-03-27

---

## Glossary Additions

| Term | Definition |
|------|-----------|
| **shouldEmit** | A boolean derived at the moment of client disconnection from `NOT clientLeaving`, captured before `StopClientOnly()` executes, that controls whether the disconnect decision tree may emit events or initiate recovery procedures. |
| **FinishLeaveClient** | A client-only teardown procedure that cleans up GATT client state, write queues, dedup state, and fragment assemblies without affecting host state. Distinguished from the full `FinishLeave()` which tears down all session state including host. |
| **Departure Message** | A `"client_leaving"` control packet sent from client to host immediately before intentional disconnection, enabling the host to bypass reconnect grace for that peer. Best-effort delivery; the grace timer is the fallback. |
| **Connection Failure** | A GATT-level event indicating that a connection attempt did not result in a connected state, distinct from a disconnection of an established connection. |
| **Migration Acceptance Window** | A bounded time period (default 3s) after a successor host begins hosting during which it accepts `migration_resume` join intents from peers in the migrated session. |
| **Lifecycle Event** | A platform-level signal indicating a change in application execution state (foregrounding, backgrounding, termination) that may affect BLE resource availability. |

---

## Change 1: Define `shouldEmit` Derivation and Reconnect Guards in Client Disconnect Decision Tree

### Objective

Define the derivation of `shouldEmit` in Section 13 (Client Disconnect Decision Tree), which the v2 spec uses as the primary branching condition at steps 3-6 but never defines. This eliminates an ambiguity that forced both platform teams to independently derive behavior, and adds reconnect-guard conditions that prevent a class of race conditions where stale disconnect callbacks conflict with in-progress reconnect or migration joins.

### Rationale

Both proposals independently identified this as the highest-priority gap. The derivation is merged from both inputs:

- **From Proposal B:** The function signature changes from parameterized `OnClientDisconnected(wasJoined, shouldEmit)` to zero-argument, with `wasJoined` and `shouldEmit` captured as preconditions *before* `StopClientOnly()` executes. This eliminates the ordering hazard where `StopClientOnly()` nulls the GATT reference before the values are captured. Proposal B's mandated capture order (step 1 before step 2) is adopted because the ordering matters for correctness and was previously implicit.

- **From Proposal A:** Reconnect-guard conditions are added to the derivation (steps 2b, 2c). These suppress `shouldEmit` when a disconnect callback fires for a stale GATT connection during an active reconnect or migration join attempt. Without these guards, a disconnect for a *previous* connection can trigger recovery logic that conflicts with the already-in-progress join. Both platforms store the current device reference (`clientGatt` on Android, `_connectedPeripheral` on iOS), making this check implementable without new state.

- **From Proposal B (Item 4):** Steps 6 and 7 reference `FinishLeaveClient()` instead of `FinishLeave(null)`, matching the actual implementation behavior and protecting host state during migration (see Change 4).

Proposal B's simpler derivation (`NOT clientLeaving` only, without device-identity guards) was considered but rejected as insufficient. The stale-disconnect race condition identified by Proposal A is real: when `ConnectToRoom` calls `StopClientOnly()` and then initiates a new GATT connection, the disconnect callback for the *old* connection arrives with `clientLeaving=false`, producing `shouldEmit=true` and triggering spurious recovery. The device-identity guards close this gap.

### Specification

Replace Section 13 with:

```
OnClientDisconnected():

PRECONDITION:
  Let wasJoined = clientJoined (true if hello_ack was received for current connection).

FUNCTION OnClientDisconnected() -> void

  1. Capture wasJoined from precondition above.
  2. Derive shouldEmit:
     2a. If clientLeaving is true -> shouldEmit = false.
     2b. Else if reconnectJoinInProgress is true AND the disconnected
         device is not the GATT device for the current reconnect attempt
         -> shouldEmit = false.
     2c. Else if migrationJoinInProgress is true AND the disconnected
         device is not the GATT device for the current migration attempt
         -> shouldEmit = false.
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
     7a. Call FinishLeaveClient().
     7b. If wasJoined is true: emit session_ended with reason "host_lost".
     7c. Else: emit error with code "join_failed" and platform-specific detail.
     7d. Return.
  8. Otherwise:
     8a. Call FinishLeaveClient(). No events emitted.

ERRORS:
  - Disconnect callback for stale device during active join -> suppressed (step 2b/2c).
  - Disconnect during intentional leave -> suppressed (step 2a).
```

**Key invariants:**
- `wasJoined` and `shouldEmit` are captured *before* `StopClientOnly()` modifies state (step 2 before step 3).
- The derivation is defined as `NOT clientLeaving` with device-identity guards, not as a GATT handle comparison. Implementations must not use handle comparison, which fails when `StopClientOnly()` nulls the handle before the callback fires.
- Steps 7 and 8 call `FinishLeaveClient()` (Change 4), not full `FinishLeave()`.

---

## Change 2: Add Client-to-Host Departure Control Message

### Objective

Add a `"client_leaving"` control message from client to host to signal intentional departure, enabling the host to bypass the 10-second reconnect grace window for intentional leaves. This eliminates a delay on every intentional client departure that holds a client slot and delays roster cleanup.

### Rationale

Both proposals agree on the problem (curated issue I-1) and the solution shape: a best-effort message sent before disconnect, with the grace timer as fallback. The merge takes the architectural approach from each:

- **From Proposal B:** The host records the departure *intent* on message receipt but does not immediately remove the peer. The actual removal happens in the existing `OnHostClientDisconnected` handler when the disconnect callback fires and finds a recorded departure intent. This two-phase design keeps removal logic in one code path and avoids the race condition that Proposal A's immediate-removal approach creates (where the host might process both the departure message and the disconnect callback as independent removal events).

- **From Proposal A:** The message name `"client_leaving"` is adopted over Proposal B's `"departure"` to maintain the directional naming convention used by other control messages (`peer_joined`, `peer_left`, `session_migrating`). The `clientLeaving` flag is set before scheduling the departure delay, matching the existing flag semantics.

- **From Proposal B:** The Departure Send Timeout is added to Section 17, which is good practice for any new timeout constant.

### Specification

**Addition to Section 4.3 (Control Message Types table):**

| MsgType | Direction | Payload | Purpose |
|---------|-----------|---------|---------|
| `"client_leaving"` | Client -> Host | Empty | Client signals intentional departure |

**Amend Section 6.6 (Leave) — client path:**

```
FUNCTION Leave() -> void

  1. If hosting with Resilient transport and clients exist:
     1a. Attempt BeginGracefulMigration().
     1b. If successful, return.
  2. If connected as client AND clientJoined is true:
     2a. Encode and send a "client_leaving" control Packet
         (from=localPeerID, to=hostPeerID, type="client_leaving", payload=empty).
     2b. Set clientLeaving = true.
     2c. Wait up to Departure Send Timeout (100ms) for write callback.
         On timeout or write failure, proceed immediately.
     2d. Call FinishLeave(null).
     2e. Return.
  3. Call FinishLeave(reason=null for client, "host_left" for host).

ERRORS:
  - Write failure in step 2c is non-fatal. The departure message is best-effort;
    the host's grace timer serves as the fallback for delivery failure.
```

**Addition to host-side control message handling:**

```
FUNCTION OnClientLeavingReceived(sourceDeviceKey, packet) -> void

  1. Let peerId = packet.fromPeerId.
  2. If peerId is empty or not in connected clients, return.
  3. Record departure intent for peerId with current timestamp.
  4. Do not disconnect the device. The client will disconnect itself.

ERRORS:
  - client_leaving from unknown peer -> silently ignored (step 2).
```

**Amend Section 14 (Host Client-Disconnect Decision Tree):**

```
FUNCTION OnHostClientDisconnected(deviceKey) -> void

  1. Remove device from pending clients, MTU map, notification queues.
  2. Look up Peer ID from device-peer map. Remove mapping.
  3. If Peer ID found:
     3a. Remove from connected clients map.
     3b. If a departure intent was recorded for this Peer ID
         within the last Departure Intent Expiry (2 seconds):
           -> Remove Peer from Session Peer roster.
              Increment membershipEpoch.
           -> Emit peer_left event with reason "left".
           -> Broadcast peer_left control to all remaining Clients.
           -> Broadcast roster_snapshot to all connected Clients.
           -> Update advertisement. Return.
     3c. If hosting AND not in migration departure:
           -> BeginPeerReconnectGrace(peerID). Return.
     3d. Else:
           -> RemoveSessionPeer(peerID).

ERRORS:
  - None. All error conditions result in peer removal.
```

**Addition to Section 17 (Timeouts, Intervals, and Limits):**

| Constant | Default | Purpose |
|----------|---------|---------|
| Departure Send Timeout | 100ms | Max time client waits for departure message write callback before proceeding with disconnect |
| Departure Intent Expiry | 2s | Max time between receiving a departure intent and the corresponding disconnect callback for the intent to be honored |

**Backward compatibility:** A v2 host that receives the unknown `"client_leaving"` control type will silently ignore it (unknown control types are not errors in the v2 spec) and proceed with the existing reconnect grace path. A v3 host connecting with a v2 client that does not send `"client_leaving"` will follow the grace path as before. No version negotiation is required.

---

## Change 3: Add GATT Connection Failure Path to ConnectToRoom

### Objective

Add step 8 to Section 6.3 (ConnectToRoom) defining behavior when a GATT connection attempt fails, and extend failure handling to cover service discovery and characteristic lookup failures. This closes a spec gap that produces zombie states on Android and divergent behavior between platforms.

### Rationale

Both proposals agree on the problem (curated issue I-4) and the need for a failure step. They diverge on the reconnect/migration behavior:

- **From Proposal A (adopted):** On GATT failure during reconnect or migration, resume the scan rather than calling `FailReconnect()`/`FailMigration()`. A single connection failure should not terminate the entire reconnect/migration attempt. The reconnect/migration timeout already bounds the retry window. Proposal A's resume-scan approach gives the protocol a retry opportunity within the existing timeout, which is more resilient in congested BLE environments. Proposal B's immediate-fail approach was rejected because it wastes the remaining timeout window on a potentially transient failure.

- **From Proposal B (adopted):** Service discovery failure (step 7b) and characteristic-not-found (step 7c) receive the same handling as GATT connection failure. A successful GATT connection that fails service discovery is functionally the same as a connection failure and must be routed through the same cleanup path. Proposal A did not address post-connection setup failures.

- **From Proposal B (adopted as informative note):** On Android, connection failures arrive as disconnect callbacks (`onConnectionStateChange` with `STATE_DISCONNECTED` and non-zero status). Implementations must ensure the failure is handled by step 8 when `clientJoined` is false and the status indicates connection establishment failure, not by the Section 13 disconnect tree. Step 8 takes precedence.

### Specification

**Amend Section 6.3 (ConnectToRoom), add after step 7:**

```
FUNCTION ConnectToRoom(room, migrationJoin) -> void

  1. [Unchanged — duplicate join guard]
  2. [Unchanged — stop scan, StopClientOnly]
  3. [Unchanged — store session info]
  4. [Unchanged — set clientLeaving=false, clientJoined=false]
  5. [Unchanged — reset roster if fresh join]
  6. [Unchanged — connect GATT with autoConnect=false]
  7. On GATT connected:
     7a. Request MTU (desired: 185, minimum: 23).
     7b. Discover services. On failure -> go to step 8.
     7c. Find Message Characteristic. If not found -> go to step 8.
     7d. Enable notifications via CCCD descriptor write (non-fatal on failure).
     7e. Call CompleteLocalJoin().
  8. On GATT connection failure (or post-connection setup failure from 7b/7c):
     8a. Call StopClientOnly().
     8b. If reconnectJoinInProgress is true:
           -> Set reconnectJoinInProgress = false.
           -> Resume reconnect scan. Do not call FailReconnect().
              The reconnect timeout is still running and may yield
              another scan result.
           -> Return.
     8c. If migrationJoinInProgress is true:
           -> Set migrationJoinInProgress = false.
           -> Resume migration scan. Do not call FailMigration().
              The migration timeout is still running and may yield
              another scan result.
           -> Return.
     8d. Else (fresh join):
           -> Call FinishLeaveClient().
           -> Emit error("join_failed", "connection_failed") with
              platform-specific detail.

ERRORS:
  - GATT connection failure during fresh join -> join_failed emitted.
    session_ended is NOT emitted (client was never joined).
  - GATT connection failure during reconnect -> scan resumes;
    failure is transient until reconnect timeout expires.
  - GATT connection failure during migration -> scan resumes;
    failure is transient until migration timeout expires.
  - Service discovery or characteristic lookup failure -> same as
    GATT connection failure.
  - CCCD write failure (step 7d) -> non-fatal; proceed to step 7e.
```

**Informative note (not normative):** On platforms where GATT connection failure is delivered as a disconnect callback (notably Android's `onConnectionStateChange` with `STATE_DISCONNECTED` and non-zero status), step 8 takes precedence over the Section 13 disconnect tree when `clientJoined` is false and the disconnect status indicates connection establishment failure. Implementations must not route connection-establishment failures through the disconnect recovery path.

---

## Change 4: Define `FinishLeaveClient` as a Distinct Procedure

### Objective

Add `FinishLeaveClient()` as a defined procedure in Section 6.6, separating client-only teardown from full session teardown. This resolves a code-to-spec divergence where both platform implementations use a client-only teardown variant that the specification does not define, and where the spec references full `FinishLeave(null)` at call sites where the implementation correctly uses client-only teardown.

### Rationale

This change is adopted from Proposal B (Item 4). Proposal A did not identify this gap.

The architectural argument is decisive: during migration, a device can be both host and client simultaneously. The Client Disconnect Decision Tree (Section 13) must clean up client state without destroying the concurrent host state. If Section 13 called full `FinishLeave()`, it would tear down the GATT server, cancel host timers, and destroy the migration in progress. Both implementations avoid this by using a client-only variant, but the spec does not define or reference it.

This is not a cosmetic issue. A future implementor following the spec literally would call `FinishLeave(null)` in the disconnect tree and break migration. The invariant being protected — *host state must survive client-side disconnect handling during migration* — is critical and must be explicit in the specification.

The name `FinishLeaveClient` is taken from the Android implementation where the procedure already exists. Alternative names were considered and rejected in favor of consistency with existing codebases.

### Specification

**Add to Section 6.6, after the existing `FinishLeave` definition:**

```
FUNCTION FinishLeaveClient() -> void

  1. Call StopClientOnly() to clean up GATT client state.
  2. Clear client-side dedup state.
  3. Clear client-side fragment assemblies.
  4. Set clientJoined = false.
  5. Set clientLeaving = true.

POSTCONDITIONS:
  - GATT client connection is closed.
  - Client write queue is empty.
  - No in-flight client writes remain.
  - Host state (GATT server, host timers, host session info) is unaffected.

ERRORS:
  - None. All operations are local cleanup.
```

**Update the following call sites to reference `FinishLeaveClient()` instead of `FinishLeave(null)`:**

- Section 13 (Client Disconnect Decision Tree), steps 7a and 8a (this document, Change 1).
- Section 7.1 `FailReconnect()`, step 4.
- Section 6.3 `ConnectToRoom` step 8d (this document, Change 3).

**Retain `FinishLeave(remoteReason)` as the full teardown procedure, used only by:**

- `Leave()` (Section 6.6) — intentional leave by client or host.
- `BeginGracefulMigration()` step 8 (Section 8.1) — host departure after migration broadcast.

---

## Change 5: Define App Lifecycle Triggers for Leave()

### Objective

Add Section 6.7 defining when the platform layer must auto-invoke `Leave()` in response to application lifecycle events. This makes graceful migration the normative path for the most common cause of host loss (app backgrounding) rather than an exceptional path triggered only by explicit user action.

### Rationale

Both proposals agree on the core logic: Resilient hosts must call `Leave()` on backgrounding (triggering graceful migration), Reliable hosts must call `Leave()` on backgrounding (triggering session_ended), and clients must take no automatic action on backgrounding.

- **From Proposal A (adopted):** Platform-agnostic function naming (`OnAppLifecycleChanged(newState)`) is used instead of Proposal B's iOS-specific naming (`OnAppWillResignActive`). The specification is cross-platform; function names must not privilege one platform's terminology. Proposal A's termination handling (immediate teardown, skip departure delay) is also adopted — this is an important edge case that Proposal B omitted.

- **From Proposal A (adopted):** The informative platform-mapping table provides implementation guidance without being normative.

- **From Proposal B (noted as tradeoff):** The observation that `willResignActive` (iOS) and `onPause` (Android) fire for non-terminal interruptions (e.g., incoming calls that are declined) is a real tradeoff. The specification mandates Leave() on these events, accepting potentially unnecessary session teardown in exchange for consistent behavior and reliable graceful migration.

The decision to not auto-invoke Leave() for backgrounded clients is deliberate and agreed by both proposals. Clients benefit from maintaining session state during brief background transitions. If the OS drops the BLE connection, the existing reconnect mechanism handles it.

### Specification

**New Section 6.7 — Application Lifecycle Integration**

The protocol layer MUST register for platform-level application lifecycle events and invoke protocol actions in response.

```
FUNCTION OnAppLifecycleChanged(newState) -> void

  1. If newState is "background" or "inactive":
     1a. If hosting is true AND transport is Resilient AND connected client count > 0:
         -> Invoke Leave(). This triggers BeginGracefulMigration()
            per Section 6.6 step 1.
     1b. Else if hosting is true:
         -> Invoke Leave(). This sends session_ended and tears down.
     1c. If connected as client:
         -> No automatic action. The client retains its connection.
            If the OS subsequently drops the connection, the standard
            disconnect decision tree (Section 13) handles recovery.
  2. If newState is "terminating":
     2a. Invoke Leave() with immediate teardown (skip departure delay
         from Change 2 step 2c). There is no time budget for
         best-effort message delivery during termination.
  3. If newState is "foreground":
     3a. No automatic action. If the session was lost during background,
         the client disconnect decision tree (Section 13) will have
         already handled it.

ERRORS:
  - Leave() fails during background transition (e.g., GATT server
    already torn down by OS) -> attempt FinishLeave("host_left")
    to clean up local state. Session may enter unexpected recovery
    on the client side.
  - Insufficient background execution time for graceful migration ->
    migration may be interrupted by OS. Clients fall back to
    unexpected host recovery (Section 8.2).
```

**Platform mapping (informative, not normative):**

| Lifecycle Event | Android | iOS |
|----------------|---------|-----|
| App entering background | `onPause()` or `onStop()` in Activity | `applicationDidEnterBackground` or `willResignActive` |
| App will terminate | `onDestroy()` in Activity | `applicationWillTerminate` |
| App entering foreground | `onResume()` in Activity | `applicationDidBecomeActive` |

---

## Change 6: Resolve Divergent Successor Elections in Unexpected Host Recovery

### Objective

Define scan-time behavior during unexpected host recovery (Section 8.2) so that clients with divergent roster state converge on a single successor. The v2 spec assumes all clients have identical roster state at the moment of host loss, which is false when roster snapshots are lost or delayed over BLE.

### Rationale

Both proposals address curated issue I-3 (divergent successor elections). Their approaches are complementary:

- **From Proposal A (adopted as primary mechanism):** The "first advertiser wins" rule during migration scan is the core resolution mechanism. Rather than requiring all clients to agree on a successor before anyone starts hosting, the protocol allows independent elections and converges on whichever successor actually starts advertising first. This is architecturally superior to synchronized election because it tolerates the very roster-state divergence that causes the problem. Proposal A's `OnScanResultDuringMigration` function defines the scan behavior explicitly, including the case where a non-elected-but-valid session member is discovered advertising.

- **From Proposal B (adopted as clarification):** The new host's `roster_snapshot` delivered after migration-resume reconnection is the authoritative state that resolves any remaining roster divergence. This is the existing mechanism but the v2 spec does not explicitly state that it serves as the convergence resolution. Proposal B's clarification is adopted to make this normative.

- **From Proposal A (adopted):** Step 10 in `BeginUnexpectedHostRecovery` encodes the migration payload in the Room Advertisement (same session ID, new host Peer ID), which is the notification mechanism. No new control message is added — the advertisement *is* the notification, which is architecturally clean since the new host has no GATT connections to remaining clients at this point.

Proposal B's `OnNewHostReady()` function was considered but adds no behavior beyond what already exists in the hello/roster_snapshot handshake. The function is omitted to avoid specification bloat.

### Specification

**Amend Section 8.2 (BeginUnexpectedHostRecovery), add after step 9:**

```
FUNCTION BeginUnexpectedHostRecovery() -> boolean

  1-9. [Unchanged from v2]
  10. If becomingHost is true AND GATT server started successfully:
      10a. The Room Advertisement encodes the migrated session info
           (same sessionId, localPeerID as new host, same maxClients,
           roomName, current membershipEpoch).
      10b. Remaining clients discover the new host via scan during
           BeginMigrationReconnect() and connect with
           join_intent="migration_resume".
  11. Return true.

ERRORS:
  - GATT server fails to start -> successor is treated as failed;
    convergence fallback applies (Section 8.3).
```

**Add to Section 8.4 (Migration Reconnect) — scan behavior during unexpected recovery:**

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

ERRORS:
  - Connection to accepted successor fails -> resume scan.
    Migration timeout still applies.
```

**Amend Section 8.3 (Successor Selection), add clarifying note:**

> During unexpected host recovery, all electing peers MUST use the roster associated with the highest `membership_epoch` known locally. The roster used for election MUST exclude: (a) the old host, (b) any peers with status `reconnecting`, and (c) any peers previously excluded by the convergence fallback. If peers have divergent rosters due to in-flight roster updates at the time of host loss, the "first advertiser wins" rule (Section 8.4 `OnScanResultDuringMigration` step 3) is the primary convergence mechanism. The new host's `roster_snapshot` delivered after migration-resume reconnection is the authoritative state that resolves any remaining divergence across all reconnected peers.

**Acknowledged transient state:** If two clients both believe they are the successor and both start GATT servers, two rooms with the same session ID will be advertising simultaneously. The "first discovered wins" rule resolves this for scanning clients. The losing host will continue advertising until its own migration timeout expires with no clients connecting, at which point it emits `session_ended`. This state is transient and self-resolving.

---

## Change 7: Define Migration Acceptance Window Duration

### Objective

Document the migration acceptance window — the bounded time period during which a successor host accepts `migration_resume` join intents — as a named constant in Section 17, and define its start/end conditions. The v2 spec references a "migration-acceptance state" in Section 6.5 step 3e but never defines when it begins or ends.

### Rationale

This change is adopted from Proposal A (Item 6). Proposal B did not address this gap.

Both platform implementations hardcode this window to 3 seconds (matching Migration Timeout). The spec references the concept (`join_rejected("migration_mismatch")` when the host is "not in a migration-acceptance state") but never defines the state transitions. This is a gap: without a defined window, an implementation could leave migration acceptance open indefinitely (accepting stale `migration_resume` intents from previous sessions) or close it immediately (rejecting legitimate migration peers).

Tying the window to 3 seconds — the same value as Migration Timeout — creates a clean temporal boundary: any client whose migration timeout has expired will also find the acceptance window closed.

The explicit flag `migrationAcceptanceActive` replaces the overloaded `migrationInProgress` flag, which in current implementations serves double duty as both "I am currently migrating" and "I am accepting migration joins." These are distinct states (the successor's own migration completes when it starts hosting, but the acceptance window extends beyond that).

### Specification

**Addition to Section 17 (Timeouts, Intervals, and Limits):**

| Constant | Default | Purpose |
|----------|---------|---------|
| Migration Acceptance Window | 3s | Duration after successor begins hosting during which `migration_resume` join intents are accepted |

**Amend Section 8.4 (Migration Reconnect) — host-side acceptance:**

When the successor begins hosting a migrated session:

```
FUNCTION BeginHostingMigratedSession(migrationInfo) -> void

  1. Start GATT server with migrated session info
     (sessionId, roomName, maxClients, membershipEpoch).
  2. Set migrationAcceptanceActive = true.
  3. Begin advertising the room.
  4. Start Heartbeat timer.
  5. Emit hosted event.
  6. Schedule Migration Acceptance Window timer (default 3 seconds).
  7. On Migration Acceptance Window expiry:
     7a. Set migrationAcceptanceActive = false.
     7b. Any subsequent join with intent="migration_resume" is
         rejected with "migration_mismatch" per Section 6.5 step 3e.

ERRORS:
  - GATT server fails to start -> emit error, session is lost.
  - No peers connect within acceptance window -> window expires,
    host continues operating with current roster. Peers arriving
    later with fresh join intent are accepted normally.
```

---

## Change 8: MaxClients Range Clarification

### Objective

Amend Section 6.1 step 5 to explicitly state that application-layer validation must not accept values outside the wire-representable range [1, 7]. This addresses a divergence where the Lua validation layer accepts `max_clients = 8`, which the native layer silently clamps to 7.

### Rationale

This change is adopted from Proposal A (Item 7). Proposal B did not address this gap.

The specification already correctly defines the range as [1, 7] (Section 3.1: `MaxClients` is "ASCII digit '1'-'7'"; Section 6.1 step 5: "Clamp maxClients to range [1, 7]"). The wire format physically cannot represent values outside this range. The Lua config layer's `max_clients = 8` is an implementation bug, not a spec gap. However, the spec should make the expectation clear to prevent similar bugs in other application layers.

This is a documentation clarification with no behavioral change to the protocol.

### Specification

**Amend Section 6.1 step 5:**

Current: "Clamp *maxClients* to range [1, 7]."

Proposed: "Validate *maxClients* is in range [1, 7]. If outside this range, clamp to the nearest bound. Application-layer validation SHOULD reject values outside [1, 7] before they reach the protocol layer, rather than relying on silent clamping."

---

## Rejection Log

### Rejected: Proposal A dual presentation of Section 13 (Item 1)

Proposal A presented the Section 13 change twice — once as pseudocode and once as a formal function definition — with slightly different formatting. This redundancy is not carried forward. The specification uses a single formal function definition.

**Reason:** Redundancy. The dual presentation adds no information and risks introducing inconsistency between the two representations.

### Rejected: Proposal B — `OnNewHostReady()` function (Item 6)

Proposal B proposed an `OnNewHostReady()` function that defines what happens when peers connect to the new host with `migration_resume` intent. The function body describes existing behavior (send `hello_ack`, send `roster_snapshot`) that is already specified in the HELLO handshake (Section 6.5) and roster delivery rules (Section 4.3). Adding a named function for this creates an additional normative reference point for behavior that is already fully defined.

**Reason:** Redundancy. The behavior is already specified. The function adds specification surface area without adding new semantics.

### Rejected: Proposal B — Zero-argument signature without reconnect guards (Item 1)

Proposal B's derivation of `shouldEmit = NOT clientLeaving` without device-identity guards was considered but not adopted in isolation. The stale-disconnect race condition during reconnect is a real failure mode that the simpler derivation does not address.

**Reason:** Insufficient. The reconnect-guard conditions from Proposal A are necessary to close the stale-disconnect race window. The merged solution combines both inputs.

### Rejected: Proposal A — Immediate peer removal in departure handler (Item 2)

Proposal A's `OnClientLeavingReceived` handler immediately removed the peer from the roster, broadcast `peer_left` and `roster_snapshot`, and updated the advertisement. This creates a race: the same peer may be removed twice (once by the departure handler, once by the disconnect callback).

**Reason:** Architectural mismatch. Removing peers in two separate code paths (departure handler and disconnect handler) violates the single-responsibility principle for roster mutation. Proposal B's two-phase design (record intent, remove on disconnect) is cleaner.

### Rejected: Proposal B — Immediate FailReconnect/FailMigration on GATT connection failure (Item 3)

Proposal B called `FailReconnect()` on GATT connection failure during reconnect, which terminates the entire reconnect attempt on a single transient failure. This wastes the remaining reconnect timeout window.

**Reason:** Excessive. A single GATT connection failure is a transient event in congested BLE environments. The reconnect/migration timeout already bounds retries. Resuming the scan (Proposal A's approach) gives the protocol additional connection attempts within the existing timeout.

### Not addressed: I-6 (Assert permissions granted is underspecified)

Curated issue I-6 (minor severity) was not addressed by either proposal. Neither proposal's scope included permission handling. This issue remains open for a future revision.

**Reason:** Out of scope for both proposals. Deferred.

---

*End of consolidated specification.*
