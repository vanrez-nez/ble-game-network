# Proposal B — BLE Game Network Protocol Specification v3

**Proposal ID:** b
**Baseline:** Protocol Specification v2.0.0 (2026-03-25)
**Date:** 2026-03-27

---

## Glossary

| Term | Definition |
|------|-----------|
| **shouldEmit** | A boolean parameter in the Client Disconnect Decision Tree (Section 13) that controls whether a disconnect event produces application-visible side effects (events, recovery attempts) or is silently cleaned up. |
| **FinishLeave** | The spec-defined teardown procedure (Section 6.6) that cleans up all session state. In the implementation, this procedure is split into a full teardown (`finishLeave`) and a client-only partial teardown (`finishLeaveClient`). |
| **FinishLeaveClient** | An implementation-only procedure that performs client-side GATT cleanup without tearing down host state. Not defined in the specification but used in both platform implementations as the actual cleanup path in the Client Disconnect Decision Tree. |
| **Departure Message** | A control packet sent from client to host to signal intentional session departure, as distinct from an unexpected BLE disconnection. |
| **Zombie State** | A condition where the client has failed a GATT connection attempt but has no timeout, retry, or cleanup path, leaving it indefinitely stuck with no session and no error event. |
| **Grace Slot** | A client slot reserved in the roster for a peer in reconnect grace. The slot counts against `MaxClients` for admission but does not count as `PeerCount` in the advertisement. |
| **Lifecycle Event** | A platform-level application state change (backgrounding, foregrounding, termination) that may affect BLE connection viability. |
| **Convergence Fallback** | The mechanism (Section 8.3) by which clients re-elect a successor when the primary elected successor fails to advertise within the Migration Timeout. |

---

## Scope Statement

This proposal covers six specification-level concerns in the v2.0.0 baseline, informed by examination of the native implementations (`BleManager.java` for Android, `Ble.mm` for iOS), the Lua application layer (`lua/ble_net/`), the curated issues list (`version-2/issues.md`), and the master backlog (`backlog/issues.md`). The concerns addressed are: (1) the undefined `shouldEmit` parameter in the Client Disconnect Decision Tree; (2) the absence of a client-to-host departure message; (3) the missing GATT connection failure path in ConnectToRoom; (4) the undocumented split between full and client-only teardown procedures; (5) the absence of app lifecycle guidance for Resilient-mode hosts; and (6) the lack of a post-election notification step in unexpected host recovery. Each of these originates from a documented gap between the specification text and the implemented behavior, or from an operational failure mode that the specification leaves unaddressed. None are cosmetic or aspirational; all trace to code-level evidence or filed issues.

---

## Item 1: Define `shouldEmit` Derivation in the Client Disconnect Decision Tree

### Problem Statement

Section 13 (Client Disconnect Decision Tree) accepts `shouldEmit` as a parameter to `OnClientDisconnected(wasJoined, shouldEmit)` but never defines how it is derived. The specification uses it as the primary branching condition for steps 3, 4, 5, and 6 — it determines whether the client attempts recovery, emits events, or silently cleans up — yet its semantics are left to the implementor.

Both platform implementations independently derived `shouldEmit = !clientLeaving` (Android: `BleManager.java` line 1935; iOS: `Ble.mm` line 1633). This derivation is correct for the common case but interacts poorly with `StopClientOnly()`, which is called in `ConnectToRoom` step 2. When a reconnect attempt fails, `StopClientOnly()` nulls the GATT reference, and the subsequent disconnect callback for the *failed reconnect attempt* arrives with `clientLeaving` still false (because the client never called `Leave()`), correctly routing through the `shouldEmit=true` path. However, the specification does not document this interaction or its implications for the decision tree's step ordering.

Additionally, the backlog (I-3) records that the original concern cited `currentGattHandle == disconnectedHandle` as part of the derivation. While the current implementations have simplified this to `!clientLeaving`, the specification must define the canonical derivation to prevent future implementations from reintroducing the handle-comparison pattern, which fails when `StopClientOnly()` nulls the handle before the callback fires.

**Curated issue:** I-2 (`shouldEmit` parameter undefined in Client Disconnect Decision Tree).

### Origin

Code-to-spec divergence. Both implementations have converged on a derivation the spec does not define.

### Proposed Change

Replace the current Section 13 signature and add a derivation preamble:

