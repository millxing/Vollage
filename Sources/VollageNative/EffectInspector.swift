import FrameShiftEffects
import SwiftUI

struct EffectInspector: View {
    let model: CanvasModel
    let clip: Clip
    @State private var openEffect: UUID?

    init(model: CanvasModel, clip: Clip) {
        self.model = model
        self.clip = clip
        _openEffect = State(initialValue: clip.state.effectStack.first?.id)
    }

    var body: some View {
        let stack = clip.state.effectStack
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Effects").font(.headline)
                Spacer()
                addMenu(isFull: stack.count >= VideoState.maximumEffects)
            }
            if stack.isEmpty {
                Text("No effects yet. Add one to transform this video.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(stack) { effect in
                card(effect, in: stack)
            }
        }
        .disabled(!model.canEdit)
    }

    private func addMenu(isFull: Bool) -> some View {
        Menu {
            ForEach(EffectCategory.allCases, id: \.self) { category in
                Section(category.title) {
                    ForEach(EffectKind.kinds(in: category)) { kind in
                        Button(kind.title) {
                            let effect = EffectInstance(kind: kind)
                            edit { $0.append(effect) }
                            openEffect = effect.id
                        }
                        .help(kind.summary)
                    }
                }
            }
        } label: {
            Label("Add Effect", systemImage: "plus")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(isFull)
        .help(isFull ? "This video has the most effects it can hold" : "Add an effect to the selected video")
    }

    private func card(_ effect: EffectInstance, in stack: [EffectInstance]) -> some View {
        let isOpen = openEffect == effect.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("Enable \(effect.kind.title)", isOn: Binding(
                    get: { effect.isEnabled },
                    set: { value in edit(effect.id) { $0.isEnabled = value } }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(effect.isEnabled ? "Bypass this effect" : "Turn this effect on")
                Button {
                    openEffect = isOpen ? nil : effect.id
                } label: {
                    HStack(spacing: 4) {
                        Text(effect.kind.title)
                            .foregroundStyle(effect.isEnabled ? Color.primary : Color.secondary)
                        Spacer(minLength: 0)
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(effect.isEnabled ? "Enabled" : "Bypassed")
                Button { move(effect.id, by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(stack.first?.id == effect.id)
                    .help("Move up. Effects run from top to bottom.")
                Button { move(effect.id, by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(stack.last?.id == effect.id)
                    .help("Move down")
                Button(role: .destructive) { edit { $0.removeAll { $0.id == effect.id } } } label: { Image(systemName: "trash") }
                    .help("Remove \(effect.kind.title)")
            }
            .buttonStyle(.borderless)
            if isOpen {
                ForEach(effect.kind.params, id: \.key) { param in
                    control(param, for: effect)
                }
                .disabled(!effect.isEnabled)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
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
