# Post-Merge Amendments — BLE Game Network Protocol v3

**Source document:** `version-3/merge.md` (2026-03-27)
**Trigger document:** `version-3/review.md` (2026-03-27)
**Date:** 2026-03-27

This document records changes to the consolidated specification after the merge was finalized. Each amendment is sequentially numbered and immutable once assigned.

---

## Amendment 1

**Affected section:** Change 3 (GATT Connection Failure), informative note after step 8; Change 1 (shouldEmit Derivation), interaction with Change 3

**Change:** The informative note after Change 3 step 8 ("On platforms where GATT connection failure is delivered as a disconnect callback... step 8 takes precedence over the Section 13 disconnect tree") is promoted from informative to normative, and a state-based enforcement mechanism is added.

Before: The note was labeled "Informative note (not normative)" and provided guidance that step 8 should take precedence.

After: The note is normative. Additionally, the following requirement is added to Change 3 step 8:

```
  8. On GATT connection failure (or post-connection setup failure from 7b/7c):
     8a. Set connectionFailureHandled = true.
     8b. Call StopClientOnly().
     ...

REQUIREMENT: On platforms where GATT connection failure is delivered as
a disconnect callback (notably Android), the implementation MUST route
the event exclusively through step 8 when clientJoined is false and the
status indicates connection establishment failure. The Section 13
disconnect tree MUST NOT process the same event. If an implementation
cannot guarantee exclusive routing, it MUST check
connectionFailureHandled at the entry of OnClientDisconnected(); if
true, clear the flag and return without executing the disconnect tree.
```

The flag `connectionFailureHandled` is added as a module-level boolean, default false, set to true at step 8a, checked and cleared at the top of `OnClientDisconnected()`.

**Trigger:** External review, Observation 1. Confirmed upon re-examination.

**Justification:** Change 3 step 8b clears `reconnectJoinInProgress` and resumes the reconnect scan. If Android then delivers the same connection failure as a disconnect callback into the Change 1 disconnect tree, `reconnectJoinInProgress` is false, `clientLeaving` is false, and `wasJoined` is false. This routes to step 7: `FinishLeaveClient()` followed by `emit error("join_failed")` — emitting a terminal error to the application while the reconnect scan is still active. The informative note identified the correct behavior but provided no mechanism for enforcement. Without a normative guard, an implementor following the specification literally would process the same event twice with contradictory outcomes.

---

## Amendment 2

**Affected section:** Change 7 (Migration Acceptance Window), `BeginHostingMigratedSession` procedure

**Change:** Add step 1a to `BeginHostingMigratedSession` cancelling the migration timeout scheduled by `BeginMigrationReconnect()` step 3.

Before: `BeginHostingMigratedSession` steps 1-7 did not reference the migration timeout.

After:

```
FUNCTION BeginHostingMigratedSession(migrationInfo) -> void

  1. Start GATT server with migrated session info
     (sessionId, roomName, maxClients, membershipEpoch).
  1a. Cancel the migration timeout scheduled by BeginMigrationReconnect()
      step 3. The successor is now hosting; the migration timeout applies
      to the reconnecting-client path, not the hosting path.
  2. Set migrationAcceptanceActive = true.
  3-7. [Unchanged]
```

**Trigger:** External review, Observation 2. Confirmed upon re-examination against v2 Section 8.4.

**Justification:** `BeginMigrationReconnect()` step 3 schedules a 3-second migration timeout unconditionally — including when step 1 takes the "becoming Host" branch. If not cancelled, `FailMigration()` fires at the same time as the Migration Acceptance Window expiry. The v2 specification does not define `FailMigration()` behavior for a device that is already actively hosting, creating an ambiguous state where the session may be torn down immediately after the acceptance window closes. Cancelling the migration timeout when hosting begins eliminates this ambiguity: the successor is no longer migrating, it is hosting.

---

## Amendment 3

**Affected section:** Change 6 (Divergent Successor Elections), "Acknowledged transient state" paragraph

**Change:** Remove the characterization "transient and self-resolving" and replace with an accurate description of the dual-host outcome.

Before:
> **Acknowledged transient state:** If two clients both believe they are the successor and both start GATT servers, two rooms with the same session ID will be advertising simultaneously. The "first discovered wins" rule resolves this for scanning clients. The losing host will continue advertising until its own migration timeout expires with no clients connecting, at which point it emits `session_ended`. This state is transient and self-resolving.

After:
> **Acknowledged transient state:** If two clients both believe they are the successor and both start GATT servers, two rooms with the same session ID will be advertising simultaneously. The "first discovered wins" rule causes each scanning client to connect to whichever successor it discovers first. If all scanning clients discover the same successor, the other successor receives no connections and emits `session_ended` when its Migration Acceptance Window expires — resolving the dual-host state. If different clients connect to different successors, the result is a persistent session split: two independent sessions operating with the same `sessionId` but divergent rosters. Neither host is aware of the other. The protocol does not provide a split-resolution mechanism; both sessions continue independently until they end by other means. The probability of a persistent split is low in the target environment (small peer counts in close physical proximity produce similar BLE discovery ordering), but it is not zero.

**Trigger:** External review, Observation 3. Confirmed upon re-examination.

