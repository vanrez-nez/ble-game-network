# Protocol Spec Merge — Amendments

**Date:** 2026-03-25 | **Applies to:** `protocol-spec.merge.md`

This document records post-merge amendments to the specification. Each entry is immutable once assigned. Observations that produced no change leave no trace here.

---

### AMD-1: Extend HELLO Payload for Host-Side Admission Validation

**Affected section:** Change Group 1, specification change step 2 (rejection reasons) and step 3 (admission lifecycle)

**Change:** Add to step 3 of Change Group 1, after "Client sends `hello`":

> The `hello` control message payload must include:
> - `peer_id` — The client's peer ID (existing).
> - `session_id` — The session ID the client believes it is joining. Empty string for a fresh join where no prior session context exists.
> - `join_intent` — One of: `fresh`, `reconnect`, or `migration_resume`.
>
> The host uses these fields to evaluate admission:
> - `stale_session` is returned when `session_id` is non-empty and does not match the current session.
> - `migration_mismatch` is returned when `join_intent` is `migration_resume` but the host is not in a migration-acceptance state.
> - `wrong_target` is evaluated from the packet's `ToPeerID` field (already defined in §4.1).

**Trigger:** Internal re-examination prompted by external observation (`protocol-spec.review.md`, observation 1).

**Justification:** The merge defined five rejection reasons but never specified the input data required to evaluate three of them. `stale_session` requires the client to declare which session it expects. `migration_mismatch` requires the client to declare its resume intent. Without these fields in the `hello` payload, the host cannot distinguish a fresh join from a reconnect or migration resume attempt, and the rejection reasons `stale_session` and `migration_mismatch` are unimplementable.

---

### AMD-2: Add Roster Request for Hash Mismatch Recovery

**Affected section:** Change Group 2, specification change step 3 (heartbeat roster fingerprint)

**Change:** Append to step 3 of Change Group 2:

> When a client detects a heartbeat roster hash mismatch, it sends a `roster_request` control message to the host (empty payload). The host responds with a `roster_snapshot` containing the current authoritative roster.
>
> Add `roster_request` to the control message types in §4.3.
>
> Rate limiting: a client must not send `roster_request` more than once per heartbeat interval.

**Trigger:** Internal re-examination prompted by external observation (`protocol-spec.review.md`, observation 2).

**Justification:** The merge defined hash-based mismatch detection but left the correction path incomplete. In a quiescent session with no membership changes, no `roster_snapshot` is naturally triggered. A client that detects staleness has no mechanism to obtain the correct roster. Without an explicit request path, the consistency check is detection-only — it identifies divergence but cannot resolve it until an unrelated membership event occurs, which may never happen.

---

### AMD-3: Include Peer Status in Roster Fingerprint

**Affected section:** Change Group 2, specification change step 3 (heartbeat roster fingerprint)

**Change:** Replace the fingerprint definition:

Before: "CRC32 of the sorted, concatenated peer IDs in the current roster."

After: "CRC32 of the sorted, concatenated `peerID:status` pairs in the current roster, where `status` is `c` (connected) or `r` (reconnecting). Example input for CRC32: `A1B2C3:c|D4E5F6:r|G7H8I9:c`."

**Trigger:** Internal re-examination prompted by external observation (`protocol-spec.review.md`, observation 3).

**Justification:** The merge defines `membership_epoch` as incrementing on status changes (grace begin, grace expire) and Group 4 uses connection status to determine successor eligibility. A fingerprint that covers only peer identity, not status, allows two peers to produce matching hashes while disagreeing on which members are reconnecting. That disagreement is material to successor selection during migration — the exact scenario the fingerprint is meant to protect.

---

### AMD-4: Retract Unsubstantiated Migration Data Recovery Claim

**Affected section:** Completion 8 (In-Flight Data During Migration), specification change bullet 3

**Change:** Replace:

> "Data lost during the migration window is recovered via heartbeat after the successor begins hosting. With Change Group 3 adopted, heartbeat replay semantics are well-defined."

With:

> "Data in flight during the migration window may be lost. Applications should treat migration as a potential data boundary. The protocol does not guarantee recovery of messages that were in write queues or partial assembly at the time `session_migrating` was sent."

Add to Part III (Deferred Items):

