# Protocol Spec Merge Review Addendum

Status: Additive review only
Role: External third-party observer
Inputs reviewed:

- [protocol-spec.merge.md](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md)
- [protocol-spec.proposal-a.md](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.proposal-a.md)
- [protocol-spec.proposal-b.md](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.proposal-b.md)

## Scope

This document does not challenge accepted or rejected decisions in the merge. It records only missed assumptions, emergent interactions, scope gaps, unresolved underlying problems, and wording drift that could still produce divergent implementations.

## Observations

### 1. HELLO now appears to require information the merge never defines

- Pertains to:
  [protocol-spec.merge.md:39](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L39),
  [protocol-spec.merge.md:43](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L43),
  [protocol-spec.merge.md:50](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L50)
- Nature of concern: `gap` and `drift`
- Observation:
  Change Group 1 adds rejection reasons `stale_session`, `wrong_target`, and `migration_mismatch`, but the merge text does not say what additional data the client includes in `hello` to make those decisions possible. In the baseline spec, `hello` carries an empty payload. `wrong_target` can plausibly rely on `ToPeerID`, but `stale_session` and `migration_mismatch` appear to require explicit client-declared session or resume intent that is not yet defined in the merged output.
- Safely dismissed if:
  the merged spec later makes it explicit that either:
  `hello` is extended with the fields needed to validate session and migration intent, or those rejection reasons are derivable from already-defined packet fields and connection context alone.

### 2. Roster hash mismatch detection has no defined correction path in a quiet session

