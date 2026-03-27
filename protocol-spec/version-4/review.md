# External Observer Review — Protocol Specification v4 Merge

**Reviewer role:** External third-party observer (non-participant, additive only)
**Document reviewed:** `merge.md` (consolidated referee output, 2026-03-27)
**Input documents:** `proposal-a.md`, `proposal-b.md`
**Date:** 2026-03-27

---

## Observation 1: HELLO `proto_version` — "present" vs. "treated as version 1" produces divergent implementations

**Pertains to:** Change 6, sections 6c and 6d
**Nature:** Specification drift

Change 6c defines the HELLO payload as `session_id|join_intent|proto_version` and states: "For backward compatibility, a missing third field is treated as version 1." Change 6d adds validation step 3f: "If proto_version **is present** and does not match the host's protocol version: send join_rejected."

These two statements interact ambiguously. There are two valid readings:

- **Reading A:** A missing field is semantically equivalent to `proto_version = 1`. Step 3f evaluates: `1 != 4`, reject. A v4 host rejects legacy clients.
- **Reading B:** "Is present" means explicitly present in the payload. A missing field is not present. Step 3f does not trigger. A v4 host accepts legacy clients.

The merge document's own tradeoffs section states: "a v4 host rejecting a v1 client on version mismatch is a behavior change from v3." This implies the intent is Reading A (reject). But step 3f's conditional language ("if proto_version is present") naturally reads as Reading B (skip).

**What would need to be true to dismiss:** The language in step 3f would need to be unambiguous about whether a missing field that defaults to version 1 counts as "present." Either: (a) step 3f should read "If the resolved proto_version does not match" (removing the "is present" gate), or (b) step 3f should explicitly say "A missing proto_version field is treated as version 1 for this comparison" to confirm Reading A, or (c) the spec should clarify that missing-field clients are intentionally accepted (confirming Reading B) and reconcile this with the tradeoffs note.

---

## Observation 2: Recovery Host Probe — "accept another successor" action is underspecified relative to "old host found" action

**Pertains to:** Change 1c, step 7a-iii (second bullet)
**Nature:** Specification drift

The Recovery Host Probe's scan handler defines two match cases. The first (old host found) specifies a concrete action sequence: "Clear migration state. Attempt `BeginClientReconnect()` to the old host. If reconnect begins, return true. If reconnect fails, proceed to step 8 (start hosting)." This is explicit, testable, and includes a fallback.

The second (another session member is advertising) says: "Accept this peer as successor (per Section 8.4 step 3 convergence rule). Return true." This references Section 8.4 step 3 for the action, but Section 8.4 step 3 is defined in the context of `OnScanResultDuringMigration` — a function that runs during an active migration scan, not during a recovery host probe. Step 3c of that function says "Connect to room with migrationJoin=true," but the probe scan handler doesn't have the same migration scan context. The connection action is implicit in the cross-reference but not stated in the probe's own logic.

Two independent implementors may handle this differently: one might immediately connect to the discovered successor; another might update the successor ID and enter the migration scan path to discover the successor again.

**What would need to be true to dismiss:** The second bullet would need to explicitly state the connection action and fallback, matching the specificity of the first bullet. Alternatively, the cross-reference to Section 8.4 step 3 would need to be clarified as "execute steps 3a-3c of `OnScanResultDuringMigration`" to make the connection action unambiguous.

---

## Observation 3: Join behavior for incompatible rooms is unspecified

**Pertains to:** Change 6, sections 6a/6b
**Nature:** Scope gap

Change 6b specifies that rooms with `protoVersion != CURRENT_PROTOCOL_VERSION` are reported to the application with `incompatible = true`. The `room_found` event gains a `proto_version` field. But the merge document does not specify what happens when the application subsequently calls `Join()` on a room flagged as incompatible.

Proposal A included guidance: "The application SHOULD NOT attempt to join incompatible rooms." The merge document dropped this language. The result is that the spec defines how to *detect* incompatibility but not how to *enforce* it at the join boundary.

Three implementation approaches are all consistent with the current text:
1. The native layer blocks `Join()` for incompatible rooms and emits an error.
2. The native layer allows the connection; the HELLO handshake rejects via step 3f.
3. The native layer allows the connection; the application is responsible for filtering.

