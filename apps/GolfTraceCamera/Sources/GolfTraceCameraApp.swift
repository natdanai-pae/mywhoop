import SwiftUI

@main
struct GolfTraceCameraApp: App {
  @StateObject private var camera = CameraService()

  var body: some Scene {
    WindowGroup {
      ContentView(camera: camera)
        .preferredColorScheme(.dark)
    }
  }
}
