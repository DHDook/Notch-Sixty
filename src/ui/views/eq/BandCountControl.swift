import SwiftUI

struct BandCountControl: View {
    @EnvironmentObject var store: EqualiserStore
    @State private var isEditing = false
    @State private var text: String = ""
    @FocusState private var isFocused: Bool
    @State private var showRemoveBandConfirmation = false

    var body: some View {
        HStack(spacing: 4) {
            StepperButton(symbol: "-", action: { showRemoveBandConfirmation = true })

            // Inline editable band count - matching gain control style
            Group {
                if isEditing {
                    TextField("", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .frame(width: 54)
                        .multilineTextAlignment(.center)
                        .focused($isFocused)
                        .onAppear {
                            text = "\(store.bandCount)"
                            DispatchQueue.main.async {
                                isFocused = true
                            }
                        }
                        .onSubmit(commit)
                        .onChange(of: text) { _, newValue in
                            let digitsOnly = newValue.filter { $0.isNumber }
                            if digitsOnly != newValue {
                                text = digitsOnly
                            }
                        }
                        .onChange(of: isFocused) { _, focused in
                            if !focused {
                                commit()
                            }
                        }
                } else {
                    Text("\(store.bandCount)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .frame(width: 54)
                        .onTapGesture {
                            text = "\(store.bandCount)"
                            isEditing = true
                        }
                }
            }

            StepperButton(symbol: "+", action: { adjustBands(by: 1) })
        }
        .onChange(of: store.bandCount) { _, newValue in
            text = "\(newValue)"
            isEditing = false
        }
        .alert("Remove Last Band?", isPresented: $showRemoveBandConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                adjustBands(by: -1)
            }
        } message: {
            Text("This removes band \(store.bandCount) from the EQ. This cannot be undone.")
        }
    }

    private func adjustBands(by delta: Int) {
        let newCount = store.bandCount + delta
        applyBandCount(newCount)
    }

    private func commit() {
        guard isEditing else { return }
        defer { isEditing = false }
        if let value = Int(text) {
            applyBandCount(value)
        }
    }

    private func applyBandCount(_ count: Int) {
        let clamped = EQConfiguration.clampBandCount(count)
        store.updateBandCount(clamped)
        text = "\(clamped)"
    }
}
