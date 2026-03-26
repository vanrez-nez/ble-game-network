# BLE Game Network Protocol — Specification Merge

**Date:** 2026-03-25 | **Baseline:** `protocol-spec.md` v1.0 | **Status:** Draft

**Inputs:** Proposal A (`protocol-spec.proposal-a.md`), Proposal B (`protocol-spec.proposal-b.md`)

---

## Purpose

This document is the authoritative next state of the protocol specification. It is derived from first principles, using Proposals A and B only as analytical inputs. Each accepted change states its objective and rationale. Each rejected or deferred item is logged with a reason. The document avoids implementation prescriptions where architectural objectives suffice.

**Governing principles (in priority order):**

1. **Stability over features.** Fewer changes with higher confidence. Reject proposals that solve symptoms rather than root causes.
2. **Architecture before implementation.** Prefer structural shifts that eliminate classes of problems over downstream patches.
3. **Merge only when strictly better.** Consolidate complementary proposals only when the combination is demonstrably superior to either alone.

---

## Part I — Architectural Changes

These changes alter protocol invariants or eliminate classes of bugs. They have cross-cutting dependencies and should be adopted as coherent groups.

---

### Change Group 1: Host-Authoritative Admission

**Sources:** B§1 (primary), A-C2 (subsumed), A-C4 (incorporated)

**Objective:** Make the host the single authority on session admission. Eliminate the window where a client considers itself admitted before the host has accepted it.

**Problem:** The current spec allows `CompleteLocalJoin()` (§6.4) to emit `joined`, `peer_status=connected`, or `session_resumed` before the host has processed `HELLO`. The host only admits a peer at `OnHelloReceived()` (§6.5), but has no mechanism to reject admission. This creates an undefined state where the client can send application messages before the host has validated the join. Every downstream rejection scenario — full room, duplicate peer, stale session — is unsolvable without fixing the authority model.

Additionally, no timeout exists for the pending state between GATT connection and HELLO completion (A-C4). On Android, any BLE device can connect to an open GATT server, occupying a slot indefinitely.

**Specification change:**

1. Add two control message types to §4.3:
   - `hello_ack` — Host to Client, admission granted.
   - `join_rejected` — Host to Client, admission denied. Payload contains a reason string.

2. Defined rejection reasons (minimum set):
   - `room_full` — Connected clients equal or exceed `max_clients`.
   - `duplicate_peer_id` — A peer with this ID is already in the session.
   - `stale_session` — The session ID in the HELLO does not match the current session.
   - `wrong_target` — The HELLO targets a peer ID that is not the current host.
   - `migration_mismatch` — The client is attempting migration resume but the host is not expecting migration.

3. Revised admission lifecycle:
   - Client connects and enables GATT notifications.
   - Client sends `hello`.
   - Client does NOT emit `joined` or mark itself admitted. Client enters a pending state.
   - Host validates the HELLO and responds with `hello_ack` or `join_rejected`.
   - Client emits `joined` (or reconnect/migration completion) only after receiving `hello_ack`.
   - If `join_rejected` is received, the client disconnects and emits a `join_failed` event with the rejection reason.

4. Add `Pending Client Timeout` to §17 (default: 5 seconds). A GATT-connected device that has not completed the `hello` to `hello_ack` exchange within this timeout is disconnected by the host. Checked on heartbeat tick.

5. Define `join_failed` event in §12 with fields: `reason`, `room_id`.

**Rationale:** A-C2 proposed adding a max-clients guard to `OnHelloReceived()` — a correct behavior, but one that only handles a single rejection case. B§1 restructures the authority model so that the host is the sole arbiter of admission. All current and future rejection reasons (including `room_full`) have a single mechanism. A-C4's pending client timeout is incorporated as the deadline for completing the handshake.

**Affected baseline sections:** §4.3, §6.4, §6.5, §12, §13

---

### Change Group 2: Authoritative Roster with Epoch and Continuous Hash Validation

