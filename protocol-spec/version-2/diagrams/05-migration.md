# Migration (Section 8)

## Graceful Migration - Full Sequence (Section 8.1)

```mermaid
sequenceDiagram
    participant OldHost as Old Host
    participant Successor as Successor (Client)
    participant OtherClient as Other Client

    Note over OldHost: Host calls Leave() with Resilient transport
    OldHost->>OldHost: BeginGracefulMigration()
    OldHost->>OldHost: Cancel all grace timers
    OldHost->>OldHost: Remove grace peers from roster
    OldHost->>OldHost: Increment membershipEpoch
    OldHost->>OldHost: successor = SelectSuccessor()
    OldHost->>OldHost: Encode migration payload
    OldHost->>Successor: session_migrating(successor, sessionId, epoch)
    OldHost->>OtherClient: session_migrating(successor, sessionId, epoch)
    OldHost->>OldHost: migrationInProgress = true
    OldHost->>OldHost: Schedule departure (400ms)

    par Successor receives migration
        Successor->>Successor: OnSessionMigratingReceived()
        Successor->>Successor: Discard write queue
        Successor->>Successor: Clear fragment assemblies
        Successor->>Successor: Disconnect from old host
        Successor->>Successor: BeginMigrationReconnect()
        Successor->>Successor: BeginHostingSession(migrationInfo)
        Successor->>Successor: Remove old host from roster
        Successor->>Successor: Open GATT Server
        Successor->>Successor: AdvertiseRoom()
        Successor->>Successor: Schedule migration timeout (3s)
    and Other client receives migration
        OtherClient->>OtherClient: OnSessionMigratingReceived()
        OtherClient->>OtherClient: Discard write queue
        OtherClient->>OtherClient: Clear fragment assemblies
        OtherClient->>OtherClient: Disconnect from old host
        OtherClient->>OtherClient: BeginMigrationReconnect()
        OtherClient->>OtherClient: Start scan for successor
        OtherClient->>OtherClient: Schedule migration timeout (3s)
    end

    Note over OldHost: 400ms departure timer fires
    OldHost->>OldHost: FinishLeave()
    OldHost->>OldHost: Close GATT, cleanup

    OtherClient->>Successor: Scan finds successor's advertisement
    OtherClient->>Successor: ConnectToRoom(migrationJoin=true)
    OtherClient->>Successor: HELLO(sessionId, migration_resume)
    Successor->>OtherClient: hello_ack
    Successor->>Successor: CompleteMigrationResume()
    Successor-->>Successor: Emit session_resumed
    OtherClient->>OtherClient: CompleteMigrationResume()
    OtherClient-->>OtherClient: Emit session_resumed
```

## BeginGracefulMigration Flow (Section 8.1)

```mermaid
flowchart TD
    A[BeginGracefulMigration] --> B[Cancel all grace timers]
    B --> C[Remove grace peers from roster]
    C --> D[Increment membershipEpoch]
    D --> E["successor = SelectSuccessor()"]
    E --> F{Successor found?}
    F -->|No| G[Return false]
    F -->|Yes| H["Encode payload:\nsessionId|successor|maxClients|\nroomName|epoch"]
    H --> I[Send session_migrating\nto all clients]
    I --> J[migrationInProgress = true]
    J --> K[Schedule departure 400ms]
    K --> L["On departure: FinishLeave()"]
    L --> M[Return true]
```

## Unexpected Host Recovery (Section 8.2)

```mermaid
sequenceDiagram
    participant Client1 as Client A (Successor)
    participant Client2 as Client B

    Note over Client1,Client2: Host connection drops unexpectedly
    Client1->>Client1: OnClientDisconnected(wasJoined=true)
    Client2->>Client2: OnClientDisconnected(wasJoined=true)

    Client1->>Client1: BeginUnexpectedHostRecovery()
    Client1->>Client1: Remove old host from roster
    Client1->>Client1: SelectRecoverySuccessor(oldHostId)
    Client1->>Client1: becomingHost = (successor == self)

    Client2->>Client2: BeginUnexpectedHostRecovery()
    Client2->>Client2: Remove old host from roster
    Client2->>Client2: SelectRecoverySuccessor(oldHostId)
    Client2->>Client2: becomingHost = (successor == self)

    Note over Client1,Client2: Both elect same successor (lexicographic sort)

    alt Client1 is successor
        Client1->>Client1: BeginHostingSession(migrationInfo)
        Client1->>Client1: AdvertiseRoom()
        Client2->>Client2: Start scan for successor
        Client2->>Client1: Finds advertisement, connects
        Client2->>Client1: HELLO(sessionId, migration_resume)
        Client1->>Client2: hello_ack
        Client1->>Client1: CompleteMigrationResume()
        Client2->>Client2: CompleteMigrationResume()
    end
```

## Successor Selection (Section 8.3)

```mermaid
flowchart TD
    subgraph "SelectSuccessor (Host-initiated)"
        A1[Collect connected client PeerIDs] --> B1[Exclude peers in grace]
        B1 --> C1[Sort lexicographically ascending]
        C1 --> D1[Return first or empty]
    end

    subgraph "SelectRecoverySuccessor (Client-initiated)"
        A2[Collect Session Peers with\nstatus=connected] --> B2[Exclude grace peers]
        B2 --> C2[Exclude oldHostID]
        C2 --> D2[Sort lexicographically ascending]
        D2 --> E2[Return first or empty]
    end
```

## Convergence Fallback (Section 8.3)

```mermaid
flowchart TD
    A[Successor elected] --> B[Schedule migration timeout 3s]
    B --> C{Successor advertises\nwithin timeout?}
    C -->|Yes| D[Connect to successor\nComplete migration]
    C -->|No| E[Exclude successor from candidates]
    E --> F{Candidates remaining?}
    F -->|Yes| G[Re-run successor election]
    G --> B
    F -->|No| H[Session lost]
    H --> I[Emit session_ended]
```

## Migration Reconnect (Section 8.4)

```mermaid
flowchart TD
    A[BeginMigrationReconnect] --> B{Becoming host?}
    B -->|Yes| C[BeginHostingSession\nwith migration info]
    C --> D[Remove old host from roster]
    D --> E[Open GATT Server]
    E --> F[AdvertiseRoom]
    B -->|No| G[Start scan for\nnew host advertisement]
    F --> H[Schedule migration\ntimeout 3s]
    G --> H
    H --> I{What happens?}
    I -->|Successor found| J[ConnectToRoom\nmigrationJoin=true]
    J --> K[HELLO migration_resume]
    K --> L[hello_ack received]
    L --> M[CompleteMigrationResume]
    I -->|Timeout| N[FailMigration]
    N --> O[Emit session_ended\nmigration_failed]
```

## CompleteMigrationResume (Section 8.5)

```mermaid
flowchart TD
    A[CompleteMigrationResume] --> B[Cancel migration timeout]
    B --> C[Clear migration state fields]
    C --> D[Set membershipEpoch\nfrom migration control]
    D --> E["Emit session_resumed:\n- session_id\n- new_host_id\n- peers (current roster)"]
```