All three produce correct eventual behavior (the client cannot join an incompatible host), but they produce different error surfaces, different BLE resource consumption, and different event sequences visible to the application.

**What would need to be true to dismiss:** Either (a) the merge document explicitly delegates join-filtering to the application layer (making options 2 and 3 both valid), or (b) a normative statement specifies whether the native layer MUST, SHOULD, or MAY block join attempts to incompatible rooms.

---

## Observation 4: Changes 3 and 4 simultaneously remove two independent safety nets from Section 13

**Pertains to:** Changes 3 and 4, both modifying Section 13
**Nature:** Silent assumption

Change 3 removes the device-identity guards (steps 3b/3c) from the `shouldEmit` derivation, replacing them with a callback-routing REQUIREMENT. Change 4 removes `connectionFailureHandled` from step 1, replacing it with a platform-concern REQUIREMENT. Both removals are individually sound and well-reasoned.

The silent assumption is that these are independent concerns. In the common case, they are. But on a platform that exhibits *both* dual delivery of connection failures *and* stale disconnect callbacks (e.g., a hypothetical platform where a connection attempt to device A fails, triggering both a connection failure event and a disconnect callback, while a stale disconnect from a prior device B also arrives), an implementor must satisfy both REQUIREMENT blocks simultaneously. Neither REQUIREMENT cross-references the other.

The v3 spec provided defense-in-depth: `connectionFailureHandled` guarded against dual delivery, and steps 3b/3c guarded against stale callbacks. An implementor inheriting v3 behavior got both protections. A v4 implementor on a new platform reading the two separate REQUIREMENT blocks might not recognize that both failure modes can co-occur on the same event sequence.

**What would need to be true to dismiss:** The REQUIREMENT blocks are each self-sufficient — satisfying each independently does handle the combined case. The concern reduces to discoverability: would an implementor reading one REQUIREMENT block be aware of the other? If Section 13 is the only place these appear and both are present, this is likely sufficient.

---

## Observation 5: Growing spec-implementation compliance gap remains unresolved

**Pertains to:** Rejected proposals (Proposal A Item 5, Proposal B Item 3)
**Nature:** Unresolved problem

The rejection of implementation compliance notes and a Section 18 compliance tracker is architecturally sound: a protocol specification should not track implementation status. The rejection reasoning is correct as stated.

However, the underlying problem both proposals were pointing at remains: multiple v3 normative mechanisms (`client_leaving` send/receive, `migrationAcceptanceActive` window, application lifecycle integration) have no implementation on either platform, and v4 adds further normative requirements (Recovery Host Probe on iOS, "first advertiser wins" on iOS, callback-routing requirement on both platforms). The gap between what the spec requires and what implementations do is growing, not shrinking.

The rejection states that "the issue backlog and GitHub issues" serve this tracking function. But neither the merge document nor the rejection defines a process by which the implementation compliance gap is inventoried, prioritized, or closed. The backlog tracks *specification* issues; there is no equivalent artifact that tracks *implementation* gaps against a given spec version.

This is not a request to reinstate the rejected proposals. The problem is real and the rejected solutions were wrong for the spec document. The problem's correct home may be a separate compliance matrix or implementation checklist — an artifact that the spec revision process could produce as a byproduct.

**What would need to be true to dismiss:** An existing artifact (outside the spec document) that inventories which v4 normative requirements each platform has not yet implemented, and a defined process for closing those gaps before or shortly after the spec is published.

---

## Observation 6: `AssertBleAvailable` emits `radio` events asymmetrically across states

**Pertains to:** Change 7a
**Nature:** Specification drift (minor)

`AssertBleAvailable()` emits a `radio` event for the `"off"` state (step 3a) and the `"unauthorized"` state (step 4a), but emits only an `error` event for `"unsupported"` (step 2) and `"resetting"` (step 5). Change 7c adds `"resetting"` to the `radio` event state set in Section 12, but `AssertBleAvailable()` itself does not emit a `radio` event when it encounters the resetting state.

This asymmetry exists in both proposals and was carried into the merge unchanged, so it may be intentional. The likely rationale is that `AssertBleAvailable()` is a point-in-time check and the `radio` event is also emitted by a separate state-change listener (existing Section 12 behavior). The function emits `radio` events for "off" and "unauthorized" as a convenience, not as the primary source.