```
OnClientDisconnected():

PRECONDITION:
  Let wasJoined = clientJoined (true if hello_ack was received for current connection).
  Let shouldEmit = NOT clientLeaving (true if this disconnect was not initiated by Leave()).

FUNCTION OnClientDisconnected() -> void

  1. Capture wasJoined and shouldEmit from preconditions above.
  2. Call StopClientOnly() to clean up GATT state.
  3. If active Migration exists:
       -> BeginMigrationReconnect(). Return.
  4. If shouldEmit AND wasJoined AND transport is Resilient:
       -> Attempt BeginUnexpectedHostRecovery().
       -> If successful, return.
  5. If shouldEmit AND wasJoined:
       -> Attempt BeginClientReconnect().
       -> If successful, return.
  6. If shouldEmit:
       -> Call FinishLeaveClient().
       -> If wasJoined: emit session_ended("host_lost").
       -> Else: emit error("join_failed", platform-specific detail).
       -> Return.
  7. If none of the above matched:
       -> Call FinishLeaveClient(). No events emitted.

ERRORS:
  - None. This function is a terminal handler; all error reporting is via emitted events.
```

Key changes:
- `shouldEmit` and `wasJoined` are captured *before* `StopClientOnly()` executes (step 1 before step 2), making the derivation unambiguous.
- The derivation is defined as `NOT clientLeaving`, not as a handle comparison.
- The signature changes from parameterized to zero-argument, with preconditions stated explicitly.
- Step 6 and 7 reference `FinishLeaveClient()` instead of `FinishLeave(null)` (see Item 4).

### Reasoning

The decision tree is the most critical branching point in client-side connection management. Every disconnect routes through it. Leaving its primary branching condition undefined means two implementors can produce different behavior at every branch. Defining the derivation eliminates a class of divergence bugs, not just one instance.

### Known Tradeoffs

- Changing the signature from parameterized to zero-argument is a semantic shift. If any caller currently passes values that differ from the precondition derivation, this would change behavior. Both current implementations always call it with `(clientJoined, !clientLeaving)`, so this is not a practical risk, but it constrains future callers.
- Mandating capture order (step 1 before step 2) introduces an ordering requirement that was previously implicit. This is intentional — the ordering matters and must be specified.

### Dependencies

Depends on Item 4 (FinishLeaveClient definition) for the step 6/7 cleanup reference.

---

## Item 2: Add Client-to-Host Departure Control Message

### Problem Statement

Section 4.3 defines no control message from client to host to signal intentional departure. The `peer_left` message is Host -> Client only. When a client calls `Leave()`, it closes its GATT connection. The host receives a `STATE_DISCONNECTED` callback indistinguishable from an unexpected BLE drop. This causes every intentional departure to enter the 10-second reconnect grace window (Section 7.2), delaying roster cleanup and holding a client slot.

In the current implementation (Android: `BleManager.java` `onHostClientDisconnected()` line 1497; iOS: `Ble.mm` `onHostClientDisconnected:` line 2381), the host always calls `beginPeerReconnectGrace()` when it detects a client disconnect while hosting. There is no path to distinguish "client left intentionally" from "BLE dropped." The 10-second grace period is architecturally necessary for unexpected drops but wasteful for intentional departures.

**Curated issue:** I-1 (No client-to-host departure message).

### Origin

Spec gap traced to GitHub issue #1 and confirmed by code analysis of both native implementations.

### Proposed Change

Add a `"departure"` control message type to Section 4.3:

| MsgType | Direction | Payload | Purpose |
|---------|-----------|---------|---------|
| `"departure"` | Client -> Host | Empty | Client signals intentional session departure |

Modify Section 6.6 `Leave()` to send the departure message before disconnecting:

```
FUNCTION Leave() -> void

  1. If hosting with Resilient transport and clients exist:
     1a. Attempt BeginGracefulMigration().
     1b. If successful, return.
  2. If connected as client AND clientJoined:
     2a. Encode and send a "departure" control Packet
         (from=localPeerID, to=hostPeerID, type="departure", payload=empty).
     2b. Wait up to Departure Send Timeout (100ms) for write callback.
         On timeout or failure, proceed anyway.
  3. Call FinishLeave(reason=null for client, "host_left" for host).

ERRORS:
  - Write failure in step 2b is non-fatal. The departure message is best-effort;
    the host's grace timer serves as the fallback for delivery failure.
```

