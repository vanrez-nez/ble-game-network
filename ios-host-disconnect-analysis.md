# iOS Host Connection Loss with Android Clients — Spec Compliance Analysis

**Date:** 2026-03-26
**Symptom:** When iOS hosts a BLE session and Android devices are clients, iOS loses connection after ~5-6 ping-pong exchanges. Android logs still show received pings from iOS. Never happens when Android hosts.

## Live Log Analysis (2026-03-26 04:17 UTC, Moto g34 5G client → iOS host)

### Key Evidence from Android Logcat

**Session characteristics:**
- `payload_limit=514`, `fragments=1` — NO fragmentation. High MTU negotiated.
- Host peer: `6C1489` (iOS), Client peer: `d3a498` (Android)

**Timeline:**
- `04:14:04 – 04:17:43`: Normal session. Host sends pings (~1/s) and heartbeats (~2/s). Client responds with pongs and sends its own pings. All single-fragment packets.
- `04:17:43.541`: **Last notification received from host** (ping msgId=373, nonce=558).
- `04:17:43.556`: Client sends pong (msgId=732). Write succeeds (no error logged).
- `04:17:43.800`: Client sends ping (msgId=733). Write succeeds.
- `04:17:44 onwards`: **Client continues sending pings every 1s. ZERO incoming notifications from host. No disconnect event. No write failure. No error.**
- `04:19:49`: Still sending pings (msgId=858). Still no notifications. Still no disconnect.

**Critical observations:**
1. **No fragmentation** — `payload_limit=514`, every packet is 1 fragment. Backpressure/queue stall hypothesis was wrong.
2. **No BLE disconnect** — Android never receives `onConnectionStateChange(STATE_DISCONNECTED)`. GATT link stays alive.
3. **Client writes continue succeeding** — `client enqueuePacket` + `fragmentPacket` succeed every second. The host's GATT server accepts writes.
4. **Host silently stops sending notifications** — no more `incomingFragment` after 04:17:43.
5. **Host never sent pongs** — entire log shows only `type=ping` and `type=heartbeat` from host. No `type=pong` ever received. Host was not responding to client pings.
6. **Session lasted ~3.5 minutes before failure** (04:14:04 to 04:17:43), not 5-6 seconds as initially reported.

**What this means:**
- The GATT connection is alive (writes accepted, no disconnect callback).
- The iOS host stops calling `updateValue:forCharacteristic:onSubscribedCentrals:` entirely.
- This is NOT a backpressure/queue issue (no fragmentation, high MTU).
- This is NOT a `didUnsubscribeFromCharacteristic:` issue (connection stays alive).
- Something on the iOS side causes the host to stop sending notifications while still accepting writes.
- The missing pong responses from the host suggest the Lua layer may not be processing received writes or the native layer is failing to deliver them to Lua.

**Needs iOS-side investigation:**
- iOS console logs during the failure window
- Whether `didReceiveWriteRequests:` is still being called after 04:17:43
- Whether the Lua `love.update()` loop is still polling events
- Whether the notification queue still has entries but is not being pumped

---

## Root Cause: iOS Notification Pump Violates Protocol Spec v2 §15.2

### What the spec mandates

Section 15.2 defines the Host Notification Queue pump:

```
PumpNotificationQueue(device)
1. Get the queue for device.
2. If empty, return.
3. Peek first Fragment.
4. Send notification to device via GATT Server.
5. On notification sent callback:
   a. Remove Fragment from queue.
   b. If queue not empty, call PumpNotificationQueue(device).
```

Key requirement: **step 5 is callback-driven**. The fragment is only removed after the platform confirms the notification was sent. The next fragment is only pumped after that confirmation.

### Android implementation (COMPLIANT)

**Files:** `BleManager.java:2063-2087` (pump) + `2613-2636` (callback)

```java
// Pump: sends one fragment, waits for callback
private boolean pumpNotificationQueue(BluetoothDevice device) {
    // ...
    serverMessageCharacteristic.setValue(queue.peekFirst());
    gattServer.notifyCharacteristicChanged(device, serverMessageCharacteristic, false);
    return true;  // fragment stays in queue until callback
}

// Callback: confirms delivery, then pumps next
public void onNotificationSent(BluetoothDevice device, int status) {
    if (status != BluetoothGatt.GATT_SUCCESS) {
        notificationQueues.remove(deviceKey);               // clear on failure
        nativeOnError("send_failed", "BLE notification delivery failed.");
        return;
    }
    queue.removeFirst();                                     // remove only on success
    if (!queue.isEmpty()) pumpNotificationQueue(device);     // pump next
}
```

