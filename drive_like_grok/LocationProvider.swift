//
//  LocationProvider.swift
//  drive_like_grok
//
//  获取当前定位，供路线规划时作为「周围」参考（如「最近的麦当劳」）。
//

import CoreLocation
import Foundation

@MainActor
final class LocationProvider: NSObject, ObservableObject {
    private let manager = CLLocationManager()
    
    /// 当前坐标（nil 表示未授权或尚未获取到）
    @Published private(set) var currentCoordinate: CLLocationCoordinate2D?
    /// 定位进行中
    @Published private(set) var isRequesting = false
    /// 定位错误信息（如权限被拒）
    @Published private(set) var errorMessage: String?
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }
    
    /// 请求「使用期间」定位并获取一次当前位置
    func requestLocation() {
        errorMessage = nil
        isRequesting = true
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }
    
    private func finish(with coordinate: CLLocationCoordinate2D?) {
        currentCoordinate = coordinate
        isRequesting = false
    }
    
    private func finish(with error: String) {
        errorMessage = error
        currentCoordinate = nil
        isRequesting = false
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            finish(with: loc.coordinate)
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message: String
        if let clErr = error as? CLError, clErr.code == .denied {
            message = "未获得定位权限，将不传位置给 AI"
        } else {
            message = error.localizedDescription
        }
        Task { @MainActor in
            finish(with: message)
        }
    }
}