> | Migration replay state transfer | Deferred | The question of what broadcast replay state, if any, the successor inherits from the departing host is outside the scope of the current proposals. A future revision should define the bounded replay set that survives migration, if replay continuity is a requirement. |

**Trigger:** Internal re-examination prompted by external observation (`protocol-spec.review.md`, observation 4).

**Justification:** The merge claimed heartbeat would recover lost data after migration, but the successor — previously a client — has no guaranteed possession of the departing host's broadcast replay state. The claim relied on an unstated assumption about state transfer that neither proposal defined. Retaining an unsubstantiated recovery guarantee would mislead implementers into expecting continuity that the protocol does not provide.

---

### AMD-5: State Membership vs Routability Distinction Explicitly

**Affected section:** Completion 9 (Directed Message Routing), specification change

**Change:** Add the following preamble to the §4.4 "Message Routing" specification, before the routing rules:

> "Roster membership and directed routability are distinct. A peer's presence in the roster (via `roster_snapshot`) indicates session membership. Directed routability requires that the peer has active connection status (`connected`). Peers with status `reconnecting` are session members but are not valid directed message targets. This distinction applies to all routing rules below."

**Trigger:** Internal re-examination prompted by external observation (`protocol-spec.review.md`, observation 6).

**Justification:** Change Group 2 allows peers with status `reconnecting` in the authoritative roster. Completion 9 drops directed messages to peers in reconnect grace. Both are internally consistent, but the distinction between session membership (roster) and directed routability (active connection) is never stated. Without it, an implementer reading only the roster definition could reasonably conclude that all roster members are valid directed targets.

---

### AMD-6: Classify Fragment Spacing as Advisory

**Affected section:** Completion 6 (Fragment Validation and Retry Resolution), specification change step 3

**Change:** Append to step 3 of Completion 6:

> `Fragment Spacing` (15ms, §17) is retained as an implementation-advisory timing hint. It is a recommended default for pacing fragment writes on platforms where back-to-back BLE writes cause congestion. It carries no interoperability requirement — implementations may use different pacing strategies without violating the protocol. It is not subject to the same removal as retry constants because it does not create a behavioral contradiction; it merely lacks operational specificity, which is acceptable for an advisory value.

**Trigger:** Internal re-examination prompted by external observation (`protocol-spec.review.md`, observation 7).

**Justification:** The merge removed `Write Retry Timeout` and `Write Retry Max` because they created a behavioral contradiction with §15. `Fragment Spacing` was raised in the same context (B§6) but was not addressed. Its normative status was left undefined — it could be read as a required pacing rule (which would need send semantics) or as a hint (which would not). Classifying it explicitly as advisory resolves the ambiguity without removing a value that implementations may find useful.

---

### AMD-7: Apply Wraparound Analysis to Message ID

**Affected section:** Completion 11 (Minor Specification Fixes), M-3 nonce wraparound note

**Change:** Replace the M-3 entry:

Before: "Add informational note to §5.3: 'The 16-bit nonce wraps after 65,535 packets. At typical BLE throughput (well under 1,000 packets/second), collision with the dedup window (5 seconds, 64 entries) requires sustained rates exceeding 13,000 packets/second. This is not a practical concern.'"

After: "Add informational note to §5.3 regarding fragment nonce: 'The 16-bit fragment nonce wraps after 65,535 fragmentation events. Fragment nonce is scoped to transport reassembly only (per Change Group 3) and has no dedup implications.' Add a separate informational note to §10 regarding message ID: 'The 16-bit `message_id` wraps after 65,535 messages. At typical BLE throughput (well under 1,000 packets/second), collision with the dedup window (5 seconds, 64 entries) requires sustained rates exceeding 13,000 packets/second. This is not a practical concern. The same analysis that applied to fragment nonce in the baseline spec applies to `message_id` with identical safety margin.'"

**Trigger:** Internal re-examination prompted by external observation (`protocol-spec.review.md`, observation 8).

**Justification:** Change Group 3 moved dedup keying from fragment nonce to `message_id`. The wraparound note in M-3 still referenced fragment nonce as the dedup-relevant field — a statement that is no longer true under the amended protocol. The wraparound analysis is valid but must reference the field that dedup actually uses. Fragment nonce wraparound is now a transport-only concern with no dedup implications and should be noted separately.
