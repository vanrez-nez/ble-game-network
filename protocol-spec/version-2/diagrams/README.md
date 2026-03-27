# BLE Game Network Protocol v2 - Diagrams

Mermaid flow charts and sequence diagrams for every protocol flow defined in `spec.md`.

| Diagram | Spec Sections | Contents |
|---------|---------------|----------|
| [01 - Room Advertisement](01-room-advertisement.md) | 3.1-3.5 | Encoding, discovery, platform differences, room expiry |
| [02 - Packet Format](02-packet-format.md) | 4-5 | Packet envelope, routing rules, fragmentation, reassembly |
| [03 - Connection Lifecycle](03-connection-lifecycle.md) | 6.1-6.6 | Hosting, scanning, join handshake, HELLO validation, leaving |
| [04 - Reconnection](04-reconnection.md) | 7.1-7.2 | Client reconnect, host reconnect grace, grace timer lifecycle |
| [05 - Migration](05-migration.md) | 8.1-8.5 | Graceful migration, unexpected recovery, successor selection, convergence fallback, migration reconnect, CompleteMigrationResume |
| [06 - Heartbeat](06-heartbeat.md) | 9 | Heartbeat tick, roster fingerprint validation, snapshot delivery rules |
| [07 - Deduplication](07-deduplication.md) | 10 | Dedup decision flow, scope (data vs control) |
| [08 - Disconnect Trees](08-disconnect-trees.md) | 13-14 | Client disconnect decision tree, host client-disconnect tree, combined scenarios |
| [09 - Write Serialization](09-write-serialization.md) | 15 | Client write queue, host notification queue, full write path |
| [10 - Codec](10-codec.md) | 11 | Encoding decision tree, wire format, decoding flow |
| [11 - State Machine](11-state-machine.md) | Overview | Peer lifecycle states, host-side peer states, session event flow, control message summary |