This is a 1:1 match with §15.2 steps 4-5. The callback naturally flow-controls the sending rate — Android never sends faster than the BLE stack can deliver.

### iOS implementation (NON-COMPLIANT)

**File:** `Ble.mm:1295-1328`

```objc
- (BOOL)pumpNotificationQueueForCentral:(CBCentral *)central
{
    // ... checks ...

    NSString *key = centralKey(central);
    NSMutableArray<NSData *> *queue = _notificationQueues[key];
    if (queue == nil || queue.count == 0)
        return YES;

    if (![_peripheralManager updateValue:queue.firstObject
            forCharacteristic:_hostCharacteristic
            onSubscribedCentrals:@[central]])
        return NO;                      // (A) backpressure: returns NO, no retry

    [queue removeObjectAtIndex:0];      // (B) removed immediately, not on callback

    if (queue.count == 0) {
        [_notificationQueues removeObjectForKey:key];
        return YES;
    }

    // schedule next fragment with 15ms spacing
    if (_reliabilityFragmentSpacingMs > 0) {
        dispatch_after(...15ms..., ^{
            [self pumpNotificationQueueForCentral:central];
        });
    } else {
        [self pumpNotificationQueueForCentral:central];
    }
    return YES;
}
```

**Two violations:**

#### Violation 1: Fragment removed synchronously, not on callback (point B)

`updateValue:forCharacteristic:onSubscribedCentrals:` is synchronous — it returns `YES`/`NO` immediately. `YES` means "queued in CoreBluetooth's internal buffer," NOT "delivered to device." CoreBluetooth has no per-notification delivery callback equivalent to Android's `onNotificationSent()`.

The closest delegate is `peripheralManagerIsReadyToUpdateSubscribers:` (`Ble.mm:2652-2661`), but this signals buffer space availability, not per-fragment delivery. It fires when the internal buffer drains enough to accept new notifications.

The iOS pump removes the fragment immediately on `YES` (line 1308) and schedules the next fragment after 15ms. This means iOS fires fragments as fast as 15ms apart, regardless of whether the BLE stack has actually delivered them. There is no flow control.

#### Violation 2: No recovery when send fails (point A)

When `updateValue:` returns `NO` (CoreBluetooth transmit buffer full):
- The fragment correctly stays in the queue (it was peeked, not removed)
- But the pump simply returns `NO` — **no retry is scheduled**
- The queue is permanently stalled

The only recovery path is `peripheralManagerIsReadyToUpdateSubscribers:` (`Ble.mm:2652-2661`):

```objc
- (void)peripheralManagerIsReadyToUpdateSubscribers:(CBPeripheralManager *)peripheral
{
    for (NSString *key in [_notificationQueues allKeys])
    {
        CBCentral *central = _centralsByKey[key];
        if (central != nil)
            [self pumpNotificationQueueForCentral:central];
    }
}
```

This delegate has **no guaranteed timing from Apple**. It may fire quickly or not at all. Meanwhile, new traffic continues appending to the stalled queue:
- Heartbeat roster fingerprint: every 2s to all clients
- Heartbeat re-broadcast of last broadcast packet: every 2s to all clients
- Relay of each client's messages to other clients: every ~1s per client

---

## How This Causes the ~5-6 Second Connection Loss

Timeline with 2 Android clients connected to iOS host running ping-pong demo:

| Time | Event | Queue state |
|------|-------|-------------|
| T=0s | Session established, queues empty | 0 fragments |
| T=1s | Ping relays (2 per second) | Draining normally |
| T=2s | Heartbeat: fingerprint + re-broadcast to 2 clients | Queue growing |
| T=3-4s | Continued pings + heartbeat | CoreBluetooth buffer filling |
| T=4-5s | `updateValue:` returns NO | **Queue stalled** |
| T=5-6s | 2-3 more seconds of heartbeats + relays pile up | Queue growing unbounded |
| T=6-7s | CoreBluetooth fires `didUnsubscribeFromCharacteristic:` | **Client removed** |

When `didUnsubscribeFromCharacteristic:` fires (`Ble.mm:2621-2650`), it maps to §14 `OnHostClientDisconnected`:
- Clears notification queue, pending client state, MTU map
- Triggers `BeginPeerReconnectGrace(peerID)` — 10s grace window
- Client is effectively disconnected from the session

**Why Android still shows received pings:** The BLE L2CAP link may still be alive — `didUnsubscribeFromCharacteristic:` is a GATT-level event from CoreBluetooth's perspective, not necessarily an L2CAP disconnect. Or Android is processing notifications that were already buffered in its BLE stack before the iOS-side unsubscribe.

