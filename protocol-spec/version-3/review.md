# External Observer Review — BLE Game Network Protocol v3 Merge

**Reviewer role:** External observer (non-participant, non-authoritative)
**Document reviewed:** `version-3/merge.md` (2026-03-27)
**Inputs reviewed:** `version-3/proposal-a.md`, `version-3/proposal-b.md`
**Baseline consulted:** `version-2/spec.md` (v2.0.0), `version-2/issues.md`
**Date:** 2026-03-27

---

## Observation 1

**Section:** Change 3 (GATT Connection Failure) + Change 1 (shouldEmit Derivation)
**Nature:** Emergent conflict
**Ref:** Change 3 step 8b clears `reconnectJoinInProgress`; Change 1 step 2b uses `reconnectJoinInProgress` as the reconnect guard

When a GATT connection fails during reconnect, Change 3 step 8b sets `reconnectJoinInProgress = false` and resumes the reconnect scan. The scan is still active. On Android, the same connection failure may also deliver a disconnect callback (as noted in the informative note). If that callback fires after step 8b has cleared `reconnectJoinInProgress`, it enters the Change 1 disconnect tree where: step 2b's guard does not suppress (`reconnectJoinInProgress` is false); `clientLeaving` is false; `wasJoined` is false (join never completed). This routes to step 7: `FinishLeaveClient()` followed by `emit error("join_failed")`. The application receives a `join_failed` error while the reconnect scan is still running — a contradictory state.

The informative note says step 8 "takes precedence," but this is guidance, not a normative mechanism. The specification provides no state that the disconnect tree can check to determine that the failure has already been handled by step 8 and the reconnect scan is still active. `reconnectScanInProgress` is set during the original `BeginClientReconnect()` and remains true, but the disconnect tree does not consult it.

**Safely dismissable if:** All platforms that deliver connection failure as a disconnect callback route it exclusively through Change 3 step 8 and guarantee the disconnect tree never fires for the same event — i.e., the precedence is enforced at the implementation level, not the specification level. If any platform might deliver both a step-8-handled failure and a subsequent disconnect callback for the same event, this conflict is live.

---

## Observation 2

**Section:** Change 7 (Migration Acceptance Window) + v2 Section 8.4 (Migration Reconnect)
**Nature:** Emergent conflict
**Ref:** Change 7 defines Migration Acceptance Window (3s, graceful expiry); v2 Section 8.4 step 3 schedules Migration Timeout (3s, calls `FailMigration()`)

For the successor host, two timers with identical duration start at approximately the same time. The Migration Acceptance Window (Change 7) expires gracefully — `migrationAcceptanceActive` is set to false and the host continues operating. The Migration Timeout (v2 Section 8.4 step 3) fires `FailMigration()`, whose behavior for a device that is already hosting a migrated session is not defined but may tear down the session.

The v2 spec's `BeginMigrationReconnect()` step 3 schedules the migration timeout unconditionally ("Schedule migration timeout. On timeout: call FailMigration()"), including when step 1 takes the "becoming Host" branch. Change 7 introduces `BeginHostingMigratedSession` but does not state that the migration timeout from `BeginMigrationReconnect` is cancelled or not scheduled for the host path.

If `FailMigration()` tears down the session at 3s, the graceful acceptance-window expiry at 3s is moot — the session is already destroyed. If `FailMigration()` is a no-op for the host (because it has already completed its own migration), this conflict resolves silently, but that behavior is not specified.

**Safely dismissable if:** `FailMigration()` is defined such that it does not tear down a session that is already actively hosting (i.e., the migration timeout is either cancelled when hosting begins or `FailMigration()` checks hosting state and no-ops). Neither the merge nor the v2 spec establishes this.

---

## Observation 3

**Section:** Change 6 (Divergent Successor Elections), "Acknowledged transient state"
**Nature:** Silent assumption
**Ref:** "The losing host will continue advertising until its own migration timeout expires with no clients connecting, at which point it emits `session_ended`. This state is transient and self-resolving."

The self-resolving claim rests on the assumption that no clients connect to the losing host during its acceptance window. `OnScanResultDuringMigration` step 3 directs clients to accept any known session member that is advertising. If two successors begin advertising simultaneously, different clients may discover them in different order (BLE advertisement discovery is non-deterministic). A client that connects to the losing host is done with migration — it receives `hello_ack` and `roster_snapshot`, completes migration resume, and has no mechanism to discover that a "better" host exists.

