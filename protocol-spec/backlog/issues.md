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
**Status:** resolved
**Severity:** critical
**Origin:** spec ambiguity
**Summary:** Section 6.6 (Leave) defined no outbound control message from client to host to signal an intentional departure. The `peer_left` control message in Section 4.3 was defined only as Host → Client. Because the host received the same `STATE_DISCONNECTED` callback for both an explicit leave and an unexpected BLE drop, every client departure entered the 10-second reconnect grace window, delaying roster cleanup and wasting a client slot. The spec needed a Client → Host departure message (or equivalent mechanism) and must define the host-side handling that bypasses reconnect grace on receipt.
**Spec sections affected:** Section 4.3 (Control Message Types — direction column), Section 6.6 (Leave), Section 7.2 (Host Reconnect Grace), Section 14 (Host Client-Disconnect Decision Tree)
**Resolution:** v3 Change 2 adds `client_leaving` control message (Section 4.3), amends `Leave()` (Section 6.6 step 2) to send departure message, and amends `OnHostClientDisconnected` (Section 14) to check departure intent. GitHub issue #1 remains open for implementation verification.

---

### I-2. ConnectToRoom has no GATT connection failure path

**Source:** GitHub issue #3 — Spec gap: ConnectToRoom has no GATT failure path; causes zombie client during reconnect
**Status:** resolved
**Severity:** major
**Origin:** spec ambiguity
**Summary:** Section 6.3 (ConnectToRoom) step 7 defined behavior "On GATT connected" but specified no step for GATT connection failure (e.g., Android `status=62 GATT_CONN_FAIL_ESTABLISH`). When a connect attempt failed — particularly during reconnect — the client entered a zombie state with no retry or timeout. The spec needed a failure step that routes to `HandleJoinFailure` or equivalent cleanup. Both Android and iOS implementations independently hit this gap.
**Spec sections affected:** Section 6.3 (ConnectToRoom — missing failure step after step 7)
**Resolution:** v3 Change 3 adds ConnectToRoom step 8 with GATT connection failure path, service discovery failure routing, and normative `connectionFailureHandled` guard for dual-delivery platforms. GitHub issue #3 remains open for implementation verification.

---

### I-3. `shouldEmit` parameter undefined in Client Disconnect Decision Tree

**Source:** GitHub issue #3 — Spec gap: ConnectToRoom has no GATT failure path; causes zombie client during reconnect
**Status:** resolved
**Severity:** major
**Origin:** spec ambiguity
**Summary:** Section 13 (Client Disconnect Decision Tree) used `shouldEmit` as a parameter in the decision logic but never defined how it was derived. Both platforms independently computed it as `!clientLeaving && currentGattHandle == disconnectedHandle`, but this derivation had a subtle interaction with `StopClientOnly()` (called in ConnectToRoom step 2), which nulled the GATT reference and caused `shouldEmit=false` on subsequent disconnect callbacks. This made reconnect failures hit the "silent cleanup" path (step 6) instead of routing through `HandleJoinFailure`. The spec needed to define `shouldEmit` semantics and add a guard for reconnect-in-progress states.
**Spec sections affected:** Section 13 (Client Disconnect Decision Tree — `shouldEmit` derivation), Section 6.3 (ConnectToRoom interaction with StopClientOnly)
**Resolution:** v3 Change 1 defines `shouldEmit` derivation in Section 13 steps 3a–3d with device-identity guards for reconnect and migration in-progress states, adds Glossary entry, and changes `OnClientDisconnected` to a zero-argument function with preconditions. GitHub issue #3 remains open for implementation verification.

---

### I-4. Spec silent on app lifecycle triggers for Leave()

