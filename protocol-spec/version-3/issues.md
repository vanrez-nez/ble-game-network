# Protocol Specification v3 — Curated Issues

Curated by the spec-curator agent for the v3 revision cycle. Each entry traces
to the master backlog at `backlog/issues.md`. Ordered by severity.

---

## Issues

### I-1. Resilient client transient disconnect triggers unilateral host recovery — causes split-brain

**Severity:** critical
**Origin:** from backlog entry I-9
**Observed in:** Section 13 (Client Disconnect Decision Tree — step 6/7 ordering for Resilient transport), Section 8.2 (BeginUnexpectedHostRecovery — no old-host liveness check), Section 8.3 (Successor Selection — always succeeds when self is in roster)
**Description:** The Client Disconnect Decision Tree (Section 13) routes Resilient-transport disconnects through `BeginUnexpectedHostRecovery()` (step 6) before `BeginClientReconnect()` (step 7). Because `SelectRecoverySuccessor()` always has at least the local peer as a candidate (self is added to the roster in Section 8.2 step 3), `BeginUnexpectedHostRecovery()` always returns true, making step 7 unreachable for Resilient transport. On a transient BLE drop where the host is still alive, the disconnected client unilaterally elects a successor (possibly itself), starts a GATT server, and advertises the same session ID — creating a dual-host state. The "first advertiser wins" mechanism (Section 8.4 step 3) helps other scanning clients converge but does not prevent the original host from continuing to serve its remaining clients unaware of the rogue election. The spec needs either a reconnect-before-recovery ordering for Resilient clients or a liveness probe / backoff before a self-elected successor commits to the host role.
**Spec sections affected:** Section 13 (step 6/7 ordering), Section 8.2 (BeginUnexpectedHostRecovery), Section 8.3 (SelectRecoverySuccessor)

---

### I-2. Graceful migration path does not remove old host from successor's roster

**Severity:** major
**Origin:** from backlog entry I-8
**Observed in:** Section 8.4 (BeginHostingMigratedSession — no old-host removal step), Section 8.5 (CompleteMigrationResume — emits stale roster with departed old host)
**Description:** Section 8.2 (Unexpected Host Recovery) step 3 explicitly states "Remove old Host from Session Peer roster," but the graceful migration path has no equivalent step. When the successor begins hosting via `BeginHostingMigratedSession` (Section 8.4), the old host's peer entry is never removed. This causes `CompleteMigrationResume` (Section 8.5 step 4) to emit `session_resumed` with the departed old host still in the `peers` field. No `peer_left` event is ever emitted for the old host because it was never in the new host's `connectedClients` map. The peer persists indefinitely with no timeout mechanism. The spec needs a step in the graceful migration hosting path that mirrors Section 8.2 step 3.
**Spec sections affected:** Section 8.4 (BeginHostingMigratedSession), Section 8.5 (CompleteMigrationResume step 4)

---

### I-3. "Assert permissions granted" is underspecified

**Severity:** minor
**Origin:** from backlog entry I-6
**Observed in:** Section 6.1 step 1, Section 6.2 step 1, Section 6.3 step 1
**Description:** Sections 6.1, 6.2, and 6.3 all begin with "Assert BLE is available and permissions granted" without defining which permissions are required, whether checks are per-operation or upfront, how to handle denial or re-request, or platform-specific nuances (e.g., Android 12+ BLE-specific permissions vs. pre-12 location permissions, iOS `CBManagerAuthorization` states). This ambiguity caused crashes on Android 12+ where runtime permissions must be explicitly granted. The spec should enumerate platform-agnostic permission categories (scan, connect, advertise) and define expected behavior on denial. This issue was explicitly deferred in v3 changelog item 10; it is re-selected for this cycle as a completeness gap.
**Spec sections affected:** Section 6.1, Section 6.2, Section 6.3, Section 12 (Event Types — `radio` event with `"unauthorized"` state)
