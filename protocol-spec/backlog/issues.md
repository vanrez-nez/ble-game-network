# Protocol Specification — Master Issues Backlog

Living document maintained by the spec-issues agent. Contains all known
specification-level issues sourced from GitHub issues and codebase analysis.
Items here are unfiltered — the spec-curator agent selects which ones enter
a revision cycle.

---

## Issues

<!-- Entries are added and updated by the spec-issues agent. -->

### I-1. No client-to-host departure message

**Source:** GitHub issue #1 — Protocol gap: client explicit leave triggers reconnect grace instead of immediate cleanup
**Status:** new
**Severity:** critical
**Origin:** spec ambiguity
**Summary:** Section 6.6 (Leave) defines no outbound control message from client to host to signal an intentional departure. The `peer_left` control message in Section 4.3 is defined only as Host → Client. Because the host receives the same `STATE_DISCONNECTED` callback for both an explicit leave and an unexpected BLE drop, every client departure enters the 10-second reconnect grace window, delaying roster cleanup and wasting a client slot. The spec needs a Client → Host departure message (or equivalent mechanism) and must define the host-side handling that bypasses reconnect grace on receipt.
**Spec sections affected:** Section 4.3 (Control Message Types — direction column), Section 6.6 (Leave), Section 7.2 (Host Reconnect Grace), Section 14 (Host Client-Disconnect Decision Tree)

---

### I-2. ConnectToRoom has no GATT connection failure path

**Source:** GitHub issue #3 — Spec gap: ConnectToRoom has no GATT failure path; causes zombie client during reconnect
**Status:** new
**Severity:** major
**Origin:** spec ambiguity
**Summary:** Section 6.3 (ConnectToRoom) step 7 defines behavior "On GATT connected" but specifies no step for GATT connection failure (e.g., Android `status=62 GATT_CONN_FAIL_ESTABLISH`). When a connect attempt fails — particularly during reconnect — the client enters a zombie state with no retry or timeout. The spec needs a failure step that routes to `HandleJoinFailure` or equivalent cleanup. Both Android and iOS implementations independently hit this gap.
**Spec sections affected:** Section 6.3 (ConnectToRoom — missing failure step after step 7)

---

### I-3. `shouldEmit` parameter undefined in Client Disconnect Decision Tree

**Source:** GitHub issue #3 — Spec gap: ConnectToRoom has no GATT failure path; causes zombie client during reconnect
**Status:** new
**Severity:** major
**Origin:** spec ambiguity
**Summary:** Section 13 (Client Disconnect Decision Tree) uses `shouldEmit` as a parameter in the decision logic but never defines how it is derived. Both platforms independently computed it as `!clientLeaving && currentGattHandle == disconnectedHandle`, but this derivation has a subtle interaction with `StopClientOnly()` (called in ConnectToRoom step 2), which nulls the GATT reference and causes `shouldEmit=false` on subsequent disconnect callbacks. This makes reconnect failures hit the "silent cleanup" path (step 6) instead of routing through `HandleJoinFailure`. The spec must define `shouldEmit` semantics and add a guard for reconnect-in-progress states.
**Spec sections affected:** Section 13 (Client Disconnect Decision Tree — `shouldEmit` derivation), Section 6.3 (ConnectToRoom interaction with StopClientOnly)

---

### I-4. Spec silent on app lifecycle triggers for Leave()

**Source:** GitHub issue #4 — Resilient mode: missing app lifecycle handlers — host backgrounding doesn't trigger graceful migration
**Status:** new
**Severity:** major
**Origin:** spec ambiguity
**Summary:** Section 6.6 defines what happens when `Leave()` is called but provides no guidance on when the platform layer should auto-invoke it. When a Resilient-mode host goes to background (app switch, screen lock, phone call), the OS tears down the BLE connection without the protocol layer sending `session_migrating`. Clients fall into the worse unexpected-host-recovery path instead of graceful migration. The spec should define platform lifecycle events that constitute an implicit leave for Resilient hosts, making graceful migration the normative path for app backgrounding.
**Spec sections affected:** Section 6.6 (Leave — triggering conditions), Section 8.1 (Graceful Migration — when it should be invoked)

---

### I-5. Unexpected host recovery has no cross-client notification

**Source:** GitHub issue #5 — Resilient mode: unexpected host recovery doesn't notify other clients of new host
**Status:** new
**Severity:** major
**Origin:** spec ambiguity
**Summary:** Section 8.2 (BeginUnexpectedHostRecovery) defines successor election as a purely local operation. When a client becomes the new host, it starts advertising but sends no `session_migrating` notification to remaining clients. Each client independently runs successor election with potentially different roster state (different `membership_epoch`), risking divergent successor elections. The spec requires that the new host, after successfully starting its GATT server, broadcast `session_migrating` to all known session peers. The convergence fallback (Section 8.3) handles successor failure but does not address the notification gap.
**Spec sections affected:** Section 8.2 (BeginUnexpectedHostRecovery — missing notification step), Section 8.3 (Successor Selection — epoch consistency assumption), Section 8.4 (Migration Reconnect)

---

### I-6. "Assert permissions granted" is underspecified

**Source:** GitHub issue #7 — Spec: clarify BLE permission requirements in 'Assert permissions granted'
**Status:** new
**Severity:** minor
**Origin:** spec ambiguity
**Summary:** Sections 6.1, 6.2, and 6.3 all begin with "Assert BLE is available and permissions granted" without defining which permissions are required, whether checks are per-operation or upfront, how to handle denial or re-request, or platform-specific nuances (e.g., Android 12+ BLE-specific permissions vs. pre-12 location permissions, the `neverForLocation` flag, iOS `CBManagerAuthorization` states). This ambiguity caused crashes on Android 12+ where runtime permissions must be explicitly granted. The spec should enumerate platform-agnostic permission categories (scan, connect, advertise) and define the expected behavior on denial.
**Spec sections affected:** Section 6.1 step 1, Section 6.2 step 1, Section 6.3 step 1, Section 12 (Event Types — `radio` event with `"unauthorized"` state)

---

### I-7. Lua validation max_clients upper bound exceeds spec MaxClients range

**Source:** Codebase analysis — `lua/ble_net/config.lua` line 18
**Status:** new
**Severity:** minor
**Origin:** code divergence
**Summary:** The Lua config layer defines `max_clients = 8` as the upper validation bound (`config.lua:18`), while the spec Section 3.1 defines `MaxClients` as ASCII digit `'1'-'7'` and Section 6.1 step 5 clamps to `[1, 7]`. The native layer should enforce the spec range, so a value of 8 from Lua would be clamped, but the Lua validation layer permits a value the protocol cannot represent in the advertisement format. The validation layers should agree on range bounds.
**Spec sections affected:** Section 3.1 (Room Advertisement — MaxClients field), Section 6.1 step 5 (maxClients clamping)