Modify Section 14 (Host Client-Disconnect Decision Tree) to check for a received departure message:

```
FUNCTION OnHostClientDisconnected(deviceKey) -> void

  1. Remove device from pending clients, MTU map, notification queues.
  2. Look up Peer ID from device-peer map. Remove mapping.
  3. If Peer ID found:
     3a. Remove from connected clients map.
     3b. If departure message was received from this Peer ID
         within the last 2 seconds:
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

Add a host-side handler:

```
FUNCTION OnDepartureReceived(sourceDeviceKey, packet) -> void

  1. Let peerId = packet.fromPeerId.
  2. If peerId is empty or not in connected clients, return.
  3. Record departure intent for peerId with timestamp.
  4. Do not disconnect the device. The client will disconnect itself.

ERRORS:
  - None.
```

Add to Section 17:

| Constant | Default | Purpose |
|----------|---------|---------|
| Departure Send Timeout | 100ms | Max time client waits for departure message write callback before proceeding with disconnect |

### Reasoning

This eliminates a 10-second delay on every intentional departure. The host can immediately clean up the roster and free the client slot. The design is best-effort: if the departure message is lost (BLE write fails, connection drops before delivery), the grace timer still fires after 10 seconds and produces the same eventual outcome. This means the change is backward-compatible at the host level — a v2 host that receives an unknown control message type ignores it and falls back to grace-based cleanup.

### Known Tradeoffs

- Adds a new control message type, increasing the protocol surface area.
- The 100ms send timeout adds latency to the `Leave()` path. This is bounded and short, but it is new blocking behavior in a previously non-blocking call.
- The 2-second departure lookback window in the host decision tree is a heuristic. If a departure message arrives but the disconnect callback is delayed beyond 2 seconds, the host falls back to grace. This is acceptable because the grace fallback is the current behavior.
- A client running an older protocol version will not send the departure message. The host must not *require* it — grace-based cleanup remains the default path.

### Dependencies

None. This item is self-contained.

---

## Item 3: Add GATT Connection Failure Path to ConnectToRoom

### Problem Statement

Section 6.3 `ConnectToRoom` step 7 defines "On GATT connected" but specifies no step for GATT connection failure. On Android, connection failures arrive as `onConnectionStateChange(status, STATE_DISCONNECTED)` with a non-zero status (e.g., `status=62 GATT_CONN_FAIL_ESTABLISH`, `status=133 GATT_ERROR`). On iOS, connection failures arrive via `didFailToConnectPeripheral:error:`, which is a separate delegate callback from `didDisconnectPeripheral:error:`.

The iOS implementation handles `didFailToConnectPeripheral` explicitly (line 1611–1624): it calls `stopClientOnly()` and emits a `join_failed` error. The Android implementation does not have a separate failure handler — all disconnects (including failures) route through `onClientDisconnected(clientJoined, !clientLeaving)`. When a GATT connection fails during a reconnect attempt, the Android path routes through the decision tree at step 4 (`shouldEmit AND wasJoined`), which attempts `BeginClientReconnect()` again — potentially creating a reconnect loop until the 10-second timeout expires.

The spec must define a connection failure step that covers both initial join and reconnect scenarios.

**Curated issue:** I-4 (ConnectToRoom has no GATT connection failure path).

### Origin

Spec gap traced to GitHub issue #3 and confirmed by divergent handling between Android and iOS native implementations.

### Proposed Change

Add step 8 to Section 6.3 `ConnectToRoom`:

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
     7b. Discover services.
     7c. Find Message Characteristic.
     7d. Enable notifications via CCCD descriptor write.
     7e. Call CompleteLocalJoin().
  8. On GATT connection failure (platform-specific):
     8a. Call StopClientOnly().
     8b. If reconnect is in progress:
           -> Call FailReconnect(). Return.
     8c. If migration is in progress:
           -> Call FailMigration(). Return.
     8d. Emit error("join_failed", platform-specific detail).

ERRORS:
  - GATT connection failure: handled by step 8.
  - Service discovery failure (step 7b returns error): same handling as step 8.
  - Characteristic not found (step 7c): same handling as step 8.
  - CCCD write failure (step 7d): non-fatal; proceed to step 7e.
```

Also add sub-step failure handling for service/characteristic discovery:

