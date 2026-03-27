# Protocol Specification v2 — Curated Issues

Curated by the spec-curator agent for the v2 revision cycle. Each entry traces
to the master backlog at `backlog/issues.md`. Ordered by severity.

---

## Issues

### I-1. No client-to-host departure message

**Severity:** critical
**Origin:** from backlog entry I-1
**Observed in:** Section 6.6 (Leave), Section 4.3 (Control Message Types — no client→host departure direction), Section 14 (Host Client-Disconnect Decision Tree)
**Description:** The spec defines no outbound control message from client to host to signal an intentional departure. The host cannot distinguish an explicit leave from a BLE drop — both arrive as `STATE_DISCONNECTED`. Every client departure therefore enters the 10-second reconnect grace window (Section 7.2), delaying roster cleanup and holding a client slot. The spec needs a Client → Host departure message and host-side handling that bypasses reconnect grace on receipt.
**Spec sections affected:** Section 4.3, Section 6.6, Section 7.2, Section 14

---

### I-2. `shouldEmit` parameter undefined in Client Disconnect Decision Tree

**Severity:** critical
**Origin:** from backlog entry I-3
**Observed in:** Section 13 (Client Disconnect Decision Tree — `shouldEmit` used but never derived)
**Description:** Section 13 uses `shouldEmit` as a branching parameter but never defines how it is computed. Both platform implementations independently derived it as `!clientLeaving && currentGattHandle == disconnectedHandle`, but this derivation interacts poorly with `StopClientOnly()` (called in ConnectToRoom step 2), which nulls the GATT reference and forces `shouldEmit=false` on subsequent disconnect callbacks. This causes reconnect failures to hit the silent cleanup path (step 6) instead of routing through `HandleJoinFailure`. The spec must define `shouldEmit` semantics explicitly and add a guard for reconnect-in-progress states.
**Spec sections affected:** Section 13, Section 6.3 (ConnectToRoom interaction with StopClientOnly)

---

### I-3. Unexpected host recovery has no cross-client notification

**Severity:** major
**Origin:** from backlog entry I-5
**Observed in:** Section 8.2 (BeginUnexpectedHostRecovery — no notification step after successor starts advertising)
**Description:** Section 8.2 defines successor election as a purely local operation. When a client becomes the new host, it starts advertising but sends no `session_migrating` notification to remaining clients. Each remaining client independently runs successor election potentially with different roster state (different `membership_epoch`), risking divergent successor elections and a network split. The new host must broadcast `session_migrating` to all known session peers after successfully starting its GATT server. The convergence fallback (Section 8.3) handles successor failure but does not address this notification gap.
**Spec sections affected:** Section 8.2, Section 8.3, Section 8.4

---

### I-4. ConnectToRoom has no GATT connection failure path

**Severity:** major
**Origin:** from backlog entry I-2
**Observed in:** Section 6.3 (ConnectToRoom — missing failure step after step 7)
**Description:** Section 6.3 step 7 defines behavior "On GATT connected" but specifies no step for GATT connection failure (e.g., Android `status=62 GATT_CONN_FAIL_ESTABLISH`). When a connect attempt fails — particularly during reconnect — the client enters a zombie state with no retry, timeout, or cleanup path. The spec needs a failure step that routes to `HandleJoinFailure` or equivalent cleanup, covering both initial join and reconnect scenarios.
**Spec sections affected:** Section 6.3

---

### I-5. Spec silent on app lifecycle triggers for Leave()

**Severity:** major
**Origin:** from backlog entry I-4
**Observed in:** Section 6.6 (Leave — defines what happens but not when it should be auto-invoked)
**Description:** Section 6.6 defines the Leave() procedure but provides no guidance on when the platform layer should auto-invoke it. When a Resilient-mode host goes to background (app switch, screen lock, incoming call), the OS tears down the BLE connection without the protocol layer sending `session_migrating`. Clients fall into the unexpected-host-recovery path instead of the graceful migration path. The spec should define platform lifecycle events that constitute an implicit leave for Resilient hosts, making graceful migration the normative path for app backgrounding.
**Spec sections affected:** Section 6.6, Section 8.1

---

### I-6. "Assert permissions granted" is underspecified

**Severity:** minor
**Origin:** from backlog entry I-6
**Observed in:** Section 6.1 step 1, Section 6.2 step 1, Section 6.3 step 1
**Description:** Sections 6.1, 6.2, and 6.3 begin with "Assert BLE is available and permissions granted" without defining which permissions are required, whether checks are per-operation or upfront, how to handle denial, or platform-specific nuances (Android 12+ BLE-specific vs. pre-12 location permissions, iOS `CBManagerAuthorization` states). This ambiguity caused crashes on Android 12+ where runtime permissions must be explicitly requested. The spec should enumerate platform-agnostic permission categories (scan, connect, advertise) and define expected behavior on denial.
**Spec sections affected:** Section 6.1, Section 6.2, Section 6.3, Section 12 (`radio` event)