**Source:** GitHub issue #4 — Resilient mode: missing app lifecycle handlers — host backgrounding doesn't trigger graceful migration
**Status:** resolved
**Severity:** major
**Origin:** spec ambiguity
**Summary:** Section 6.6 defined what happens when `Leave()` is called but provided no guidance on when the platform layer should auto-invoke it. When a Resilient-mode host went to background (app switch, screen lock, phone call), the OS tore down the BLE connection without the protocol layer sending `session_migrating`. Clients fell into the worse unexpected-host-recovery path instead of graceful migration. The spec should define platform lifecycle events that constitute an implicit leave for Resilient hosts, making graceful migration the normative path for app backgrounding.
**Spec sections affected:** Section 6.6 (Leave — triggering conditions), Section 8.1 (Graceful Migration — when it should be invoked)
**Resolution:** v3 Change 5 adds Section 6.7 (Application Lifecycle Integration) with `OnAppLifecycleChanged()` procedure covering background, termination, and foreground transitions. Immediate teardown mechanism defined for termination events. GitHub issue #4 remains open for implementation verification.

---

### I-5. Unexpected host recovery has no cross-client notification

**Source:** GitHub issue #5 — Resilient mode: unexpected host recovery doesn't notify other clients of new host
**Status:** resolved
**Severity:** major
**Origin:** spec ambiguity
**Summary:** Section 8.2 (BeginUnexpectedHostRecovery) defined successor election as a purely local operation. When a client became the new host, it started advertising but sent no `session_migrating` notification to remaining clients. Each client independently ran successor election with potentially different roster state (different `membership_epoch`), risking divergent successor elections. The spec required that the new host, after successfully starting its GATT server, broadcast `session_migrating` to all known session peers. The convergence fallback (Section 8.3) handled successor failure but did not address the notification gap.
**Spec sections affected:** Section 8.2 (BeginUnexpectedHostRecovery — missing notification step), Section 8.3 (Successor Selection — epoch consistency assumption), Section 8.4 (Migration Reconnect)
**Resolution:** v3 Change 6 addresses convergent discovery through the "first advertiser wins" scan rule (Section 8.4 `OnScanResultDuringMigration` step 3) and authoritative `roster_snapshot` delivery on migration-resume reconnection. Rather than broadcasting `session_migrating` from the new host, the spec relies on scan-based discovery with convergence rules. GitHub issue #5 remains open for implementation verification.

---

### I-6. "Assert permissions granted" is underspecified

**Source:** GitHub issue #7 — Spec: clarify BLE permission requirements in 'Assert permissions granted'
**Status:** deferred
**Severity:** minor
**Origin:** spec ambiguity
**Summary:** Sections 6.1, 6.2, and 6.3 all begin with "Assert BLE is available and permissions granted" without defining which permissions are required, whether checks are per-operation or upfront, how to handle denial or re-request, or platform-specific nuances (e.g., Android 12+ BLE-specific permissions vs. pre-12 location permissions, the `neverForLocation` flag, iOS `CBManagerAuthorization` states). This ambiguity caused crashes on Android 12+ where runtime permissions must be explicitly granted. The spec should enumerate platform-agnostic permission categories (scan, connect, advertise) and define the expected behavior on denial.
**Spec sections affected:** Section 6.1 step 1, Section 6.2 step 1, Section 6.3 step 1, Section 12 (Event Types — `radio` event with `"unauthorized"` state)
**Resolution note:** v3 Changelog item 10 explicitly defers this issue: "Deferred: Assert permissions granted underspecified."

---

### I-7. Lua validation max_clients upper bound exceeds spec MaxClients range

**Source:** Codebase analysis — `lua/ble_net/config.lua` line 18
**Status:** resolved
**Severity:** minor
**Origin:** code divergence
**Summary:** The Lua config layer defines `max_clients = 8` as the upper validation bound (`config.lua:18`), while the spec Section 3.1 defines `MaxClients` as ASCII digit `'1'-'7'` and Section 6.1 step 5 clamps to `[1, 7]`. The native layer should enforce the spec range, so a value of 8 from Lua would be clamped, but the Lua validation layer permits a value the protocol cannot represent in the advertisement format. The validation layers should agree on range bounds.
**Spec sections affected:** Section 3.1 (Room Advertisement — MaxClients field), Section 6.1 step 5 (maxClients clamping)
**Resolution note:** v3 Change 8 adds normative language to Section 6.1 step 5: "Application-layer validation SHOULD reject values outside [1, 7] before they reach the protocol layer, rather than relying on silent clamping." The spec-level concern is addressed. The Lua code (`config.lua` `max_clients = 8`) still diverges and needs an implementation fix, but this is no longer a specification gap.