**Sources:** B§2 (primary), A-C3 Option B (merged), A-H3 (subsumed)

**Objective:** Provide a single authoritative mechanism for roster state with ordering semantics that enable deterministic successor election, combined with a lightweight continuous consistency check.

**Problem:** The spec says "Send Roster" in §6.5 and §7.2 but never defines the wire format. The implementation sends individual `peer_joined` controls per connected client — meaning the roster is not authoritative (it only covers currently connected clients, not the full session roster including grace peers). If a `peer_left` control is lost (BLE notifications have no ACK per §4.2), a client retains a stale roster. During unexpected host recovery, clients with divergent rosters elect different successors, causing a network split (A-C1, A-C3).

**Specification change:**

1. Add `roster_snapshot` control message to §4.3 with payload:
   - `session_id` — Current session identifier.
   - `host_peer_id` — Current host's peer ID.
   - `membership_epoch` — Monotonically increasing integer, incremented on every membership change (join, leave, grace begin, grace expire).
   - Peer list — Pipe-delimited peer IDs with per-peer status suffix: `peerID:connected` or `peerID:reconnecting`.

2. Delivery rules:
   - Host sends `roster_snapshot` immediately after `hello_ack` for fresh joins.
   - Host sends `roster_snapshot` after reconnect acceptance.
   - Host broadcasts `roster_snapshot` to all clients after any membership change.
   - Migration control messages (§8.1) must include the current `membership_epoch`.

3. Extend heartbeat (§9) to include a 4-byte roster fingerprint: CRC32 of the sorted, concatenated peer IDs in the current roster. Clients compare against their local roster hash on each heartbeat. On mismatch, the client knows its roster is stale; the next `roster_snapshot` (triggered by the host detecting the divergence or by the next membership change) corrects it.

4. Successor election (§8.3) during recovery must use the roster associated with the highest `membership_epoch` known to the electing peer. Peers must not elect successors from ad-hoc local memory.

**Rationale:** Neither proposal alone is sufficient. B§2 provides the structural foundation — the `membership_epoch` gives roster changes a total ordering, which is what is actually needed to prevent split-brain during recovery. A-C3's heartbeat hash provides continuous cheap validation that catches missed control packets without requiring explicit request/response cycles. The combination is strictly better than either alone: epoch ordering prevents split-brain; hash validation provides self-healing consistency. A-H3 (defining `roster_sync` format) is subsumed by `roster_snapshot`, which is strictly more complete (includes epoch, host identity, peer states). A-C3 Option A (ACK-based roster confirmation) is rejected as excessive complexity for the BLE environment.

**Affected baseline sections:** §4.3, §6.5, §7.2, §8.1, §8.3, §9, §10

---

### Change Group 3: Separate Message ID from Fragment Nonce

**Sources:** B§3 (primary), A-H4 (rejected)

**Objective:** Resolve the architectural conflict between fragment nonce (transport-layer reassembly key) and dedup key (application-layer duplicate detection).

**Problem:** The current spec uses the fragment nonce for both reassembly (§5) and dedup keying (§10 keys on `fromPeerID:msgType:nonce`). Heartbeat (§9) re-broadcasts the stored packet, which must be re-fragmented with a new nonce for transport. But then dedup sees a different nonce and treats it as a new message. The alternative — reusing the old nonce — has undefined collision semantics with the reassembly layer. This conflict means heartbeat either defeats dedup or dedup blocks heartbeat.

**Specification change:**

1. Add a `message_id` field to the packet envelope (§4.1). This is a 16-bit identifier assigned by the sender at the application packet level, independent of fragment nonce.

2. Fragment nonce (§5) remains a transport reassembly key only, scoped to a single fragmentation event. It has no application-layer semantics.

3. Dedup (§10) keys on `(fromPeerID, msgType, message_id)` instead of `(fromPeerID, msgType, nonce)`.

