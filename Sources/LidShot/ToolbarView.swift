import SwiftUI

struct ToolbarView: View {
    @ObservedObject var state: EditorState
    let canvas: CanvasView

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Tool.allCases) { tool in
                    Button {
                        state.tool = tool
                    } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(state.tool == tool ? Color.accentColor.opacity(0.28) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.title) (\(String(tool.key).uppercased()))")
                }
            }

            Divider().frame(height: 22)

            HStack(spacing: 7) {
                ForEach(Palette.colors.indices, id: \.self) { index in
                    let color = Palette.colors[index]
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.primary.opacity(0.3), lineWidth: 1))
                        .overlay(
                            Circle()
                                .stroke(Color.accentColor, lineWidth: 2)
                                .padding(-3)
                                .opacity(state.color == color ? 1 : 0)
                        )
                        .contentShape(Circle())
                        .onTapGesture { state.color = color }
                }
            }

            Divider().frame(height: 22)

            Image(systemName: "lineweight").foregroundStyle(.secondary)
            Slider(value: $state.width, in: 1...12)
                .frame(width: 90)
                .help("Толщина линии / размер текста")

            Spacer(minLength: 8)

            Button { canvas.undo(nil) } label: { Image(systemName: "arrow.uturn.backward") }
                .help("Отменить (⌘Z)")
            Button { canvas.redo(nil) } label: { Image(systemName: "arrow.uturn.forward") }
                .help("Повторить (⇧⌘Z)")
            Button { canvas.saveImage(nil) } label: { Image(systemName: "square.and.arrow.down") }
                .help("Сохранить в файл (⌘S)")
            Button { canvas.copy(nil) } label: { Image(systemName: "doc.on.doc") }
                .help("Скопировать в буфер (⌘C)")
            Button { canvas.showLinkMenu() } label: { Image(systemName: "link") }
                .help("Загрузить и скопировать ссылку")
            Button("Готово") { canvas.finish() }
                .buttonStyle(.borderedProminent)
                .help("Скопировать и закрыть (Return)")
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }
}
