# Protocol Spec Gap Analysis — Proposal A

**Date:** 2026-03-25 | **Spec Version:** 1.0 (Draft)
**Source:** `docs/protocol-spec.md`

---

## Context

Review of the BLE Game Network protocol specification against the native implementation (C++/ObjC in `love/src/modules/ble/`) and Lua layer (`lua/ble_net/`). The goal is to identify logic gaps, missing scenarios, ambiguities, and spec/implementation mismatches — with proposals that account for ripple effects across affected workflows.

---

## CRITICAL — Logic gaps that cause incorrect behavior

### C-1. Successor Selection Inconsistency (Graceful vs Recovery Migration)

**Gap:** `SelectSuccessor()` (§8.3 line 401) uses "connected client Peer IDs" — excludes peers in reconnect grace. `SelectRecoverySuccessor()` (§8.3 line 407) uses "Session Peer IDs" — includes peers in grace because `BeginPeerReconnectGrace()` (§7.2) keeps them in the roster. A disconnected peer can be elected successor during unexpected host loss but not during graceful departure. Worse: during unexpected host loss, all clients run `SelectRecoverySuccessor()` independently — if any client has a stale roster (see C-3), clients elect different successors, causing a **network split**.

**Sections affected:** §7.2, §8.1, §8.2, §8.3, §14

**Proposal:**
1. Amend `SelectRecoverySuccessor()` to exclude peers in reconnect grace, matching `SelectSuccessor()`
2. Add convergence fallback: if elected successor doesn't advertise within Migration Timeout (3s), remaining clients re-run selection with that successor excluded
3. §7.2 should track grace peers in a separate set queryable by both successor functions

---

### C-2. No MaxClients Enforcement / Room Full Rejection

**Gap:** §3.1 defines MaxClients as `'1'`–`'7'`, §6.1 clamps to [1,7]. But the spec never describes what happens when a client joins a full session. No "room_full" error. `OnHelloReceived()` (§6.5) unconditionally binds new peers. Meanwhile `config.lua:18` uses `max_clients = 8` and `validation.lua:74` validates [1,8] — contradicting the spec.

**Sections affected:** §3.1, §6.1, §6.5, §12

**Proposal:**
1. Add guard to `OnHelloReceived()` §6.5: if connected clients >= maxClients, disconnect the device, return
2. Define error code `"room_full"` in §12
3. Reconcile range: spec says [1,7] clients (+ host = 2–8 total peers) — fix `config.lua` to match, or expand spec to [1,8]
4. §3.1 should clarify MaxClients counts clients only, not host

---

### C-3. Control Packet Loss → Stale Roster → Wrong Successor

**Gap:** Control packets (`peer_joined`, `peer_left`) are BLE notifications with **no ACK mechanism** (§4.2). If a `peer_left` is lost, a client retains a stale roster. During unexpected host recovery (§8.2), that client elects a different successor than clients with accurate rosters, causing a **split**.

**Sections affected:** §4.2, §6.5, §7.2, §8.2, §9, §12

**Proposal (recommend Option B):**
- **Option A — ACK:** Host expects `peer_ack` control from each client after roster changes. Retransmit if not received within one heartbeat. Reliable but complex.
- **Option B — Heartbeat roster hash:** Extend heartbeat (§9) to include a 4-byte roster fingerprint (sorted peer IDs hash). Client compares to local roster; on mismatch, requests `roster_sync` from host. Self-healing, simple, fits BLE's eventual-consistency model.
- New control types needed: `roster_sync` (§4.3), optionally `roster_request`

---

### C-4. No Pending Client Timeout

**Gap:** §6.5 references "pending clients" but never defines creation, lifetime, or cleanup. A GATT-connected device that never sends HELLO occupies resources indefinitely. On Android, any BLE device can connect to the open GATT server.

**Sections affected:** §6.1, §6.5, §14, §17

**Proposal:**
1. Define: "pending client = GATT-connected device that hasn't completed HELLO"
2. Add "Pending Client Timeout" to §17: default 5 seconds
3. On each heartbeat tick, disconnect pending clients older than timeout
4. Add to §6.1 step 9: begin tracking pending clients

---

## HIGH — Gaps affecting reliability

### H-1. In-Flight Data During Migration