However, the inconsistency may confuse implementors who read `AssertBleAvailable()` as the canonical radio-state handler. An implementor might omit the separate state-change listener, relying solely on `AssertBleAvailable()` for radio events, and thereby never emit `radio` events for "unsupported" or "resetting."

**What would need to be true to dismiss:** A note in or near `AssertBleAvailable()` clarifying that this function is not the sole emitter of `radio` events and that the platform's radio state-change listener (per existing Section 12) remains the primary source for ongoing radio state transitions. Alternatively, make the emission pattern uniform (emit `radio` events for all states or none).

---

## Observation 7: Mixed v3/v4 session tradeoff note contradicts version isolation from Change 6

**Pertains to:** Change 1 (Known tradeoffs, third bullet) and Change 6
**Nature:** Emergent conflict (minor)

Change 1's third tradeoff note states: "v3 clients in a mixed session will use the old ordering (recovery before reconnect). The probe mitigates this for self-elected successors regardless of ordering."

Change 6 makes v3 and v4 incompatible at the advertisement level: v4 rooms advertise `"LB4"` and v3 scanners check for `"LB1"`, so v3 clients cannot discover v4 rooms. The HELLO validation (step 3f) provides a secondary rejection. Together, these mechanisms should prevent mixed v3/v4 sessions from forming.

If Change 6 succeeds in its design intent, the mixed-session scenario described in Change 1's tradeoff note cannot occur. If mixed sessions *can* occur despite Change 6 (e.g., through a bug, manual override, or transition-window scenario not contemplated), then Change 6's isolation guarantee is weaker than stated.

This is likely a drafting artifact — the tradeoff note was authored in the context of the split-brain fix (where version isolation was not yet integrated) and was not updated after Change 6 was accepted into the same document.

**What would need to be true to dismiss:** Either (a) the tradeoff note is removed or updated to acknowledge that Change 6 prevents mixed sessions, or (b) a specific scenario is identified where mixed v3/v4 sessions can still form despite Change 6, and the tradeoff note is retained as applicable to that scenario.

---

## Observation 8: `OnReconnectTimeout` state cleanup — "reconnect scan state fields" is undefined

**Pertains to:** Change 1b, step 1b
**Nature:** Specification drift (minor)

Change 1b defines `OnReconnectTimeout()` step 1b as: "Clear reconnect scan state fields (but preserve session info and roster for recovery)." The parenthetical clarifies intent, but "reconnect scan state fields" is not a defined term. The v3 spec does not enumerate which fields constitute "reconnect scan state" vs. "session info and roster."

Two implementors may draw the boundary differently. For example: does `hostPeerId` (the reconnect target) count as a "reconnect scan state field" (cleared) or "session info" (preserved)? `BeginUnexpectedHostRecovery()` needs the old host's Peer ID (for the probe and for `SelectRecoverySuccessor()`), so clearing it would break the escalation. But nothing in step 1b's language prevents an implementor from clearing it.

**What would need to be true to dismiss:** Either (a) the fields preserved for recovery are enumerated (at minimum: `joinedSessionId`, `hostPeerId`, session peer roster), or (b) a cross-reference to `BeginUnexpectedHostRecovery()`'s preconditions clarifies which fields it requires.

---

## Summary

| # | Section | Nature | Severity |
|---|---------|--------|----------|
| 1 | Change 6 (6c/6d) — HELLO proto_version "present" ambiguity | Specification drift | High — will produce divergent implementations |
| 2 | Change 1c (step 7a-iii) — probe successor-acceptance action | Specification drift | Medium — underspecified relative to sibling case |
| 3 | Change 6 (6b) — join behavior for incompatible rooms | Scope gap | Medium — undefined enforcement boundary |
| 4 | Changes 3+4 — dual safety-net removal from Section 13 | Silent assumption | Low — independently sound, discoverability concern |
| 5 | Rejected Items 5/3 — compliance gap tracking | Unresolved problem | Medium — structural, not addressable in spec |
| 6 | Change 7a — radio event emission asymmetry | Specification drift | Low — likely intentional but undocumented |
| 7 | Change 1 tradeoff + Change 6 — mixed-session contradiction | Emergent conflict | Low — likely drafting artifact |
| 8 | Change 1b — "reconnect scan state fields" undefined | Specification drift | Low — intent is clear, boundary is not |
