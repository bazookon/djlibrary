import AppKit
import SwiftUI

@main
struct DJLibraryApp: App {
    @State private var model = LibraryModel()
    @State private var player = Player()

    init() {
        // Al lanzarse con `swift run` no hay bundle: forzamos app normal con ventana y Dock.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("DJ Library") {
            ContentView()
                .environment(model)
                .environment(player)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Guardar cambios") {
                    // El archivo puede reescribirse: soltamos el que está sonando.
                    player.stop()
                    Task { await model.save() }
                }
                    .keyboardShortcut("s")
                    .disabled(model.dirtyCount == 0 || model.isSaving)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