The result is a persistent session split: some clients on one host, others on another, both operating with the same `sessionId` but divergent rosters. The losing host has clients, so it does not emit `session_ended` at acceptance-window expiry. Neither host is aware of the other.

The dual-host window is narrow (both must start advertising and be discovered before either attracts all clients), and BLE environments with only 2-7 devices make simultaneous discovery of the wrong host unlikely. But the merge characterizes this as "transient and self-resolving," which is only true when no clients connect to the losing host.

**Safely dismissable if:** The probability of clients connecting to different hosts is negligible in the target BLE environment (small peer counts, same physical space, similar advertisement timing), AND the application layer tolerates rare permanent splits as equivalent to session loss.

---

## Observation 4

**Section:** Change 5 (App Lifecycle), step 2 (terminating)
**Nature:** Specification drift
**Ref:** "Invoke Leave() with immediate teardown (skip departure delay from Change 2 step 2c)."

The merge instructs implementations to call `Leave()` with "immediate teardown" but defines no mechanism for this. `Leave()` has no parameter to signal immediate mode. Two implementors could reasonably: (a) add a boolean parameter to `Leave(immediate)`, (b) set a module-level flag before calling `Leave()`, (c) call `FinishLeave()` directly and skip `Leave()` entirely, or (d) call `Leave()` as-is and accept the 100ms delay. These produce different behavior, particularly in option (c) which bypasses the graceful-migration check at `Leave()` step 1.

Additionally, the "skip departure delay" instruction references only Change 2's 100ms departure send timeout. It does not address the 400ms Migration Departure Delay (v2 Section 8.1 step 7). If a Resilient host with clients receives a "terminating" event, `Leave()` step 1 triggers `BeginGracefulMigration()`, which schedules a 400ms departure timer. During termination, 400ms is likely unavailable. The merge's error section mentions "insufficient background execution time for graceful migration" but only in the context of background transitions, not termination.

**Safely dismissable if:** A future editorial pass defines a normative mechanism for immediate-mode Leave (parameter, flag, or alternative entry point), and addresses whether the migration departure delay is also skipped during termination.

---

## Observation 5

**Section:** Change 6 (Divergent Successor Elections), step 10a
**Nature:** Specification drift
**Ref:** "The Room Advertisement encodes the migrated session info (same sessionId, localPeerID as new host, same maxClients, roomName, current membershipEpoch)."

The v2 Room Advertisement format (Section 3.1) is a fixed-layout UTF-8 string: `Prefix | SessionID | HostPeerID | Transport | MaxClients | PeerCount | RoomName`. There is no field for `membershipEpoch`. Step 10a lists `membershipEpoch` as part of the advertisement's content, but the wire format cannot carry it.

This is likely a descriptive error rather than an intent to extend the wire format — the scanning client does not need the epoch from the advertisement (it receives it via `roster_snapshot` after the hello handshake). But the language "The Room Advertisement encodes... current membershipEpoch" could lead an implementor to attempt adding an epoch field to the advertisement, which would break the wire format and interoperability with v2 devices.

**Safely dismissable if:** Step 10a is read as describing the session state that the advertisement represents (not the literal fields it encodes), and a future editorial pass clarifies the language to distinguish between "the advertisement identifies this session" and "the advertisement contains these fields."

---

## Observation 6

**Section:** Change 1 (shouldEmit Derivation), steps 2b/2c
**Nature:** Silent assumption
**Ref:** "the disconnected device is not the GATT device for the current reconnect attempt"

The device-identity comparison requires a stored reference to "the GATT device for the current reconnect/migration attempt." The merge's rationale states: "Both platforms store the current device reference (`clientGatt` on Android, `_connectedPeripheral` on iOS), making this check implementable without new state."

However, `clientGatt` and `_connectedPeripheral` are GATT connection handles, not device-identity references. `StopClientOnly()` nulls these handles (Android line 1917, iOS line 1576). The merge resolves this by placing the derivation (step 2) before `StopClientOnly()` (step 3), so the handles are still populated when the comparison runs.

