import SwiftUI

/// SwiftUI wrapper for the GPU-accelerated VU meter.
struct VUMeterNSView: NSViewRepresentable {
    let meterStore: MeterStore
    let meterType: MeterType
    let channelLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> VUMeterLayer {
        let view = VUMeterLayer(channelLabel: channelLabel)
        view.frame = CGRect(x: 0, y: 0, width: 150, height: 62)
        meterStore.addObserver(view, for: meterType)
        context.coordinator.meterStore = meterStore
        context.coordinator.meterType = meterType
        return view
    }

    func updateNSView(_ nsView: VUMeterLayer, context: Context) {
        // Updates come via observer callback, not through SwiftUI
    }

    func dismantleNSView(_ nsView: VUMeterLayer, coordinator: Coordinator) {
        coordinator.meterStore?.removeObserver(nsView, for: coordinator.meterType)
    }

    class Coordinator {
        weak var meterStore: MeterStore?
        var meterType: MeterType = .inputVULeft
    }
}
