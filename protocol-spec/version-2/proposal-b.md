# Protocol Spec Proposal B

Status: Draft
Source: Review of [protocol-spec.md](/Users/vanrez/Documents/game-dev/ble-game-network/docs/protocol-spec.md)

## Scope

This document records gaps found in the current protocol draft and proposes changes for each gap. It does not modify the protocol directly. Each proposal includes the other workflows and use cases that would also need to change if the proposal is adopted.

## 1. Join Handshake Is Not Authoritative

### Gap

The current flow lets `CompleteLocalJoin()` mark the client as joined or resumed before `HELLO` is sent, while the host only admits the peer after `OnHelloReceived()`.

That leaves an undefined state:

- The client can emit `joined`, `peer_status=connected`, or `session_resumed` before the host has accepted it.
- The client can send app messages before host admission is complete.
- The spec does not define what happens if the host rejects admission after BLE connection succeeds.

### Proposal

Add explicit host admission outcomes:

- `hello_ack`
- `join_rejected`

Define `join_rejected` reasons at minimum:

- `room_full`
- `duplicate_peer_id`
- `stale_session`
- `wrong_target`
- `migration_mismatch`

Change the lifecycle so:

1. Client connects and enables notifications.
2. Client sends `hello`.
3. Host validates and either sends `hello_ack` or `join_rejected`.
4. Client emits `joined`, reconnect completion, or migration completion only after `hello_ack`.

### Other Affected Use Cases And Workflows

- First join flow
- Reconnect resume flow
- Migration resume flow
- Immediate post-join sends
- Join failure reporting and UX
- Duplicate join suppression
- Session admission metrics and diagnostics

## 2. Roster Transfer Is Implicit And Non-Authoritative

### Gap

Several sections say "Send Roster", but the wire protocol does not define a roster snapshot message, a membership epoch, or ordering guarantees for roster changes.

This is especially risky because:

- New peers reconstruct state from repeated `peer_joined` controls.
- Reconnected peers also receive an unspecified roster replay.
- Unexpected host recovery selects a successor from each peer's local roster view.

Different peers can therefore make different successor decisions if they missed or reordered membership events.

### Proposal

Add an explicit `roster_snapshot` control message with:

- `session_id`
- `host_peer_id`
- `membership_epoch`
- Full peer list
- Optional peer states such as `connected` or `reconnecting`

Rules:

- Host sends `roster_snapshot` after `hello_ack` for fresh joins.
- Host sends `roster_snapshot` after reconnect acceptance.
- Host includes roster epoch in migration-related control messages.
- Successor election during recovery must use the last committed roster epoch, not ad hoc local memory.

### Other Affected Use Cases And Workflows

- New-client roster bootstrap
- Reconnect-after-grace resume
- `session_resumed` event semantics
- Peer list UI and local cache rebuild
- Split-brain prevention during recovery
- Interop tests for out-of-order control delivery

## 3. Heartbeat And Dedup Semantics Conflict

### Gap

Heartbeat re-broadcasts the last broadcast packet, but dedup is keyed by `(fromPeerID, msgType, nonce)`.

That leaves two bad outcomes:

- If heartbeat creates a fresh fragment nonce, the client sees every heartbeat as a new message.
- If heartbeat reuses the old nonce, nonce lifetime and collision rules are unspecified.

The current draft also does not define whether heartbeat applies to all broadcast messages or only state snapshots.

### Proposal

Add a packet-level message identifier independent of fragment nonce.

Rules:

- Fragment nonce remains a transport reassembly key only.
- Dedup uses packet message ID, not fragment nonce.
- Heartbeat must resend the same message ID when replaying the same packet.
- Heartbeat should be restricted to replay-safe broadcast message classes, ideally explicit state snapshots.

If the protocol wants generic broadcast replay, it should also define replay expectations for the application layer.

### Other Affected Use Cases And Workflows

- Broadcast state synchronization
- Chat-style broadcast delivery
- Host heartbeat implementation
- Dedup cache behavior
- Replay behavior after reconnect
- Replay behavior after migration

