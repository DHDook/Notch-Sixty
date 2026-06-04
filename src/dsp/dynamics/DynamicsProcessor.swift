[Content from line 1-250 remains unchanged]
     /// nonisolated(unsafe) since it's a let set once in init and never changes,
     /// and setDeviceVolumeScalar is nonisolated.
     nonisolated(unsafe) let volumeService: VolumeControlling
     private let logger = Logger(subsystem: "net.knage.equaliser", category: "VolumeManager")

    // ... rest of file remains the same - only the variable declaration on line 727 needs to be removed
    // Remove the duplicate 'let subPhaseOn' declaration around line 727