```
  7b-err. If service discovery fails:
          -> Same as step 8a-8d.
  7c-err. If Message Characteristic not found:
          -> Same as step 8a-8d.
```

### Reasoning

The absence of a failure step is not theoretical — it produces observable zombie states on Android when GATT connections fail during reconnect. Defining the failure path at the spec level ensures both platforms handle connection failures consistently and ensures reconnect-in-progress and migration-in-progress states are properly unwound. The step 8 handler explicitly checks for reconnect and migration contexts, routing to the appropriate failure handler rather than falling through to the generic disconnect decision tree.

### Known Tradeoffs

- Step 8 partially overlaps with the Client Disconnect Decision Tree (Section 13). On Android, connection failures arrive as disconnect callbacks and already route through Section 13. This proposal creates a separate, explicit failure path. Implementations must ensure the failure is handled by exactly one of these paths, not both. The spec should note that if the platform delivers connection failure as a disconnect callback, step 8 takes precedence when `clientJoined` is false and the disconnect status indicates connection establishment failure.
- CCCD write failure is classified as non-fatal (step 7d). This matches both implementations but means a client could join without notification delivery working. This is an existing reality, not a new risk introduced by this proposal.

### Dependencies

None. This item is self-contained, though it interacts with Item 1 (shouldEmit definition) at the boundary between step 8 and Section 13.

---

## Item 4: Define FinishLeaveClient as a Distinct Procedure

### Problem Statement

Section 6.6 defines a single `FinishLeave(remoteReason)` procedure that performs full session teardown: cancels all timers, clears all maps, closes GATT Server, closes GATT Client, resets all session state. However, both platform implementations use a second, undocumented procedure — `finishLeaveClient()` (Android: line 2861; iOS: implicit via `stopClientOnly()` with partial state clearing) — that performs client-side cleanup *without* tearing down host state.

This split is architecturally necessary. The Client Disconnect Decision Tree (Section 13) calls cleanup at steps 5 and 6. If it called the full `FinishLeave()`, it would tear down any concurrent host state (a device can be both host and client during migration). The actual code calls `finishLeaveClient()`, which clears only client GATT state, client write queues, dedup state, and the `clientJoined` flag.

The spec references `FinishLeave(null)` in Section 13 step 5 and in `FailReconnect()` step 4 (Section 7.1), but both implementations actually call `finishLeaveClient()` at these points, not the full `FinishLeave()`.

### Origin

Code-to-spec divergence. The implementation has a procedure the spec does not define, and the spec references a different procedure at call sites where the implementation uses the undocumented one.

### Proposed Change

Add `FinishLeaveClient()` as a defined procedure in Section 6.6:

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
  - No in-flight writes remain.
  - Host state (if any) is unaffected.

ERRORS:
  - None. All operations are local cleanup.
```

Update the following call sites to reference `FinishLeaveClient()` instead of `FinishLeave(null)`:

- Section 13 (Client Disconnect Decision Tree), steps 5 and 6.
- Section 7.1 `FailReconnect()`, step 4.

Retain `FinishLeave(remoteReason)` as the full teardown procedure, used only by:
- `Leave()` step 2 (intentional leave by client or host).
- `BeginGracefulMigration()` step 8 (host departure after migration).

### Reasoning

The spec currently conflates two distinct teardown scopes. Using full `FinishLeave()` in the disconnect decision tree would destroy host state during migration — a scenario the implementations explicitly avoid by using the client-only variant. Defining `FinishLeaveClient()` makes the spec match the implementation and prevents future implementors from using the wrong teardown scope in the disconnect path.

### Known Tradeoffs

- Adds a second teardown procedure to the specification, increasing surface area. The alternative — a single procedure with conditional scope — was considered and rejected because it obscures the critical invariant (host state must survive client-side disconnect handling during migration).
- The name `FinishLeaveClient` is taken directly from the Android implementation. Alternative names (`ClientTeardown`, `CleanupClientState`) were considered but the existing name is already established in two codebases.

### Dependencies

Item 1 (shouldEmit definition) references `FinishLeaveClient()` in its proposed decision tree. These two items must be adopted together or the cross-references break.

---

## Item 5: Define App Lifecycle Triggers for Resilient Host Leave

### Problem Statement

Section 6.6 defines the `Leave()` procedure but provides no guidance on when the platform layer should auto-invoke it. On iOS, when a Resilient-mode host app enters background (app switch, screen lock, incoming call), iOS may tear down the BLE peripheral manager's advertisement and GATT server. The host never sends `session_migrating` because `Leave()` was never called. Clients detect the host loss via BLE disconnect and enter the `BeginUnexpectedHostRecovery` path (Section 8.2), which is slower, less reliable, and more susceptible to divergent successor elections than the graceful migration path (Section 8.1).

The iOS `BLEService.swift` implementation (lines 3150–3161) tracks `isAppActive` state and adjusts scan parameters on background entry, but does not trigger `Leave()` or graceful migration. The Android `BleManager.java` has no lifecycle hooks at all. Neither implementation auto-invokes `Leave()` on backgrounding, meaning Resilient-mode hosts silently vanish from the perspective of connected clients.

**Curated issue:** I-5 (Spec silent on app lifecycle triggers for Leave()).

### Origin

Spec gap traced to GitHub issue #4 and confirmed by codebase analysis of both platforms.

### Proposed Change

Add a new Section 6.7 "Platform Lifecycle Integration" to the specification:

```
## 6.7 Platform Lifecycle Integration