## 4. Migration Does Not Define How Reconnect-Grace Peers Are Handled

### Gap

Graceful migration selects a successor from connected clients, but reconnect-grace peers remain in the session roster and are treated as still in-session elsewhere in the draft.

The spec does not define whether those peers:

- Remain members of the migrated session
- Are excluded from the new session
- Can reconnect to the successor using the old grace window
- Consume capacity during migration

This creates ambiguity in successor selection, slot accounting, and reconnect outcomes.

### Proposal

Pick one explicit model and apply it consistently.

Option A:
Reconnect-grace peers are excluded from migrated sessions.

Option B:
Reconnect-grace peers are preserved across migration and can resume against the successor within the remaining grace window.

If Option B is chosen, the protocol also needs:

- Grace metadata transferred in migration state
- Roster snapshot support with peer status
- Successor rules for honoring inherited grace timers
- Capacity rules for reserved slots during inherited grace

### Other Affected Use Cases And Workflows

- Host leave during transient client disconnects
- Reconnect racing with host migration
- Successor eligibility rules
- Full-room handling during migration
- Peer status UI during handoff
- Failure reasons when inherited grace expires

## 5. Advertised Capacity Semantics Are Underspecified

### Gap

The room advertisement includes `MaxClients` and `PeerCount`, but the draft never states whether `PeerCount` includes the host.

That ambiguity leaks into:

- Lobby occupancy display
- Full-room decisions
- Slot accounting during reconnect grace
- Migration capacity carry-over

The draft also does not define host behavior when a room fills after discovery but before `HELLO`.

### Proposal

Make advertisement semantics explicit.

Recommended model:

- `max_clients` means non-host clients only.
- `client_count` means admitted non-host clients only.
- Host is not counted in advertised capacity.
- Peers in reconnect grace do not increase `client_count`, but they may reserve slots if the protocol chooses slot reservation.

Also add explicit host-side admission behavior for "room filled between scan and join" using `join_rejected(room_full)`.

### Other Affected Use Cases And Workflows

- Lobby sorting and display
- "Room full" UX
- Admission control
- Reconnect slot reservation
- Migration room re-advertisement
- Demo app occupancy strings and diagnostics

## 6. Retry, Pacing, And Malformed Fragment Handling Are Incomplete

### Gap

The timeout table defines:

- `Fragment Spacing`
- `Write Retry Timeout`
- `Write Retry Max`

But the send algorithms do not specify how those values are applied.

There are also missing validation rules for malformed fragments, such as:

- `count == 0`
- `index >= count`
- Header shorter than 5 bytes
- Excessive concurrent assemblies

Section 15 currently says a failed write clears the queue immediately, which conflicts with the existence of retry constants.

### Proposal

Choose one of these approaches for v1:

Option A:
Remove retry and pacing constants from the spec and keep the transport simple.

Option B:
Specify exact retry and pacing semantics, including:

- When fragment spacing applies
- Which write failures are retryable
- Retry timer behavior
- Retry exhaustion behavior
- Queue handling while a retry is pending

Independently of retries, add mandatory malformed-fragment rejection rules.

### Other Affected Use Cases And Workflows

- Platform parity between Android and iOS
- Backpressure handling under BLE instability
- Interoperability testing
- Fuzz and malformed-input testing
- Error codes and diagnostics
- Large-payload reliability expectations

## Recommended Adoption Order

If changes are adopted, the highest-value order is:

1. Authoritative join handshake
2. Authoritative roster snapshot and epoch
3. Heartbeat and dedup separation
4. Migration handling for reconnect-grace peers
5. Capacity semantics
6. Retry and malformed-fragment rules

## Notes

- This proposal intentionally avoids editing the existing spec text.
- Some native implementation details in the repo already imply stronger validation rules than the spec currently documents.
- If Proposal B is accepted, a follow-up change should map each adopted proposal to exact packet definitions, event changes, and migration/reconnect state transitions before updating the main spec.
