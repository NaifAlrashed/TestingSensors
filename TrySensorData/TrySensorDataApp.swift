//
//  TrySensorDataApp.swift
//  TrySensorData
//
//  Created by Naif Alrashed on 12/02/2025.
//

import SwiftUI

@main
struct TrySensorDataApp: App {
    @State var sensorManager = SonsorManager()
    var body: some Scene {
        WindowGroup {
            ContentView(sensorManager: sensorManager)
        }
    }
}
