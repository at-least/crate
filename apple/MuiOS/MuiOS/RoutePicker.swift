import AVKit
import SwiftUI

/// AirPlay 路由選擇器（C3：Control Center 之外的顯式入口）。
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor.label
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
