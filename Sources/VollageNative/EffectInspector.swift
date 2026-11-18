import FrameShiftEffects
import SwiftUI

struct EffectInspector: View {
    let model: CanvasModel
    let clip: Clip
    @State private var expanded = true
    @State private var openEffect: UUID?

    init(model: CanvasModel, clip: Clip) {
        self.model = model
        self.clip = clip
        _openEffect = State(initialValue: clip.state.effectStack.first?.id)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(clip.state.effectStack) { effect in
                    row(effect)
                }
                Menu("Add Effect", systemImage: "plus") {
                    ForEach(EffectKind.allCases) { kind in
                        Button(kind.title) {
                            let effect = EffectInstance(kind: kind)
                            edit { $0.append(effect) }
                            openEffect = effect.id
                        }
                    }
                }
                .disabled(clip.state.effectStack.count >= VideoState.maximumEffects)
                .help("Add an effect to the selected video")
            }
            .padding(.top, 4)
        } label: {
            let count = clip.state.effectStack.count
            Text(count == 0 ? "Effects" : "Effects (\(count))")
        }
        .disabled(!model.canEdit)
    }

    private func row(_ effect: EffectInstance) -> some View {
        let stack = clip.state.effectStack
        let isExpanded = Binding(get: { openEffect == effect.id }, set: { openEffect = $0 ? effect.id : nil })
        return HStack(alignment: .top, spacing: 8) {
            DisclosureGroup(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable Effect", isOn: Binding(
                        get: { effect.isEnabled },
                        set: { value in edit(effect.id) { $0.isEnabled = value } }
                    ))
                    ForEach(effect.kind.params, id: \.key) { param in
                        control(param, for: effect)
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Text(effect.kind.title)
                    .foregroundStyle(effect.isEnabled ? Color.primary : Color.secondary)
                    .accessibilityValue(effect.isEnabled ? "Enabled" : "Bypassed")
            }
            Menu {
                Button(effect.isEnabled ? "Bypass Effect" : "Enable Effect") { edit(effect.id) { $0.isEnabled.toggle() } }
                Button("Move Up") { move(effect.id, by: -1) }.disabled(stack.first?.id == effect.id)
                Button("Move Down") { move(effect.id, by: 1) }.disabled(stack.last?.id == effect.id)
                Divider()
                Button("Remove Effect", role: .destructive) { edit { $0.removeAll { $0.id == effect.id } } }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityHidden(true)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("\(effect.kind.title) actions")
            .help("Manage \(effect.kind.title)")
        }
    }

    @ViewBuilder private func control(_ param: ParamSpec, for effect: EffectInstance) -> some View {
        let value = effect.value(param.key)
        if let options = param.options {
            Picker(param.label, selection: Binding(
                get: { Int(value) },
                set: { selection in edit(effect.id) { $0.set(param.key, Double(selection)) } }
            )) {
                ForEach(options.indices, id: \.self) { index in Text(options[index]).tag(index) }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(param.label)
                    Spacer()
                    Text(param.format(value)).monospacedDigit().foregroundStyle(.secondary)
                }
                let binding = Binding(
                    get: { value },
                    set: { value in edit(effect.id) { $0.set(param.key, value) } }
                )
                if param.isInteger {
                    Slider(value: binding, in: param.range, step: 1, onEditingChanged: editing)
                        .accessibilityLabel(param.label).accessibilityValue(param.format(value))
                } else {
                    Slider(value: binding, in: param.range, onEditingChanged: editing)
                        .accessibilityLabel(param.label).accessibilityValue(param.format(value))
                }
            }
        }
    }

    private func editing(_ active: Bool) {
        if active { model.beginGesture() }
        else { model.endGesture() }
    }

    private func edit(_ change: (inout [EffectInstance]) -> Void) {
        guard model.selection.count == 1, model.selected === clip else { return }
        model.edit { change(&$0.state.effectStack) }
    }

    private func edit(_ id: UUID, _ change: (inout EffectInstance) -> Void) {
        edit { stack in
            guard let index = stack.firstIndex(where: { $0.id == id }) else { return }
            change(&stack[index])
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        edit { stack in
            guard let index = stack.firstIndex(where: { $0.id == id }), stack.indices.contains(index + offset) else { return }
            stack.swapAt(index, index + offset)
        }
    }
}
