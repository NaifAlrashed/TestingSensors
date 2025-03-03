//
//  ContentView.swift
//  TrySensorData
//
//  Created by Naif Alrashed on 12/02/2025.
//

import CoreLocation
import CoreMotion
import Foundation
import SwiftUI
import MapKit
import GLKit

struct ContentView: View {
    @Bindable var sensorManager: SonsorManager
    var body: some View {
        Map(position: $sensorManager.lastLocation)
            .overlay(alignment: .bottom) {
                VStack {
                    if let speed = sensorManager.speed {
                        Text(
                            "\(measuremrntFormatter.string(from: speed.converted(to: .kilometersPerHour)))"
                        )
                    }
                    Button(
                        sensorManager.enableLocationTracking ? "disable location tracking": "enable location tracking"
                    ) {
                        sensorManager.enableLocationTracking.toggle()
                    }
                }
            }
    }
}

#Preview {
    ContentView(sensorManager: SonsorManager())
}
let measuremrntFormatter = MeasurementFormatter()

@Observable
final class SonsorManager: NSObject {
    private let locationManager = CLLocationManager()
    private let coreMotionManager = CMMotionManager()
    var enableLocationTracking = true {
        didSet {
            if enableLocationTracking {
                locationManager.startUpdatingLocation()
            } else {
                locationManager.stopUpdatingLocation()
            }
        }
    }
    private(set) var speed: Measurement<UnitSpeed>?
    private var lock = NSLock()
    private var data: [SensorData] = [] {
        didSet {
            if let lastSensorData = data.last, let location = lastSensorData.location {
                lastLocation = .item(.init(placemark: .init(coordinate: CLLocationCoordinate2D(
                    latitude: location.latitude,
                    longitude: location.longitude
                ))))
            }
        }
    }
    private var lastKnownLocation: CLLocation?
    private var lastKnownHeading: CLHeading?
    var lastLocation: MapCameraPosition = .automatic

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.startUpdatingHeading()
        coreMotionManager.deviceMotionUpdateInterval = 0.1
        coreMotionManager.startDeviceMotionUpdates(
            using: .xTrueNorthZVertical,
            to: .main
        ) { motion, error in
            if let error {
                print("error in AccelerometerUpdates: \(error)")
            }
            guard let motion else { return }
            print(
                "device true north angle (yaw): \(motion.attitude.yaw), pitch: \(motion.attitude.pitch), roll: \(motion.attitude.roll)"
            )
            print("rotation: \(motion.attitude.rotationMatrix)")
            let rotationMatrix = motion.attitude.rotationMatrix
            let userAcceleration = motion.userAcceleration
            let userAccelerationDirectedAtTrueNorth = Vector(
                x: ((rotationMatrix.m11 * userAcceleration.x) + (rotationMatrix.m12 * userAcceleration.y) + (rotationMatrix.m13 * userAcceleration.z)),
                y: (rotationMatrix.m21 * userAcceleration.x) + (rotationMatrix.m22 * userAcceleration.y) + (rotationMatrix.m23 * userAcceleration.z),
                z: (rotationMatrix.m31 * userAcceleration.x) + (rotationMatrix.m32 * userAcceleration.y) + (rotationMatrix.m33 * userAcceleration.z),
                unit: UnitAcceleration.metersPerSecondSquared
            )
            let currentTimestamp = Date().timeIntervalSince1970
            if let lastKnownLocation = self.lastKnownLocation {
                let (speed, newLocation) = userAccelerationDirectedAtTrueNorth.calculateSpeed(
                    prevCoordinate: lastKnownLocation.ourCoordinate,
                    deltaTime: self.coreMotionManager.deviceMotionUpdateInterval,
                    currentTimestamp: currentTimestamp
                )
                self.speed = speed
                self.data.append(SensorData(
                    timeStamp: currentTimestamp,
                    location: newLocation,
                    acceleration: userAccelerationDirectedAtTrueNorth,
                    heading: nil
                ))
            } else {
                self.data.append(SensorData(
                    timeStamp: currentTimestamp,
                    location: nil,
                    acceleration: userAccelerationDirectedAtTrueNorth,
                    heading: nil
                ))
            }
            print("accelerometerData: \(motion)")
        }
    }
}
struct SensorData: Codable {
    let timeStamp: TimeInterval
    let location: Coordinate?
    let acceleration: Vector<UnitAcceleration>?
    let heading: Double?
}

struct Coordinate: Codable {
    let latitude: Double
    let longitude: Double
    let speed: Measurement<UnitSpeed>
    let course: CLLocationDirection
    let timestamp: TimeInterval
}

struct Vector<UnitType: Unit>: Codable {
    let x: Measurement<UnitType>
    let y: Measurement<UnitType>
    let z: Measurement<UnitType>

