import ActivityKit
import Foundation

// TEMPORARY LIVE ACTIVITY/BACKGROUND BLE DIAGNOSTICS: Remove after iOS testing.
@available(iOS 16.1, *)
struct ScrbrdActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var status: String
  }

  var name: String
}
