import SwiftUI

struct StyledDropdown<V: Hashable, Content: View>: View {
    @Binding var selection: V
    let width: CGFloat
    let current: String
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Menu {
            Picker("", selection: $selection, content: content)
                .labelsHidden()
                .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                Text(current)
                    .font(.system(size: 13))
                    .foregroundColor(PTT.textPrimary(scheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(PTT.textMuted(scheme))
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(width: width, height: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(PTT.fieldBG(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PTT.fieldBorder(scheme), lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