4. Heartbeat (§9) re-sends with the same `message_id` (ensuring dedup correctly filters repeated delivery at peers that already received the message) but generates a fresh fragment nonce (ensuring transport reassembly works correctly for the new fragmentation event).

5. Heartbeat replay is restricted to broadcast message classes only. Directed messages are not replayed by heartbeat.

**Rationale:** B§3 identifies the root architectural conflict. A-H4 (store last broadcast per message type) addresses a storage concern but does not fix the nonce/dedup collision. With message ID separation, the correct behavior of heartbeat replay becomes well-defined, and the storage model (per-type or single) becomes an implementation decision rather than a protocol concern.

**Affected baseline sections:** §4.1, §5, §9, §10

---

### Change Group 4: Grace Peers and Migration Policy

**Sources:** B§4 (framing), A-C1 (convergence fallback, successor amendment)

**Objective:** Explicitly define whether peers in reconnect grace survive host migration, and ensure successor election converges even when an elected successor fails.

**Problem:** The spec is silent on what happens to reconnect-grace peers during migration. `SelectSuccessor()` (§8.3) uses connected clients only, excluding grace peers. `SelectRecoverySuccessor()` (§8.3) uses session peer IDs, which includes grace peers because `BeginPeerReconnectGrace()` (§7.2) keeps them in the roster. This inconsistency means a disconnected peer can be elected successor during unexpected host loss but not during graceful departure. If the elected successor is actually disconnected, it cannot advertise, and the network deadlocks.

**Specification change:**

1. **v1 policy: Exclude grace peers from migrated sessions.** When migration begins (graceful or recovery), peers currently in reconnect grace are treated as departed. They are removed from the session roster. Their grace timers are cancelled. If they reconnect to the old host's address, they find the session gone.

2. Amend `SelectRecoverySuccessor()` to exclude peers in reconnect grace, matching `SelectSuccessor()` behavior. Both functions operate on the set of connected (non-grace) peers.

3. **Convergence fallback:** If the elected successor does not begin advertising within the Migration Timeout (default 3 seconds per §17), remaining clients re-run successor election with that peer excluded from the candidate set. This repeats until a successor advertises or the candidate set is exhausted, at which point the session is considered lost and `session_ended` is emitted.

4. The `roster_snapshot` sent by the new host after migration (per Change Group 2) must reflect the exclusion of grace peers.

**Rationale:** B§4 correctly identifies that the spec must make an explicit architectural choice rather than leaving the behavior undefined. The exclusion model is chosen per governing principle 1 (stability over features) — preserving grace across migration (B§4 Option B) would require grace metadata transfer, inherited timers, capacity reservation, and successor rules for honoring inherited grace windows, which is disproportionate complexity for v1. A-C1's convergence fallback addresses the separate but related problem of elected successor failure.

**Affected baseline sections:** §7.2, §8.1, §8.2, §8.3, §8.4

---

## Part II — Specification Completions

These are gaps where the protocol behavior is either already implemented or straightforward to define, but the spec is silent. They do not change protocol invariants.

---

### Completion 5: Capacity Semantics

**Sources:** B§5 (primary), A-M4 (subsumed)

**Objective:** Make advertised capacity fields unambiguous so that lobby display, admission control, and slot accounting use consistent definitions.

**Problem:** §3.1 defines `MaxClients` and `PeerCount` in the room advertisement but never states whether the host is counted in either field. This ambiguity affects lobby occupancy display, full-room decisions, slot accounting during reconnect grace, and migration capacity carry-over.

**Specification change:**

- `max_clients` counts non-host client slots only.
- `peer_count` counts admitted non-host clients only. Host is never counted.
- A solo host advertises `peer_count = 0`.
- Peers in reconnect grace do not increment `peer_count` but their slots remain reserved against `max_clients` for admission purposes.
- When a room fills between discovery and HELLO, the host responds with `join_rejected(room_full)` per Change Group 1.
- §3.1 must clarify that `MaxClients` and `PeerCount` exclude the host.

