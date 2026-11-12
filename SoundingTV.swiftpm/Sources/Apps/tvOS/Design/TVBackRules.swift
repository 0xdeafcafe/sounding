import SwiftUI

extension View {
    func tvEntersFocus<Value: Hashable>(_ focus: FocusState<Value?>.Binding, _ value: Value, when condition: Bool) -> some View {
        modifier(TVFocusEntry(focus: focus, value: value, condition: condition))
    }
}

private struct TVFocusEntry<Value: Hashable>: ViewModifier {
    var focus: FocusState<Value?>.Binding
    let value: Value
    let condition: Bool

    func body(content: Content) -> some View {
        content.onChange(of: condition, initial: true) { _, now in
            guard now else { return }
            for delay in [0.0, 0.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard condition, focus.wrappedValue == nil else { return }
                    focus.wrappedValue = value
                }
            }
        }
    }
}
