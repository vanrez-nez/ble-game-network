# Protocol Specification v4 — Post-Merge Amendments

**Parent document:** `merge.md` (consolidated referee output, 2026-03-27)
**Date:** 2026-03-27
**Purpose:** Ordered record of every post-merge amendment to the specification.

---

## Amendment 1

**Affected section:** Change 6, section 6d (HELLO validation step 3f)

**Change:** Replace step 3f:

Before:
```
3f. If proto_version is present and does not match the host's
    protocol version: send join_rejected("incompatible_version")
    to device, disconnect device, return.
```

After:
```
3f. Resolve the client's protocol version: if the proto_version
    field is present in the HELLO payload, use its value; if the
    field is absent, treat the client's protocol version as 1
    (per Section 6c backward-compatibility rule).
3g. If the resolved protocol version does not match the host's
    protocol version: send join_rejected("incompatible_version")
    to device, disconnect device, return.
```

Update the Summary of Specification Section Changes table entry for Section 6.5 to reference steps 3f–3g.

**Trigger:** External observation (review.md, Observation 1) identifying ambiguous interaction between Change 6c's default-to-version-1 rule and Change 6d's "is present" conditional gate.

**Justification:** Change 6c defines that a missing `proto_version` field is treated as version 1. Change 6d's step 3f conditions on "proto_version is present," which creates two valid readings: (A) the defaulted value counts as present and is compared, or (B) a missing field is not present and the check is skipped entirely. These readings produce opposite behavior — a v4 host either rejects or accepts legacy clients. The merge document's own tradeoff note ("a v4 host rejecting a v1 client on version mismatch is a behavior change from v3") confirms the intent is Reading A. Splitting into an explicit resolution step (3f) and an unconditional comparison step (3g) eliminates the ambiguity and aligns the normative text with the stated intent.

---

## Amendment 2

**Affected section:** Change 1c, step 7a-iii (second scan-result bullet: another session member advertising)

**Change:** Expand the second bullet's action sequence to match the specificity of the first bullet.

Before:
```
- If room.sessionId matches current session AND
  room.hostPeerId matches a different known session member:
    -> Another peer has already become successor.
    -> Set recoveryHostProbeActive = false.
    -> Accept this peer as successor
       (per Section 8.4 step 3 convergence rule).
    -> Return true.
```

After:
```
- If room.sessionId matches current session AND
  room.hostPeerId matches a different known session member:
    -> Another peer has already become successor.
    -> Set recoveryHostProbeActive = false.
    -> Cancel probe timer. Stop scan.
    -> Clear migration state.
    -> Update migration info with this peer as new successor.
    -> Connect to this peer's room with migrationJoin=true.
    -> If connection begins, return true.
    -> If connection fails, proceed to step 8 (start hosting).
```

**Trigger:** External observation (review.md, Observation 2) identifying that the second bullet's action is underspecified relative to the first bullet, with the connection action implicit in a cross-reference rather than stated directly.

**Justification:** The first bullet (old host found) specifies five discrete actions including a fallback path. The second bullet defers to "Section 8.4 step 3 convergence rule," but that function runs in a different context (active migration scan, not a recovery host probe). The connection action and fallback are not stated in the probe's own logic. Two implementors could differ: one immediately connects, another re-enters the migration scan path. Inlining the action sequence eliminates this ambiguity and provides a fallback (proceed to step 8) consistent with the first bullet's pattern.

---

## Amendment 3

**Affected section:** Change 1, Known tradeoffs (third bullet)

**Change:** Remove the third tradeoff bullet.

Before:
```
- v3 clients in a mixed session will use the old ordering (recovery before reconnect). The probe mitigates this for self-elected successors regardless of ordering.
```

After: Bullet removed. The Known tradeoffs section retains the first two bullets only.

**Trigger:** External observation (review.md, Observation 7) identifying an emergent conflict between this tradeoff note and Change 6 within the same document.

**Justification:** Change 6 within the same revision makes v3 and v4 incompatible at the advertisement level: v4 rooms advertise `"LB4"` and v3 scanners check for `"LB1"`. The HELLO validation (step 3f/3g, as amended) provides secondary rejection. Mixed v3/v4 sessions cannot form under the protocol as specified by this revision. The tradeoff note describes a scenario that the same document prevents. Retaining it implies a version isolation gap that does not exist, which is misleading.

---

## Amendment 4

**Affected section:** Change 1b, step 1b of `OnReconnectTimeout()`

**Change:** Enumerate the minimum fields that must be preserved for recovery escalation.

Before:
```
1b. Clear reconnect scan state fields (but preserve session info
    and roster for recovery).
```

After:
```
1b. Clear reconnect scan state fields. The following fields MUST
    be preserved, as they are preconditions for
    BeginUnexpectedHostRecovery(): joinedSessionId, hostPeerId
    (the old host's Peer ID, needed for the Recovery Host Probe
    and SelectRecoverySuccessor()), and the Session Peer roster.
```

**Trigger:** External observation (review.md, Observation 8) identifying that "reconnect scan state fields" is not a defined term and the preservation boundary is ambiguous.

**Justification:** `BeginUnexpectedHostRecovery()` requires the old host's Peer ID for the Recovery Host Probe (step 7a-iii, matching against `room.hostPeerId`) and for `SelectRecoverySuccessor()`. It requires the session peer roster for successor election and for the convergence rule. It requires `joinedSessionId` for session identity. An implementor who interprets `hostPeerId` as a "reconnect scan state field" and clears it would break the escalation from reconnect timeout to recovery — the probe would have no host identity to scan for. Enumerating the preserved fields makes the boundary explicit and prevents this failure.

---

## Deferred Item D-1

**Pertains to:** Change 6, sections 6a/6b — join behavior for rooms flagged as `incompatible = true`

**Nature:** The specification defines how to detect protocol version incompatibility at the advertisement level but does not specify whether the native layer MUST block `Join()` for incompatible rooms, or whether enforcement is delegated to the HELLO handshake (step 3f/3g) and/or the application layer. Correctness is covered by the HELLO validation regardless of approach, but the error surface and BLE resource consumption differ across implementations.

**Reason for deferral:** Neither proposal covered join-boundary enforcement for incompatible rooms. The correctness path (HELLO rejection) is fully specified. Whether to additionally block at the native layer is an optimization and UX consistency decision that belongs to a future revision cycle where the version negotiation feature has implementation experience.

**Trigger:** External observation (review.md, Observation 3).