**Why it's intermittent:** Depends on MTU negotiation result. If `central.maximumUpdateValueLength` returns a high value (e.g., 182 bytes from a 185 MTU negotiation), packets fit in 1 fragment instead of 4-5, reducing queue pressure. Under favorable conditions, the queue never fills.

---

## §15.2 Spec Gap: No Failure Handling Defined

§15.1 (Client Write Queue) has explicit failure handling at step 6c:

> "If write failed, clear queue and emit error `write_failed` with platform-specific BLE error detail."

§15.2 (Host Notification Queue) has **no equivalent step**. It only covers the happy path. Missing from the spec:

1. What to do when notification send fails (backpressure or error)
2. Whether to clear the queue (like §15.1), retry, or use platform-specific recovery
3. Queue size limits to prevent unbounded growth during backpressure
4. How platform-specific mechanisms (iOS `peripheralManagerIsReadyToUpdateSubscribers:`) map to the abstract pump model

This gap leaves iOS implementations without a spec-defined recovery path when `updateValue:` returns NO.

---

## Additional Compliance Gaps

### Max Concurrent Assemblies Per Source not enforced

- **Spec:** §17 defines "Max Concurrent Assemblies Per Source: 32"
- **iOS:** Fragment assembly logic in `Ble.mm` creates assemblies without per-source limit
- **Risk:** Misbehaving peer could exhaust memory

### MTU 185 not proactively requested

- **Spec:** §16 "Desired ATT MTU: 185 bytes"
- **iOS:** Reads `central.maximumUpdateValueLength` reactively at subscribe time (`Ble.mm:2618`) but doesn't proactively request MTU 185
- **Impact:** May operate at lower MTU than necessary, causing more fragmentation and more queue pressure — contributing to the backpressure problem above

---

## Relevant Code Locations

| Component | File | Lines |
|-----------|------|-------|
| iOS notification pump (bug) | `love/src/modules/ble/apple/Ble.mm` | 1295-1328 |
| iOS notification enqueue | `love/src/modules/ble/apple/Ble.mm` | 1330-1359 |
| iOS readyToUpdate delegate | `love/src/modules/ble/apple/Ble.mm` | 2652-2661 |
| iOS didUnsubscribe handler | `love/src/modules/ble/apple/Ble.mm` | 2621-2650 |
| iOS heartbeat (adds queue pressure) | `love/src/modules/ble/apple/Ble.mm` | 2779-2822 |
| iOS unused `_fragmentPacingInFlight` | `love/src/modules/ble/apple/Ble.mm` | 503 |
| Android notification pump (compliant) | `BleManager.java` | 2063-2087 |
| Android onNotificationSent (compliant) | `BleManager.java` | 2613-2636 |
| Spec §15.2 | `protocol-spec/version-2/spec.md` | 720-732 |
| Spec §15.1 (has failure handling) | `protocol-spec/version-2/spec.md` | 700-718 |
| Spec §14 disconnect tree | `protocol-spec/version-2/spec.md` | 682-696 |

---

## Summary

| Finding | Type | Severity |
|---------|------|----------|
| iOS pump removes fragment synchronously instead of on callback (§15.2 step 5) | Code divergence | Critical |
| iOS pump has no retry/recovery on `updateValue:` NO | Code divergence | Critical |
| §15.2 defines no failure handling for notification sends | Spec gap | Critical |
| Max concurrent assemblies not enforced on iOS | Code divergence | Major |
| MTU 185 not proactively requested on iOS | Code divergence | Medium |

---

## Fix Attempts Log (2026-03-26, debugging session with remote TCP logs)

### Setup: TCP Log Server

Added a TCP log server to `ble_log.lua` (replacing the ENet-based server) so logs can be pulled from devices via `nc <ip> 4400`. Commands: `tail <n>`, `since <minutes>`, `follow`, `status`. Server status shown on debug overlay via `ble_log.server_state`. Required `pcall(require, "socket")` for safe loading on iOS, and `"0.0.0.0"` bind instead of `"*"`.

Also added `"raw"` catch-all category to `classify_diagnostic()` in `ble_net/init.lua` so ALL native `bleLog()` entries (including `incomingFragment`, `fragmentPacket`, etc.) are captured in the TCP log, not just classified events.

### Key finding from raw logs

With `raw` logging enabled, `incomingFragment` entries (logged inside `processIncomingFragment` at the top of `didReceiveWriteRequests` processing) **stop entirely** after 6-15 fragments. This proves **CoreBluetooth stops calling `didReceiveWriteRequests`** — the issue is not in packet validation, dedup, fragment assembly, or any application-level logic. The delegate method simply stops being invoked.

Meanwhile, `enqueueNotification` entries continue indefinitely — iOS keeps sending notifications via `updateValue:forCharacteristic:` without issue.