**Gap:** §8.1 sends `session_migrating`, waits 400ms, leaves. No mention of: flushing write queues (§15), clearing partial assemblies (§5.4), handling messages during the 400ms window.

**Sections affected:** §5.4, §8.1, §15.1, §15.2

**Proposal:**
1. After sending `session_migrating`, Host stops accepting new data writes; continues pumping existing notification queues
2. On receiving `session_migrating`, Client discards write queue and clears in-progress assemblies
3. Data lost during migration window recovered via heartbeat after successor begins hosting

---

### H-2. Fragment Assembly Memory Exhaustion

**Gap:** §5.4 creates assemblies keyed by sourceKey+nonce with 15s timeout (§5.5), but no limit on concurrent assemblies per source. A misbehaving peer could create thousands of assembly slots.

**Sections affected:** §5.4, §5.5, §17

**Proposal:** Add "Max Concurrent Assemblies Per Source" constant to §17 (default 32). In §5.4 step 6, if limit exceeded, discard oldest assembly before creating new one.

---

### H-3. Roster Sync Format Undefined

**Gap:** §6.5 says "Send Roster to the new Client (one `peer_joined` control per existing Peer)." §7.2 says "Send Roster to reconnected Client." Neither defines exact format. Reconnect sync only sends `peer_joined` — if a peer left during disconnection, client never learns.

**Sections affected:** §4.3, §6.5, §7.2

**Proposal:**
1. Define `roster_sync` control message in §4.3 — payload: pipe-delimited list of current peer IDs
2. §6.5 step 7a: send `roster_sync` instead of individual `peer_joined` controls
3. §7.2 step 4: send `roster_sync`; client replaces local roster entirely
4. Couples with C-3 fix: `roster_sync` becomes the authoritative roster delivery mechanism

---

### H-4. Heartbeat Only Stores Last Broadcast

**Gap:** §9 stores and re-broadcasts "the stored broadcast Packet" — singular. Apps using multiple broadcast message types only get heartbeat protection for the most recent one.

**Sections affected:** §9, §12

**Proposal (recommend Option A):**
- **Option A:** Store last broadcast per message type (map of msgType → packet). Heartbeat iterates all entries. Bounded by number of distinct message types.
- **Option B:** Document as deliberate limitation; recommend apps consolidate into single message type.

---

## MEDIUM — Ambiguities and inconsistencies

### M-1. Directed Message Relay Not Specified

**Gap:** §4.1 defines `ToPeerID` but never describes host relay rules.

**Proposal:** Add §4.4 "Message Routing":
- Empty `ToPeerID` → broadcast to all connected clients except sender
- Matching connected client → forward only to that client
- Peer in grace or unknown → drop silently
- Host delivers to self if `ToPeerID` is empty or matches host's own peer ID

**Sections affected:** §4.1

---

### M-2. Empty Table Codec Ambiguity

**Gap:** §11.3 doesn't cover `{}`. `Codec.cpp:195` encodes as empty array.

**Proposal:** Add rule 5 to §11.3: "Empty table → Array with count 0 (tag `0x05`, 4-byte LE `0x00000000`)."

**Sections affected:** §11.3

---

### M-3. Nonce Wraparound vs Dedup

**Gap:** 16-bit nonce wraps after 65,535 packets; dedup window is 5s/64 entries. Collision requires ~13,000 packets/sec — two orders of magnitude above BLE throughput.

**Proposal:** Add informational note to §10 confirming this is not a practical concern.

**Sections affected:** §5.3, §10

---

### M-4. PeerCount: Does It Include the Host?

**Gap:** §3.1 doesn't say whether PeerCount includes the host.

**Proposal:** Clarify PeerCount includes host. Solo host = `'1'`. Matches glossary definition of "Peer" (any participant).

**Sections affected:** §3.1, §6.5

---

### M-5. `session_resumed` Never Explicitly Emitted

**Gap:** §12 lists `session_resumed` but no procedure emits it. `CompleteMigrationResume()` (§6.4 step 4) is called but never defined.

**Proposal:** Define `CompleteMigrationResume()` in §8.5:
```
CompleteMigrationResume()
1. Cancel Migration Timeout.
2. Clear migration state fields.
3. Emit `session_resumed` event with current session_id,
   the new host's peer ID, and the current peer roster.
```