---

### I-8. Graceful migration path does not remove old host from successor's roster

**Source:** GitHub issue #8 — Spec gap: graceful migration does not remove old host from successor's roster
**Status:** new
**Severity:** major
**Origin:** spec ambiguity
**Summary:** Section 8.2 (Unexpected Host Recovery) step 3 explicitly states "Remove old Host from Session Peer roster," but the graceful migration path has no equivalent step. When the successor begins hosting via `BeginHostingMigratedSession` (Section 8.4), the old host's peer entry is never removed from the session peer roster. This causes `CompleteMigrationResume` (Section 8.5 step 4) to emit `session_resumed` with the departed old host still in the `peers` field. No `peer_left` event is ever emitted for the old host because it was never in the new host's `connectedClients` map. The peer persists indefinitely with no timeout mechanism. The spec needs a step in the graceful migration hosting path that mirrors Section 8.2 step 3.
**Spec sections affected:** Section 8.4 (`BeginMigrationReconnect` step 1 / `BeginHostingMigratedSession` — missing old-host removal), Section 8.5 (`CompleteMigrationResume` step 4 — emits stale roster)

---

### I-9. Resilient client transient disconnect triggers unilateral host recovery — causes split-brain

**Source:** GitHub issue #9 — Resilient client transient disconnect triggers unilateral host recovery — causes split-brain
**Status:** new
**Severity:** critical
**Origin:** architectural friction
**Summary:** The Client Disconnect Decision Tree (Section 13) routes Resilient-transport disconnects through `BeginUnexpectedHostRecovery()` (step 6) before `BeginClientReconnect()` (step 7). Because `SelectRecoverySuccessor()` (Section 8.3) always has at least the local peer as a candidate (Section 8.2 step 3 adds self to roster), `BeginUnexpectedHostRecovery()` always returns true, making step 7 unreachable for Resilient transport. On a transient BLE drop where the host is still alive, the disconnected client unilaterally elects a successor (possibly itself), starts a GATT server, and advertises the same session ID — creating a dual-host state with two GATT servers. The "first advertiser wins" mechanism (Section 8.4 step 3) only helps other scanning clients converge; it does not prevent the original host from continuing to serve its remaining clients unaware of the rogue election. The spec needs either a reconnect-before-recovery path for Resilient clients or a liveness probe before a self-elected successor commits to the host role.
**Spec sections affected:** Section 13 (Client Disconnect Decision Tree — step 6/7 ordering for Resilient transport), Section 8.2 (`BeginUnexpectedHostRecovery` — no old-host liveness check), Section 8.3 (Successor Selection — always succeeds when self is in roster)

---

### I-10. v3 Changes 6 and 7 not implemented — code-to-spec divergence on migration convergence and acceptance window

**Source:** GitHub issue #10 — Implementation missing v3 Change 6 (first advertiser wins) and Change 7 (migrationAcceptanceActive)
**Status:** new
**Severity:** major
**Origin:** code divergence
**Summary:** Two v3 spec mechanisms are not implemented in the Android BLE layer, creating code-to-spec divergence that affects migration safety. (1) `OnScanResultDuringMigration` step 3 ("first advertiser wins" — Section 8.4) is not implemented; the code only checks for the exact elected successor, so divergent elections where different clients elect different successors never converge. Both self-elected hosts advertise until timeout, losing the session for all participants. (2) `migrationAcceptanceActive` (Section 8.4 `BeginHostingMigratedSession` steps 2, 6, 7) does not exist; the implementation uses `migrationInProgress` which has different lifecycle semantics — cleared on migration completion rather than after a bounded 3s window. This means the acceptance window is tied to migration state rather than an independent timer, potentially accepting stale `migration_resume` intents or closing prematurely. The spec defines both mechanisms clearly; the code needs to catch up for v3 compliance.
**Spec sections affected:** Section 8.4 (`OnScanResultDuringMigration` step 3), Section 8.4 (`BeginHostingMigratedSession` steps 2, 6, 7), Section 17 (Migration Acceptance Window constant)