### Attempt 1: Single `respondToRequest:` per batch

**Theory:** Apple docs say `respondToRequest:withResult:` must be called exactly once per `didReceiveWriteRequests:` invocation. The original code called it once per request in the loop, potentially desynchronizing CoreBluetooth's internal write-response tracking.

**Change:** Split into validate-all → respond-once → process-all. Respond with `requests.firstObject` after validating the batch.

**Result:** Did not fix the issue. Messages lasted slightly longer (~4s vs ~1s in some runs) but writes still stopped. The fix was correct per Apple API contract but was not the root cause.

**File:** `Ble.mm` `didReceiveWriteRequests:` (line ~2681)

### Attempt 2: `peripheralManagerIsReadyToUpdateSubscribers:` respect fragment spacing

**Theory:** The `peripheralManagerIsReadyToUpdateSubscribers:` callback drained the notification queue in a tight `while` loop, bypassing the 15ms fragment spacing used by `pumpNotificationQueueForCentral:`. This could flood the BLE link and starve inbound writes.

**Change:** Replaced the tight `while` loop with calls to `pumpNotificationQueueForCentral:` (which respects 15ms spacing).

**Result:** Did not fix the issue. Same behavior.

**File:** `Ble.mm` `peripheralManagerIsReadyToUpdateSubscribers:` (line ~2652)

### Attempt 3: Dedicated serial dispatch queue for CoreBluetooth

**Theory:** Both `CBCentralManager` and `CBPeripheralManager` delegates and the notification pump `dispatch_after` blocks all run on `dispatch_get_main_queue()`. Under load, write request delivery could stall on the main queue while notifications continue flowing.

**Change:** Created `dispatch_queue_create("love.ble.delegate", DISPATCH_QUEUE_SERIAL)` and used it for both managers and all `dispatch_after` calls.

**Result:** Did not fix the issue. Reverted. (Note: moving off main queue may cause thread-safety issues with Lua callbacks that expect main thread execution.)

**File:** `Ble.mm` init (line ~552) + all `dispatch_after` calls

### Attempt 4: Defer packet processing after `respondToRequest:`

**Theory:** Processing packets inside `didReceiveWriteRequests` triggers notification sends via `enqueueNotificationPacketData` → `pumpNotificationQueueForCentral` → `updateValue:`. These outgoing notifications could fill the transmit buffer before the ATT write response from `respondToRequest:` has been flushed, blocking the central's write pipeline.

**Change:** Collected fragment data into an array, responded to all writes immediately, returned from the delegate, then processed packets via `dispatch_async(dispatch_get_main_queue(), ...)`.

**Result:** Did not fix the issue. Same behavior — `incomingFragment` entries still stop after a few seconds.

**File:** `Ble.mm` `didReceiveWriteRequests:` (line ~2681)

### Attempt 5: Remove `CBCharacteristicPropertyWriteWithoutResponse`

**Theory:** The characteristic was created with both `Write` and `WriteWithoutResponse` properties (line 1701). The spec (§2) only defines Read, Write, Notify. Some Android BLE stacks default to write-without-response when both properties are present, bypassing ATT-level flow control and allowing Android to blast writes faster than iOS can process them.

**Change:** Removed `CBCharacteristicPropertyWriteWithoutResponse` from the characteristic properties.

**Result:** Did not fix the issue. Same behavior.

**File:** `Ble.mm` characteristic creation (line ~1700)

### What we know for certain

1. **`didReceiveWriteRequests` stops being called** — confirmed by `incomingFragment` log entries stopping entirely (not filtered by validation/dedup)
2. **Outbound notifications continue working** — iOS keeps sending pings and heartbeats via `updateValue:` after inbound stops
3. **No BLE disconnect occurs** — no `didUnsubscribeFromCharacteristic:` or connection state change logged
4. **Android keeps sending writes** — `client enqueuePacket` entries continue, no `write_failed` or `send_failed` errors
5. **MTU is 512** — single-fragment packets, no fragmentation pressure
6. **Timing varies** — 1-12 seconds after connection, sometimes works fine
7. **Only when iOS hosts** — never happens with Android as host
8. **Multiple iOS-side fixes had no effect** — the problem may be in the Android write path or a CoreBluetooth internal issue that cannot be worked around from the delegate level

### Open questions

- Is Android's `onCharacteristicWrite` callback still firing after the cutoff? (No logging on success in current code)
- Could `clientWriteInFlight` be stuck `true` on Android, preventing further writes from being sent?
- Is this a known CoreBluetooth regression on specific iOS versions?
- Would switching to `WriteWithoutResponse` exclusively (with application-level flow control) avoid the issue?