**Rationale:** B§5 provides a comprehensive semantic model. A-M4 raised the question without providing a complete answer.

**Affected baseline sections:** §3.1, §6.5

---

### Completion 6: Fragment Validation and Retry Resolution

**Sources:** B§6 (primary), A-H2 (incorporated)

**Objective:** Define mandatory validation rules for malformed fragments. Resolve the contradiction between retry constants in §17 and the immediate-failure behavior in §15.

**Problem:** §17 defines `Write Retry Timeout` (1.5s) and `Write Retry Max` (5), but §15.1 step 6c says a failed write clears the queue immediately. These are contradictory. The spec also has no validation rules for malformed fragments.

**Specification change:**

1. Add mandatory fragment rejection rules to §5.4:
   - Reject if fragment header is shorter than 5 bytes.
   - Reject if `count == 0`.
   - Reject if `index >= count`.
   - Reject if version byte does not equal `1`.

2. Add `Max Concurrent Assemblies Per Source` to §17 (default: 32). When the limit is exceeded for a given source, discard the oldest assembly before creating a new one. This bounds resource consumption from misbehaving peers.

3. **Remove `Write Retry Timeout` and `Write Retry Max`** from §17. These constants have no specified semantics — no section describes which failures are retryable, timer behavior, queue handling during retry, or retry exhaustion. Per governing principle 1, unspecified retry behavior is worse than explicit no-retry. If retry support is needed, it should be added as a self-contained future specification with full semantics.

4. §15.1 step 6c retains its current behavior: on write failure, clear the queue and emit `write_failed` error (see Completion 11).

**Rationale:** B§6 correctly identifies that retry constants without semantics create ambiguity and platform divergence. The fragment validation rules are independent of the retry question and must be adopted regardless. A-H2's assembly limit is incorporated as a resource-bounding mechanism.

**Affected baseline sections:** §5.4, §5.5, §15, §17

---

### Completion 7: Pending Client Timeout

**Source:** A-C4

This completion is defined as part of Change Group 1 (step 4). See Change Group 1 for the full specification.

**Affected baseline sections:** §6.1, §6.5, §17

---

### Completion 8: In-Flight Data During Migration

**Source:** A-H1

**Objective:** Define what happens to write queues and partial fragment assemblies during the migration transition window.

**Problem:** §8.1 sends `session_migrating`, waits 400ms, then the host departs. The spec says nothing about in-flight data during this window. Write queues (§15) may contain unsent fragments. Fragment assemblies (§5.4) may be partially complete. Without defined behavior, data is silently lost or delivered into an inconsistent session state.

**Specification change:**

- After sending `session_migrating`, the departing host stops accepting new data writes and continues pumping its existing notification queue until departure.
- On receiving `session_migrating`, clients discard their write queue and clear all in-progress fragment assemblies.
- Data lost during the migration window is recovered via heartbeat after the successor begins hosting. With Change Group 3 adopted, heartbeat replay semantics are well-defined.

**Affected baseline sections:** §5.4, §8.1, §15.1, §15.2

---

### Completion 9: Directed Message Routing

**Source:** A-M1

**Objective:** Define host relay behavior for directed messages (non-empty `ToPeerID`).

**Problem:** §4.1 defines the `ToPeerID` field but the spec never describes how the host routes directed packets.

**Specification change — add §4.4 "Message Routing":**

- Empty `ToPeerID`: broadcast to all connected clients except sender. Host delivers to self if host is not the sender.
- `ToPeerID` matches a connected client: forward only to that client.
- `ToPeerID` matches the host's own peer ID: deliver to host, do not relay.
- `ToPeerID` references a peer in reconnect grace or an unknown peer ID: drop silently.

**Affected baseline sections:** §4 (new subsection §4.4)

---

### Completion 10: CompleteMigrationResume Definition

**Source:** A-M5

**Objective:** Define the `CompleteMigrationResume()` procedure that §6.4 references but no section specifies.