- Pertains to:
  [protocol-spec.merge.md:78](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L78),
  [protocol-spec.merge.md:84](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L84),
  [protocol-spec.merge.md:90](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L90),
  Proposal A C-3 at [protocol-spec.proposal-a.md:49](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.proposal-a.md#L49)
- Nature of concern: `unresolved problem`
- Observation:
  The merge accepts epoch snapshots plus heartbeat hash validation, but the text says a mismatch is corrected by "the next `roster_snapshot` (triggered by the host detecting the divergence or by the next membership change)." The merge never defines how the host detects client-local divergence, and it explicitly rejects the ACK-based path that Proposal A presented as the stronger coordination option. In a quiescent session with no membership changes, a client can know its roster is stale without any defined way to obtain a repair.
- Safely dismissed if:
  the merged spec later states that mismatch is only advisory until the next membership change, or it defines a concrete recovery trigger already considered in scope by the merge, such as a client-initiated re-sync request.

### 3. The roster fingerprint does not appear to cover the same state that membership epoch orders

- Pertains to:
  [protocol-spec.merge.md:81](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L81),
  [protocol-spec.merge.md:82](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L82),
  [protocol-spec.merge.md:90](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L90),
  [protocol-spec.merge.md:136](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L136)
- Nature of concern: `conflict`
- Observation:
  Change Group 2 says `membership_epoch` increments on every membership change, including grace begin and grace expire, and `roster_snapshot` carries per-peer status (`connected` or `reconnecting`). The heartbeat fingerprint, however, is defined only as CRC32 of sorted concatenated peer IDs. That means two peers can agree on the fingerprint while disagreeing on which members are reconnecting. That difference matters because Group 4 excludes grace peers from migrated sessions and successor selection depends on connectedness, not just identity.
- Safely dismissed if:
  the merged spec later makes clear that either peer status is included in the fingerprint input, or status divergence is intentionally not part of the consistency model used for migration and recovery.

### 4. Migration recovery via heartbeat assumes replayable state survives the handoff

- Pertains to:
  [protocol-spec.merge.md:116](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L116),
  [protocol-spec.merge.md:217](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L217),
  [protocol-spec.merge.md:227](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L227),
  Rejected A-H4 at [protocol-spec.merge.md:314](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L314)
- Nature of concern: `assumption`
- Observation:
  Completion 8 says data lost during the migration window is recovered via heartbeat after the successor begins hosting. Group 3 makes replay semantics coherent, but it does not say what replayable broadcast state the successor is guaranteed to possess after graceful migration or unexpected recovery. The rejection of Proposal A's per-type storage model is sound as a rejection of that specific solution, but the underlying question of what replay set survives the handoff remains implicit.
- Safely dismissed if:
  the merged spec later states that heartbeat recovery applies only to replayable state already held by the successor, or it explicitly defines the bounded replay set that the successor must carry forward.

### 5. Convergence fallback assumes sufficiently uniform discovery across remaining clients

- Pertains to:
  [protocol-spec.merge.md:138](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L138),
  [protocol-spec.merge.md:140](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L140),
  Proposal A C-1 at [protocol-spec.proposal-a.md:22](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.proposal-a.md#L22)
- Nature of concern: `assumption`
- Observation:
  Group 4 accepts the fallback where clients exclude a non-advertising successor and re-run election. That is internally coherent, but it rests on an unstated premise: the remaining clients will make sufficiently similar observations about whether a candidate "did not begin advertising." BLE discovery is local and lossy. One client may fail to discover a successor that another client can already see, which can still split the exclusion set even when epoch ordering is correct.
- Safely dismissed if:
  the merged spec later narrows the claim to eventual convergence under ordinary scan conditions, or it defines "did not begin advertising" in a way that is deterministic from protocol state rather than from each client's local discovery result alone.

### 6. Membership and reachability semantics are now separate, but that separation is only implicit

- Pertains to:
  [protocol-spec.merge.md:82](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L82),
  [protocol-spec.merge.md:166](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L166),
  [protocol-spec.merge.md:245](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L245)
- Nature of concern: `drift`
- Observation:
  The merged output now clearly allows peers to remain in the authoritative roster with status `reconnecting`, while directed routing drops messages to peers in reconnect grace or unknown peers. That may be the intended model, but it means "peer is in the session" and "peer is a valid directed target right now" are no longer equivalent. The merge never states that distinction directly, even though several application-facing sections will now rely on it.
- Safely dismissed if:
  the merged spec later states that roster membership expresses session identity, while directed routability is limited to currently connected peers.

### 7. Retry cleanup was resolved, but fragment pacing still appears normatively loose

- Pertains to:
  [protocol-spec.merge.md:183](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L183),
  [protocol-spec.merge.md:197](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L197),
  Proposal B §6 at [protocol-spec.proposal-b.md:207](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.proposal-b.md#L207)
- Nature of concern: `gap`
- Observation:
  Completion 6 removes `Write Retry Timeout` and `Write Retry Max`, which closes the main contradiction Proposal B identified. But Proposal B also raised `Fragment Spacing` as a normative timing value whose operational semantics were never defined. The merge does not say whether that constant remains normative, becomes advisory, or should be removed alongside retry-related timing.
- Safely dismissed if:
  the merged spec later classifies `Fragment Spacing` explicitly as either an implementation hint with no interoperability significance or a required pacing rule with concrete send semantics.

### 8. Message ID was introduced without an accompanying reuse or wraparound statement

- Pertains to:
  [protocol-spec.merge.md:110](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L110),
  [protocol-spec.merge.md:114](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L114),
  [protocol-spec.merge.md:289](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.merge.md#L289)
- Nature of concern: `scope gap`
- Observation:
  Group 3 adds a 16-bit `message_id` and moves dedup to that field, but the only wraparound note retained in the merge is still about fragment nonce. This is not an objection to the new field; it is a note that the accepted change implicitly created a new reuse window question analogous to the one the old nonce note discussed.
- Safely dismissed if:
  the merged spec later states that `message_id` reuse is safe under the same dedup-window assumptions, or it otherwise defines sender behavior for wraparound and reuse.

## Closing Note

None of the observations above imply that the merge decisions were unsound. They identify places where the merged document appears to rely on unstated premises or leaves enough room for two compliant implementations to behave differently.
