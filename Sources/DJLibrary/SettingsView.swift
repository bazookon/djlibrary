import AppKit
import DJCore
import SwiftUI

struct SettingsView: View {
    @Environment(LibraryModel.self) private var model
    @AppStorage("libraryRoot") private var libraryRoot = EngineDatabase.defaultLibraryRoot.path
    @AppStorage("writeFileTags") private var writeFileTags = true

    var body: some View {
        Form {
            Section("Biblioteca de Engine DJ") {
                LabeledContent("Carpeta") {
                    HStack {
                        Text(libraryRoot).lineLimit(1).truncationMode(.middle)
                        Button("Elegir…") {
                            if let url = pick(directory: true) {
                                libraryRoot = url.path
                                model.load()
                            }
                        }
                    }
                }
                Toggle("Escribir también los tags en los archivos (ID3 / M4A)", isOn: $writeFileTags)
            }
            Section("Mi logo") {
                HStack(spacing: 16) {
                    if let data = model.logoJPEG, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 96, height: 96)
                            .overlay(Text("Sin logo").font(.caption))
                    }
                    Button("Elegir imagen…") {
                        if let url = pick(directory: false) { model.chooseLogo(url) }
                    }
                }
                Text("Se convierte a JPEG cuadrado de 600×600 con fondo negro.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private func pick(directory: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        if !directory { panel.allowedContentTypes = [.image] }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