The assumption is that the stale disconnect callback fires after the `OnClientDisconnected` handler has already begun — i.e., during or after step 2. If the stale callback fires before the handler begins (which is the expected timing: the stale callback triggers the handler), then the comparison is between the callback's device and the value of `clientGatt`/`_connectedPeripheral` at that moment. If `ConnectToRoom` step 2 already called `StopClientOnly()` (nulling the reference) and step 6 has initiated a new connection (setting a new reference), the comparison works: callback device (old) != current reference (new or null) → shouldEmit = false. If step 6 has not yet executed, the reference is null: callback device (old) != null → shouldEmit = false. Both cases resolve correctly.

But this relies on null never equaling any actual device reference, and on the platform's disconnect callback providing the device identity of the disconnected connection (not just a status code). Both are true for Android (`BluetoothGatt` parameter) and iOS (`CBPeripheral` parameter), but the merge does not state these as requirements.

**Safely dismissable if:** All target platforms deliver device identity in the disconnect callback, and null-comparison semantics (null != any device) hold for those platforms. Both are true for Android and iOS but are not stated as normative requirements for future platforms.

---

## Observation 7

**Section:** Change 5 (App Lifecycle), platform mapping table
**Nature:** Specification drift
**Ref:** "App entering background: Android: `onPause()` or `onStop()` in Activity"

The platform mapping lists both `onPause()` and `onStop()` as options for Android without specifying which one maps to the "background" lifecycle event. These have different semantics: `onPause()` fires when the activity loses focus (including partial occlusion by a dialog, split-screen focus change, or notification shade pull-down); `onStop()` fires when the activity is no longer visible. Using `onPause()` triggers Leave() for non-terminal interruptions (incoming call overlay, notification banner). Using `onStop()` misses cases where the activity is partially visible but BLE may be degraded.

The table is marked "informative, not normative," which limits the blast radius. But both proposals identified this as a real tradeoff (Proposal B explicitly discussed `willResignActive` vs. `applicationDidEnterBackground` for the same reason on iOS), and the Android side leaves the choice unresolved.

**Safely dismissable if:** The informative status of the table is sufficient, and the normative "background or inactive" language in the function body is precise enough that Android implementors can independently arrive at a consistent choice. Given that Proposal B flagged this as a known tradeoff on iOS (where both events are also listed), the same ambiguity exists on both platforms.

---

## Observation 8

**Section:** Change 4 (FinishLeaveClient) applied at Section 7.1 FailReconnect step 4
**Nature:** Scope gap
**Ref:** FailReconnect step 4 changes from `FinishLeave(null)` to `FinishLeaveClient()`

`FinishLeaveClient()` cleans up GATT client state, dedup, fragment assemblies, and sets `clientJoined = false`, `clientLeaving = true`. It does NOT: cancel non-reconnect timers (heartbeat, pending-client), clear session identifiers (`joinedSessionId`, `joinedRoomId`, `hostPeerId`), clear the rooms map, or reset flags beyond `clientJoined`/`clientLeaving`.

`FailReconnect()` steps 1-3 cancel the reconnect timeout, clear reconnect state, and stop the scan. But after step 4 (`FinishLeaveClient`) and step 5 (`emit session_ended`), the device retains stale session identifiers. If the device was a pure client (not hosting), these identifiers serve no purpose and are overwritten by the next `ConnectToRoom` step 3. But `ConnectToRoom` step 1's duplicate-join guard checks: "If already connected to the same room/session/host and not leaving, return." After `FinishLeaveClient` sets `clientLeaving = true`, this guard evaluates false regardless of stale identifiers, so the next join proceeds.

During migration (the case that motivates `FinishLeaveClient`), the device is both host and client. Using `FinishLeaveClient` correctly preserves host state. But `FailReconnect` is called when reconnect fails, which implies the session is over for this device as a client. If the device is also a host during migration, is `FailReconnect` ever called? The migration path uses `FailMigration`, not `FailReconnect`. So `FailReconnect` may only be called for pure clients, where the full `FinishLeave` would have been safe.

**Safely dismissable if:** `FailReconnect` is never called during an active migration (i.e., only `FailMigration` handles migration-path failures), AND the stale session identifiers left by `FinishLeaveClient` do not affect any subsequent operation due to `clientLeaving = true` and `ConnectToRoom`'s overwrite behavior. Both appear to be true but are not stated as invariants.

---

## Observation 9

**Section:** Change 1 (shouldEmit Derivation), step 3 + Change 4 (FinishLeaveClient), step 1
**Nature:** Silent assumption
**Ref:** `StopClientOnly()` is called at Change 1 step 3, then again inside `FinishLeaveClient()` at steps 7a/8a