The protocol layer MUST respond to platform lifecycle events that affect
BLE connection viability. The following rules apply:

FUNCTION OnAppWillResignActive() -> void

  1. If hosting with Resilient transport:
     1a. Call Leave(). This triggers BeginGracefulMigration() per Section 6.6
         step 1, sending session_migrating to all clients before the OS
         tears down the BLE stack.
  2. If hosting with Reliable transport:
     2a. Call Leave(). This sends session_ended("host_left") to all clients.
  3. If connected as client:
     3a. No action. The client retains its connection. If the OS
         subsequently drops the connection, the standard disconnect
         decision tree (Section 13) handles recovery.

FUNCTION OnAppDidBecomeActive() -> void

  1. No protocol-level action required. If the device was hosting and
     called Leave() on resign, it is no longer hosting. The application
     layer may choose to re-host or re-scan.

ERRORS:
  - If Leave() fails during OnAppWillResignActive (e.g., GATT server
    already torn down by OS), the host should still attempt to clean up
    local state via FinishLeave("host_left").
```

Define the platform-specific lifecycle events that map to `OnAppWillResignActive()`:

| Platform | Event |
|----------|-------|
| iOS | `UIApplication.willResignActiveNotification` |
| Android | `Activity.onPause()` (or `LifecycleObserver ON_PAUSE`) |

### Reasoning

Graceful migration is strictly superior to unexpected host recovery: it notifies all clients with a consistent successor election, it includes the current `membership_epoch` in the migration payload, and it avoids the 3-second convergence fallback timeout. The specification already defines the graceful migration mechanism but provides no trigger for the most common cause of host departure on mobile — app backgrounding. Adding lifecycle triggers makes graceful migration the normative path rather than the exceptional one.

### Known Tradeoffs

- Mandating `Leave()` on background entry means a host cannot maintain its session while briefly backgrounded (e.g., responding to a notification). This is intentional: on iOS, BLE peripheral advertising is unreliable in background, and maintaining a host session across background transitions creates false expectations of connectivity. Applications that need background hosting should use a different transport.
- Android's lifecycle is less aggressive than iOS about tearing down BLE. An Android host might survive brief backgrounding. This proposal still mandates `Leave()` on `onPause()` for consistency across platforms, at the cost of potentially unnecessary session teardown on Android.
- The 400ms migration departure delay (Section 8.1 step 7) must complete before the OS fully suspends the app. On iOS, `willResignActive` provides some time before suspension, but `applicationDidEnterBackground` provides more. Using `willResignActive` is the conservative choice — it fires earlier, giving the protocol more time, but also fires for non-terminal interruptions (incoming calls that are declined). This tradeoff favors reliability over session persistence.

### Dependencies

None. This item references existing spec mechanisms (`Leave()`, `BeginGracefulMigration()`) without modifying them.

---

## Item 6: Add Post-Election Notification in Unexpected Host Recovery

### Problem Statement

Section 8.2 (`BeginUnexpectedHostRecovery`) defines successor election as a purely local operation. When a client becomes the new host, it starts advertising (via `BeginHostingSession` in Section 8.4 step 1) but sends no notification to remaining clients. Each remaining client independently runs successor election with its local roster state. If two clients have different roster states (different `membership_epoch` values, which can occur if a roster update was in transit when the host dropped), they may elect different successors, producing a network split.

The graceful migration path (Section 8.1) avoids this problem because the outgoing host broadcasts `session_migrating` with the successor identity and epoch to all clients. The unexpected recovery path has no equivalent notification.

The convergence fallback (Section 8.3) partially mitigates this: if a client's elected successor fails to advertise within the Migration Timeout, the client re-elects. But this requires the timeout to expire (3 seconds per failed candidate), and with N clients potentially electing different successors, convergence can take `N * 3` seconds in the worst case.

**Curated issue:** I-3 (Unexpected host recovery has no cross-client notification).

### Origin

Spec gap traced to GitHub issue #5 and confirmed by architectural analysis of the migration path asymmetry.

### Proposed Change

Add a notification step to Section 8.2 after the successor begins hosting:

```
FUNCTION BeginUnexpectedHostRecovery() -> void

  1. [Unchanged — check Resilient transport]
  2. [Unchanged — check valid session info]
  3. [Unchanged — remove old Host, add self to roster]
  4. [Unchanged — remove reconnect-grace peers from candidates]
  5. [Unchanged — SelectRecoverySuccessor(oldHostID)]
  6. [Unchanged — if no successor, return false]
  7. [Unchanged — create MigrationInfo, set becomingHost]
  8. Call StartMigration(info).
  9. Call BeginMigrationReconnect().
  10. Return true.