**Sections affected:** §6.4, §8.4, §12

---

### M-6. Transport Naming Mismatch

**Gap:** Spec uses "Reliable"/"Resilient". Lua layer uses `TRANSPORT.NORMAL` as alias for RELIABLE, `transport_name()` returns `"Normal"`. "Normal" appears nowhere in the spec.

**Proposal:** Rename to `RELIABLE` in Lua layer to match spec, or add "Normal" as acknowledged alias in §1 glossary.

**Sections affected:** §1, §3.1 | `init.lua:10`, `init.lua:153`

---

## LOW — Documentation gaps

### L-1. `shouldEmit=false` Branch Undocumented

§13 decision tree: all branches check `shouldEmit`, but `!shouldEmit` case falls through without return.

**Proposal:** Add step 6: "If none of the above returned: silent cleanup, no events."

---

### L-2. Write Failure Error Details

§15.1 step 6c says "clear queue and emit error" — no error code or detail specified.

**Proposal:** Define error code `"write_failed"` with detail containing platform-specific BLE error string.

---

### L-3. Room Name Max Length Discrepancy

Spec §3.2 truncates to 8 chars (BLE advertisement). `config.lua:15` allows 24, `validation.lua:43` validates against that. Different purposes (BLE encoding vs app-level) but spec doesn't explain.

**Proposal:** Add note to §3.2: "NormalizeRoomName() applies to BLE advertisement encoding only. Applications may accept longer names locally; the advertised name is a truncated representation."

---

## Summary Matrix

| ID  | Severity | Title | Spec Sections | Implementation Files |
|-----|----------|-------|---------------|---------------------|
| C-1 | CRITICAL | Successor selection inconsistency | §7.2, §8.1–§8.3, §14 | Native BLE impl |
| C-2 | CRITICAL | No MaxClients enforcement | §3.1, §6.1, §6.5, §12 | `config.lua:18`, `validation.lua:74` |
| C-3 | CRITICAL | Control packet loss → stale roster | §4.2, §6.5, §7.2, §8.2, §9 | Native BLE impl |
| C-4 | CRITICAL | No pending client timeout | §6.1, §6.5, §14, §17 | Native BLE impl |
| H-1 | HIGH | In-flight data during migration | §5.4, §8.1, §15.1, §15.2 | Native BLE impl |
| H-2 | HIGH | Fragment assembly memory exhaustion | §5.4, §5.5, §17 | Native BLE impl |
| H-3 | HIGH | Roster sync format undefined | §4.3, §6.5, §7.2 | Native BLE impl |
| H-4 | HIGH | Heartbeat stores only last broadcast | §9, §12 | Native BLE impl |
| M-1 | MEDIUM | Directed message relay unspecified | §4.1 | Native BLE impl |
| M-2 | MEDIUM | Empty table codec ambiguity | §11.3 | `Codec.cpp:195` |
| M-3 | MEDIUM | Nonce wraparound vs dedup | §5.3, §10 | — (informational) |
| M-4 | MEDIUM | PeerCount host inclusion unclear | §3.1, §6.5 | `init.lua:167` |
| M-5 | MEDIUM | `session_resumed` never emitted | §6.4, §8.4, §12 | `init.lua:437` |
| M-6 | MEDIUM | Transport naming mismatch | §1, §3.1 | `init.lua:10,153` |
| L-1 | LOW | `shouldEmit=false` undocumented | §13 | — |
| L-2 | LOW | Write failure error details | §12, §15.1 | — |
| L-3 | LOW | Room name length discrepancy | §3.2 | `config.lua:15`, `validation.lua:43` |

---

## Recommended Resolution Order

| Priority | Issues | Rationale |
|----------|--------|-----------|
| 1st | C-1 + C-3 + H-3 | Deeply coupled: roster consistency drives successor selection. Solve together via `roster_sync` + amended `SelectRecoverySuccessor()` + heartbeat roster hash |
| 2nd | C-2 + C-4 | Both are missing guards on host connection acceptance. Solve together |
| 3rd | H-1 | Migration data handling, independent |
| 4th | H-2 | Assembly limits, independent |
| 5th | H-4 | Heartbeat storage model, independent |
| 6th | M-1 → M-6 | Single spec editing pass |
| 7th | L-1 → L-3 | Documentation cleanup pass |