**Justification:** The original characterization was factually conditional: it assumed no clients connect to the losing host. BLE advertisement discovery is non-deterministic. `OnScanResultDuringMigration` step 3 directs clients to accept any known session member that is advertising, so different clients may connect to different successors. When the losing host has clients, it does not emit `session_ended` at acceptance-window expiry — it continues operating. The corrected text states the actual outcome space without overstating the protocol's convergence guarantee.

---

## Amendment 4

**Affected section:** Change 5 (App Lifecycle), step 2 (terminating)

**Change:** Define the mechanism for immediate-mode teardown during termination and extend the scope to cover the 400ms Migration Departure Delay.

Before:
```
  2. If newState is "terminating":
     2a. Invoke Leave() with immediate teardown (skip departure delay
         from Change 2 step 2c). There is no time budget for
         best-effort message delivery during termination.
```

After:
```
  2. If newState is "terminating":
     2a. If hosting is true AND transport is Resilient AND connected client count > 0:
         -> Send session_migrating to all clients (best-effort, no delivery wait).
         -> Call FinishLeave("host_left") immediately.
            Do not schedule the 400ms Migration Departure Delay
            (v2 Section 8.1 step 7). Do not wait for the Departure
            Send Timeout (Change 2 step 2c).
            Clients will detect host loss via disconnect callback and
            enter unexpected host recovery (Section 8.2).
     2b. Else:
         -> Call FinishLeave(null) immediately.
            Do not send the client_leaving departure message
            (Change 2 step 2a). Do not wait for any write callback.
```

The error handling entry is also updated:

Before:
```
  - Leave() fails during background transition (e.g., GATT server
    already torn down by OS) -> attempt FinishLeave("host_left")
    to clean up local state. Session may enter unexpected recovery
    on the client side.
```

After:
```
  - Leave() fails during background transition (e.g., GATT server
    already torn down by OS) -> attempt FinishLeave("host_left")
    to clean up local state. Session may enter unexpected recovery
    on the client side.
  - Termination handler is interrupted by OS before FinishLeave
    completes -> client-side recovery handles the abrupt host loss.
    No protocol-level mitigation is possible.
```

**Trigger:** External review, Observation 4. Confirmed upon re-examination.

**Justification:** The original text instructed "Invoke Leave() with immediate teardown" but `Leave()` accepts no parameter to signal immediate mode. Four distinct interpretations were possible (boolean parameter, module flag, direct `FinishLeave()` call, or accept the delay), producing different behavior — particularly option (c) which bypasses the graceful-migration check. Additionally, only the 100ms departure send timeout was addressed; the 400ms Migration Departure Delay from v2 Section 8.1 step 7 was not mentioned, despite being unavailable during termination. The amended text calls `FinishLeave()` directly with explicit skip of both delays, and handles the Resilient-host-with-clients case separately to ensure `session_migrating` is sent best-effort before teardown.

---

## Amendment 5

**Affected section:** Change 6 (Divergent Successor Elections), `BeginUnexpectedHostRecovery` step 10a

**Change:** Remove `membershipEpoch` from the Room Advertisement field list in step 10a.

Before:
```
  10a. The Room Advertisement encodes the migrated session info
       (same sessionId, localPeerID as new host, same maxClients,
       roomName, current membershipEpoch).
```

After:
```
  10a. The Room Advertisement encodes the migrated session info
       (same sessionId, localPeerID as new host, same maxClients,
       roomName). The current membershipEpoch is not carried in the
       advertisement (the wire format has no field for it); it is
       delivered to reconnecting peers via roster_snapshot after
       the hello handshake completes.
```

**Trigger:** External review, Observation 5. Confirmed against v2 Section 3.1.

**Justification:** The v2 Room Advertisement wire format (Section 3.1) is a fixed-layout string: `Prefix | SessionID | HostPeerID | Transport | MaxClients | PeerCount | RoomName`. There is no `membershipEpoch` field. The original text could lead an implementor to attempt adding an epoch field to the advertisement, breaking the wire format and interoperability with v2 devices. The epoch is available through the migration payload and `roster_snapshot` — the advertisement does not need to carry it.

---

## Amendment 6

**Affected section:** Change 4 (FinishLeaveClient), `StopClientOnly()` usage across Change 1 and Change 4

**Change:** Add a normative requirement that `StopClientOnly()` MUST be idempotent.

The following note is appended to Change 4's specification, after the ERRORS section:

```
REQUIREMENT: StopClientOnly() MUST be idempotent. Calling it when GATT
client state is already cleaned up (null references, empty queues) MUST
be a no-op with no side effects. This is required because the Client
Disconnect Decision Tree (Change 1) calls StopClientOnly() at step 3,
and if recovery attempts at steps 4-6 all fail, step 7a/8a calls
FinishLeaveClient() whose step 1 calls StopClientOnly() again.
```

**Trigger:** External review, Observation 9. Confirmed upon re-examination of Change 1 step 3 and Change 4 step 1.

**Justification:** The disconnect tree calls `StopClientOnly()` at Change 1 step 3 to clean up GATT state before deriving recovery actions. If all recovery paths fail, step 7a calls `FinishLeaveClient()`, whose step 1 calls `StopClientOnly()` a second time. The second call operates on already-null references and empty queues. Without an idempotency requirement, an implementation could throw on the second call (e.g., attempting to close an already-closed GATT connection) or produce misleading diagnostics. Both current implementations handle this via null checks, but the behavior is not a stated contract. Making it normative ensures future implementations do not introduce regressions on this code path.

---

*End of amendments. 6 amendments recorded.*
