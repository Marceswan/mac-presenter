import SwiftUI

struct PresentationLibraryView: View {
    @Environment(PrompterModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Presentation Library")
                .font(.title2.bold())
            Text("Saved on this Mac. Select a presentation to continue editing or presenting.")
                .foregroundStyle(.secondary)

            List(model.presentations, selection: $selection) { presentation in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(presentation.title).font(.headline).lineLimit(1)
                        if presentation.id == model.currentPresentationID {
                            Text("Current").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(presentation.updatedAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(presentation.text.isEmpty ? "Empty presentation" : String(presentation.text.prefix(160)).replacingOccurrences(of: "\n", with: " "))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 4)
                .tag(presentation.id)
                .onTapGesture(count: 2) { model.openPresentation(presentation.id) }
            }
            .accessibilityLabel("Saved presentations")

            HStack {
                Text("\(model.presentations.count) saved")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open Presentation") {
                    if let selection { model.openPresentation(selection) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 580, idealWidth: 660, minHeight: 380, idealHeight: 460)
        .onAppear { selection = model.currentPresentationID }
    }
}