ERRORS:
  - None at this stage. Failure is handled by migration timeout.
```

Add a post-hosting notification step in the migration-as-new-host path. After `BeginHostingSession` completes successfully (GATT server opened, advertising started), the new host MUST:

```
FUNCTION OnNewHostReady() -> void

  1. For each peer in the session roster (excluding self and the old host):
     1a. When the peer connects and completes the HELLO handshake
         with join_intent="migration_resume":
           -> Send hello_ack.
           -> Send roster_snapshot with current membershipEpoch.
  2. The new host's advertisement serves as the implicit notification
     that this peer is the successor. Clients discover it via scan
     during BeginMigrationReconnect().

ERRORS:
  - If no peers connect within Migration Timeout, the session is
    considered lost by those peers (per convergence fallback).
```

Additionally, modify Section 8.3 (Successor Selection) to add an explicit note:

> During unexpected host recovery, all electing peers MUST use the roster associated with the highest `membership_epoch` known locally. The roster used for election MUST exclude: (a) the old host, (b) any peers with status `reconnecting`, and (c) any peers previously excluded by the convergence fallback. If a peer's local roster differs from another peer's due to in-flight roster updates at the time of host loss, the convergence fallback (Migration Timeout re-election) is the normative resolution mechanism. The new host's `roster_snapshot` delivered after reconnection is the authoritative state that resolves any remaining divergence.

### Reasoning

The current spec relies entirely on the convergence fallback to resolve divergent elections. This proposal does not eliminate that reliance — the convergence fallback remains necessary because roster divergence is possible — but it strengthens the resolution path by ensuring the new host delivers an authoritative `roster_snapshot` upon reconnection. The key insight is that the existing `hello` handshake with `join_intent="migration_resume"` followed by `roster_snapshot` delivery already provides the notification mechanism. What the spec lacks is the explicit statement that this is the normative convergence resolution, not just an implementation detail.

### Known Tradeoffs

- This proposal does not add a new control message for post-election notification. An alternative would be to have the new host broadcast a `session_migrating` message to remaining clients after it begins hosting. This was considered but rejected because: (a) the new host has no GATT connections to those clients yet — they must discover it via scan and connect; (b) the `session_migrating` message is semantically "the current host is leaving," not "a new host has arrived," and reusing it would conflate two meanings.
- The roster-snapshot-as-convergence-resolution relies on clients actually reconnecting to the new host. If a client elected a different successor, it will not discover the actual new host's advertisement until its chosen successor times out (3 seconds). This is the existing convergence fallback behavior and is not worsened by this proposal.
- The requirement to use the highest known `membership_epoch` for election is already stated in Section 8.3 but is easy to miss. Restating it in the context of unexpected recovery adds redundancy to the spec, which is the lesser cost compared to an implementor missing it.

### Dependencies

None. This item clarifies existing mechanisms rather than introducing new ones.