The disconnect tree calls `StopClientOnly()` at step 3. If recovery attempts (steps 4-6) all fail, step 7a calls `FinishLeaveClient()`, whose step 1 calls `StopClientOnly()` again. `StopClientOnly()` nulls the GATT reference, closes the GATT client, and clears write queues. The second call operates on already-null references.

The specification does not state that `StopClientOnly()` is idempotent. If the procedure has side effects on second invocation (e.g., attempting to close an already-closed GATT connection throws an exception, or logging produces misleading output), the double call could cause issues. Both current implementations handle null checks internally, but this is implementation behavior, not a specified contract.

**Safely dismissable if:** `StopClientOnly()` is defined (or amended to require) idempotent behavior — i.e., calling it when GATT state is already cleaned up is a no-op. Both current implementations satisfy this, but it is not a stated requirement.

---

## Observation 10

**Section:** Rejection of Proposal B Item 6 (OnNewHostReady)
**Nature:** Unresolved problem
**Ref:** "The behavior is already specified. The function adds specification surface area without adding new semantics."

The rejection is sound: the hello handshake (Section 6.5) and roster delivery already define the behavior. However, the underlying problem Proposal B was addressing — making explicit that the hello/roster_snapshot handshake for `migration_resume` joins is the normative convergence resolution mechanism — is addressed only in a clarifying note appended to Section 8.3.

A future implementor reading Section 6.5 (hello handshake) will see that `migration_resume` joins receive `hello_ack` and `roster_snapshot`, but nothing in Section 6.5 signals that this roster_snapshot carries special weight as the authoritative post-migration state. The Section 8.3 note establishes this, but the distance between the operational flow (Section 6.5) and the architectural statement (Section 8.3 note) means an implementor could: (a) implement the handshake correctly, (b) not realize the roster_snapshot must overwrite the client's local roster completely (not merge), and (c) produce subtle state divergence.

**Safely dismissable if:** The existing Section 8.5 (`CompleteMigrationResume`) step 3 — "Set local membershipEpoch to the epoch received in the migration control message" — combined with the standard roster_snapshot processing rules, is unambiguous enough that an implementor would not attempt a merge strategy. The concern is that roster_snapshot processing rules are not explicitly "replace" semantics; if an implementor treats them as additive, divergence results.

---

## Observation 11

**Section:** Change 5 (App Lifecycle), step 1a + v2 Section 8.1 step 7 (Migration Departure Delay)
**Nature:** Scope gap
**Ref:** Step 1a triggers Leave() → BeginGracefulMigration() which includes a 400ms departure delay

When a Resilient host with clients backgrounds, Change 5 step 1a invokes `Leave()`, which triggers `BeginGracefulMigration()` (v2 Section 8.1). Step 5 of graceful migration sends `session_migrating` to all clients. Step 7 schedules a 400ms departure timer. Step 8 calls `FinishLeave` on departure timer expiry.

On iOS, `willResignActive` (or `applicationDidEnterBackground`) provides limited background execution time. The 400ms departure delay fits within this window. But `FinishLeave` at step 8 closes the GATT server, which tears down all client connections. Those clients must then discover and connect to the successor host — a process that takes variable time and is not bounded by the 400ms.

The concern is not the departure delay itself but what happens if the OS suspends the app between step 5 (session_migrating sent) and step 8 (FinishLeave). The clients have received `session_migrating` but the host has not torn down. Clients begin migration reconnect (scanning for the successor) while still connected to the old host. When the OS finally kills the old host's BLE stack, clients receive disconnect callbacks and may re-enter the disconnect tree — but they are already in migration reconnect, so step 4 of the disconnect tree routes them to `BeginMigrationReconnect()` (which is already in progress).

This is already handled by the existing flow, but the merge does not acknowledge that the OS may interrupt between sending `session_migrating` and completing teardown, leaving a window where the old host is still technically live but has committed to migrating.

**Safely dismissable if:** The existing migration flow already tolerates the old host remaining connected after `session_migrating` is sent (clients ignore further data from the old host during migration), and the OS interruption between steps 5 and 8 produces the same eventual state as completion of steps 5-8.

---

*End of observations. No actionable conflicts were found that would require reversal of any accepted or rejected decision. All observations are additive signal for the final editorial pass.*