    init(x: Double, y: Double, z: Double, unit: UnitType) {
        self.x = .init(value: x, unit: unit)
        self.y = .init(value: y, unit: unit)
        self.z = .init(value: z, unit: unit)
    }

    func calculateSpeed(
        prevCoordinate: Coordinate,
        deltaTime: TimeInterval,
        currentTimestamp: TimeInterval
    ) -> (Measurement<UnitSpeed>, Coordinate) {
        let acceleration = Vector<UnitAcceleration>(
            x: y.value * 9.81,
            y: x.value * 9.81,
            z: z.value * 9.81,
            unit: UnitAcceleration.metersPerSecondSquared
        )
        print(
            "acceleration x: \(measuremrntFormatter.string(from: acceleration.x)), acceleration y: \(measuremrntFormatter.string(from: acceleration.y))"
        )
        let prevVelocityCourseRadians = prevCoordinate.course * .pi / 180
        let prevVelocity = if prevCoordinate.speed.value != -1 {
            Vector<UnitSpeed>(
                x: sin(prevVelocityCourseRadians),
                y: cos(prevVelocityCourseRadians),
                z: prevCoordinate.speed.value,
                unit: prevCoordinate.speed.unit
            )
        } else {
            Vector<UnitSpeed>(
                x: 0,
                y: 0,
                z: 0,
                unit: UnitSpeed.metersPerSecond
            )
        }
        /// since the coordinate system for core motion has it so x is true north
        /// But We want to make it so that y is true north
        /// That is why we are converting here
        let newVelocityFromStandingX = Measurement(
            value: acceleration.y.value * deltaTime,
            unit: UnitSpeed.metersPerSecond
        )
        let newVelocityFromStandingY = Measurement(
            value: acceleration.x.value * deltaTime,
            unit: UnitSpeed.metersPerSecond
        )
        let newVelocityX = (newVelocityFromStandingX + prevVelocity.x)
            .converted(to: .metersPerSecond)
        let newVelocityY = (newVelocityFromStandingY + prevVelocity.y)
            .converted(to: .metersPerSecond)
        let speed = Measurement(
            value: sqrt((newVelocityX.value * newVelocityX.value) + (newVelocityY.value * newVelocityY.value)),
            unit: UnitSpeed.metersPerSecond
        )
        let newCourseInRadians = atan2l(newVelocityY.value, newVelocityX.value)
        let newCourse = newCourseInRadians * 180 / .pi
        print("course is: \(newCourse), and in radians is: \(newCourseInRadians)")
        print("speed is: \(speed)")
        let R: Double = 6378137 // Earth's radius in meters

        let deltaDistanceYInMeters = newVelocityY.value * deltaTime
        let deltaDistanceXInMeters = newVelocityX.value * deltaTime

        let longitudeInRadians = prevCoordinate.longitude * .pi / 180

        let deltaLatitudeInRadians = deltaDistanceXInMeters / R//(deltaDistanceXInMeters / R) * (180 / .pi)
        let deltaLatitude = deltaLatitudeInRadians * 180 / .pi

        let deltaLongitudeInRadians = deltaDistanceYInMeters / R * cos(longitudeInRadians)
        let deltaLongitude = deltaLongitudeInRadians * 180 / .pi

        // Convert back to degrees
        let latitude = prevCoordinate.latitude + deltaLatitude
        let longitude = prevCoordinate.longitude + deltaLongitude

        let location = Coordinate(
            latitude: latitude,
            longitude: longitude,
            speed: speed,
            course: newCourse,
            timestamp: currentTimestamp
        )
        return (speed, location)
    }
}

extension SonsorManager: CLLocationManagerDelegate {
    func locationManager(
        _ manager: CLLocationManager,
        didUpdateHeading newHeading: CLHeading
    ) {
        lastKnownHeading = newHeading
        data.append(SensorData(
            timeStamp: newHeading.timestamp.timeIntervalSince1970,
            location: nil,
            acceleration: nil,
            heading: newHeading.trueHeading
        ))
        print("location manager heading updated to: \(newHeading)")
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        print("did update locations to: \(locations)")
        guard let location = locations.last else { return }
        lastKnownLocation = location
        data.append(SensorData(
            timeStamp: location.timestamp.timeIntervalSince1970,
            location: location.ourCoordinate,
            acceleration: nil,
            heading: nil
        ))
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: any Error
    ) {
        print("did fail with error: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        print("did change authorization to \(manager.authorizationStatus)")
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }
}

extension CLLocation {
    var ourCoordinate: Coordinate {
        let speed = Measurement(value: speed, unit: UnitSpeed.metersPerSecond)
        print("raw speed: \(measuremrntFormatter.string(from: speed))")
        return .init(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            speed: speed,
            course: course,
            timestamp: timestamp.timeIntervalSince1970
        )
    }
}
