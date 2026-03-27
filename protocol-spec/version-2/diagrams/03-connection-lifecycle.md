# Connection Lifecycle (Section 6)

## Hosting a Session (Section 6.1)

```mermaid
sequenceDiagram
    participant App as Application
    participant Host as Host Device
    participant BLE as BLE Stack

    App->>Host: Host(roomName, maxClients, transport)
    Host->>Host: Assert BLE available
    Host->>Host: Leave() any existing session
    Host->>Host: sessionId = GenerateShortID()
    Host->>Host: roomName = NormalizeRoomName()
    Host->>Host: Clamp maxClients [1,7]
    Host->>Host: membershipEpoch = 0
    Host->>BLE: Open GATT Server
    Host->>BLE: Create Service + Characteristic + CCCD
    Host->>BLE: Add Service
    BLE-->>Host: Service added
    Host->>BLE: AdvertiseRoom()
    Host->>Host: Start Heartbeat timer
    Host-->>App: Emit hosted event
```

## Scanning for Rooms (Section 6.2)

```mermaid
flowchart TD
    A[Scan] --> B[Assert BLE available]
    B --> C[Stop existing scan]
    C --> D[Clear discovered rooms]
    D --> E[Start BLE scan\nLow Latency, no filter]
    E --> F{Scan result}
    F --> G[DecodeRoom]
    G --> H{Valid room?}
    H -->|Yes| I[Store in rooms map]
    H -->|No| F
    I --> J{In active Migration\nor Reconnect?}
    J -->|No| K[Emit room_found]
    J -->|Yes| L[Suppress event]
    K --> F
    L --> F
```

## Join Handshake (Sections 6.3-6.5)

```mermaid
sequenceDiagram
    participant Client as Client
    participant BLE as BLE Link
    participant Host as Host

    Client->>Client: Join(roomID)
    Client->>Client: Look up room
    Client->>BLE: ConnectGatt(autoConnect=false)
    BLE-->>Client: GATT connected
    Client->>BLE: Request MTU
    BLE-->>Client: MTU negotiated
    Client->>BLE: Discover services
    BLE-->>Client: Service found
    Client->>BLE: Find characteristic
    Client->>BLE: Enable notifications (CCCD)
    BLE-->>Client: CCCD written
    Client->>Client: CompleteLocalJoin()
    Client->>Host: HELLO(sessionId, joinIntent)

    alt Admission Granted
        Host->>Host: Validate admission
        Host->>Host: Bind device-peer maps
        Host->>Client: hello_ack
        Host->>Host: Add peer to roster
        Host->>Host: Increment membershipEpoch
        Host-->>Host: Emit peer_joined
        Host->>Client: roster_snapshot
        Host->>Host: AdvertiseRoom()
        Client->>Client: OnHelloAckReceived()
        Client-->>Client: Emit joined
    else Admission Denied
        Host->>Client: join_rejected(reason)
        Client->>Client: Disconnect
        Client-->>Client: Emit join_failed
    end
```

## HELLO Validation (Section 6.5)

```mermaid
flowchart TD
    A[OnHelloReceived] --> B{peerId empty?}
    B -->|Yes| Z1[Disconnect device]
    B -->|No| C{clients >= maxClients\nAND not in grace?}
    C -->|Yes| Z2[join_rejected: room_full]
    C -->|No| D{peerId in\nconnectedClients?}
    D -->|Yes| Z3[join_rejected: duplicate_peer_id]
    D -->|No| E{sessionId non-empty\nAND mismatch?}
    E -->|Yes| Z4[join_rejected: stale_session]
    E -->|No| F{toPeerID !=\nhost peerId?}
    F -->|Yes| Z5[join_rejected: wrong_target]
    F -->|No| G{migration_resume\nAND not migrating?}
    G -->|Yes| Z6[join_rejected: migration_mismatch]
    G -->|No| H[Admit peer]
    H --> I{In Reconnect Grace?}
    I -->|Yes| J[Cancel grace timer\nUpdate status to connected\nBroadcast roster_snapshot]
    I -->|No| K[Add to roster\nBroadcast peer_joined\nBroadcast roster_snapshot]
```

## Leaving a Session (Section 6.6)

```mermaid
flowchart TD
    A[Leave] --> B{Hosting with\nResilient transport\nAND clients exist?}
    B -->|Yes| C[BeginGracefulMigration]
    C --> D{Migration\nsuccessful?}
    D -->|Yes| E[Return\nDeparture timer handles cleanup]
    D -->|No| F
    B -->|No| F["FinishLeave(host_left or null)"]
    F --> G[Cancel all timers]
    G --> H[Clear reconnect state]
    H --> I[Clear dedup state]
    I --> J{remoteReason\nnot null?}
    J -->|Yes| K[Send session_ended\nto all clients]
    J -->|No| L[Skip]
    K --> M[Stop advertising\nStop scanning]
    L --> M
    M --> N[Close GATT Server\nClose GATT Client]
    N --> O[Clear all maps\nReset flags]
```