**Problem:** §6.4 step 4 calls `CompleteMigrationResume()` but the procedure is never defined. §12 lists `session_resumed` as an event type but no procedure emits it.

**Specification change — add §8.5 "CompleteMigrationResume":**

```
CompleteMigrationResume():
1. Cancel Migration Timeout.
2. Clear migration state fields (pending successor, migration session info).
3. Emit session_resumed event with:
   - session_id: the migrated session's ID
   - new_host_id: the successor's peer ID
   - peers: the current peer roster
4. If Change Group 2 is adopted: set local membership_epoch
   to the epoch received in the migration control message.
```

**Affected baseline sections:** §6.4, §8 (new subsection §8.5), §12

---

### Completion 11: Minor Specification Fixes

**Sources:** A-M2, A-M3, A-M6, A-L1, A-L2, A-L3

These are individually small clarifications that can be adopted in a single editorial pass.

**M-2 — Empty table codec rule:**
Add rule 5 to §11.3: "Empty table (no keys) encodes as Array with count 0: type tag `0x05` followed by 4-byte little-endian `0x00000000`." This matches the existing implementation in `Codec.cpp:195`.

**M-3 — Nonce wraparound note:**
Add informational note to §5.3: "The 16-bit nonce wraps after 65,535 packets. At typical BLE throughput (well under 1,000 packets/second), collision with the dedup window (5 seconds, 64 entries) requires sustained rates exceeding 13,000 packets/second. This is not a practical concern."

**M-6 — Transport naming:**
Add to §1 glossary: "`Normal` is an accepted application-layer alias for `Reliable`. The wire protocol uses `'r'` (Reliable) and `'s'` (Resilient) only."

**L-1 — shouldEmit=false branch:**
Add step 6 to §13 (Client Disconnect Decision Tree): "If none of the above conditions returned a result: perform silent cleanup with no events emitted."

**L-2 — Write failure error code:**
Define error code `write_failed` in §12 for §15.1 step 6c, with a `detail` field containing the platform-specific BLE error string.

**L-3 — Room name length note:**
Add note to §3.2: "`NormalizeRoomName()` applies to BLE advertisement encoding only (8-character truncation). Applications may accept longer names locally; the advertised name is a truncated representation."

**Affected baseline sections:** §1, §3.2, §5.3, §11.3, §12, §13, §15.1

---

## Part III — Deferred and Rejected Items

### Rejected

| Item | Source | Reason |
|------|--------|--------|
| Per-type broadcast storage | A-H4 | Subsumed by Change Group 3. Once message ID is separated from fragment nonce, heartbeat replay is well-defined and the storage model is an implementation decision, not a protocol concern. |
| Standalone MaxClients guard in OnHelloReceived | A-C2 | Subsumed by Change Group 1. Host-authoritative admission with `join_rejected(room_full)` is the architectural solution. The guard is a natural implementation consequence. |
| ACK-based roster confirmation | A-C3 Opt A | Excessive complexity for BLE's constrained environment. The merged approach (epoch snapshots + heartbeat hash) provides equivalent consistency with less protocol machinery. |

### Deferred

| Item | Source | Reason |
|------|--------|--------|
| Config range discrepancy [1,7] vs [1,8] | A-C2 | Implementation configuration, not protocol. The wire format (§3.1) uses a single ASCII digit, supporting `'1'`–`'9'`. The spec should state the wire maximum and leave application defaults to configuration. |
| Preserve grace peers across migration | B§4 Opt B | Requires grace metadata transfer, inherited timers, capacity reservation, and successor rules for honoring inherited grace. Disproportionate complexity for v1. Revisit for v2 if use cases demand it. |
| Full retry semantics | B§6 Opt B | Per governing principle 1, unspecified retry is worse than no retry. If retry is needed in a future version, it must be a self-contained specification covering retryable failures, timer behavior, and queue handling during retry. |

---

## Adoption Order

Changes are ordered by dependency. Each group depends on the groups above it being adopted first.

| Priority | Change | Dependency | Rationale |
|----------|--------|------------|-----------|
| 1st | Group 1: Host-Authoritative Admission | None | Foundation. All other groups assume `hello_ack` exists. |
| 2nd | Group 2: Roster Epoch + Hash | Group 1 | `roster_snapshot` is sent after `hello_ack`. |
| 3rd | Group 3: Message ID Separation | None (technically independent) | Heartbeat semantics must be resolved before migration data handling. |
| 4th | Group 4: Grace + Migration | Groups 1, 2 | Roster epoch needed for successor election convergence. |
| 5th | Completions 5–7 | Group 1 | Capacity and pending timeout depend on the admission model. |
| 6th | Completions 8–9 | None | Migration data handling and routing are independent. |
| 7th | Completions 10–11 | None | Procedure definitions and editorial fixes. Independent. |

---

## Cross-Reference Matrix

| Change | Source Proposals | Baseline Sections Modified |
|--------|-----------------|---------------------------|
| Group 1: Admission | B§1, A-C2, A-C4 | §4.3, §6.4, §6.5, §12, §13, §17 |
| Group 2: Roster | B§2, A-C3, A-H3 | §4.3, §6.5, §7.2, §8.1, §8.3, §9 |
| Group 3: Message ID | B§3 | §4.1, §5, §9, §10 |
| Group 4: Grace/Migration | B§4, A-C1 | §7.2, §8.1, §8.2, §8.3, §8.4 |
| Completion 5: Capacity | B§5, A-M4 | §3.1, §6.5 |
| Completion 6: Fragments | B§6, A-H2 | §5.4, §5.5, §15, §17 |
| Completion 7: Pending | A-C4 | §6.1, §6.5, §17 |
| Completion 8: Migration Data | A-H1 | §5.4, §8.1, §15.1, §15.2 |
| Completion 9: Routing | A-M1 | §4 (new §4.4) |
| Completion 10: Resume Proc | A-M5 | §6.4, §8 (new §8.5), §12 |
| Completion 11: Minor Fixes | A-M2, M3, M6, L1–L3 | §1, §3.2, §5.3, §11.3, §12, §13, §15.1 |

---

## Traceability: All Proposal Items

Every item from both proposals is accounted for below.

| Proposal A ID | Disposition | Destination |
|---------------|-------------|-------------|
| C-1 | Accepted (partial) | Group 4 — convergence fallback and successor amendment |
| C-2 | Rejected (subsumed) | Group 1 — room_full is one rejection reason in host-authoritative admission |
| C-3 | Accepted (Option B, merged) | Group 2 — heartbeat hash as secondary mechanism |
| C-4 | Accepted | Group 1 step 4, Completion 7 |
| H-1 | Accepted | Completion 8 |
| H-2 | Accepted (incorporated) | Completion 6 — assembly limit |
| H-3 | Rejected (subsumed) | Group 2 — roster_snapshot replaces roster_sync |
| H-4 | Rejected | See Part III — subsumed by Group 3 |
| M-1 | Accepted | Completion 9 |
| M-2 | Accepted | Completion 11 |
| M-3 | Accepted | Completion 11 |
| M-4 | Rejected (subsumed) | Completion 5 — B§5 provides complete answer |
| M-5 | Accepted | Completion 10 |
| M-6 | Accepted | Completion 11 |
| L-1 | Accepted | Completion 11 |
| L-2 | Accepted | Completion 11 |
| L-3 | Accepted | Completion 11 |

| Proposal B § | Disposition | Destination |
|--------------|-------------|-------------|
| §1 | Accepted (primary) | Group 1 |
| §2 | Accepted (merged with A-C3) | Group 2 |
| §3 | Accepted (primary) | Group 3 |
| §4 | Accepted (framing; Option A chosen) | Group 4 |
| §5 | Accepted (primary) | Completion 5 |
| §6 | Accepted (framing; Option A chosen) | Completion 6 |
