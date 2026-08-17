import ActivityKit
import SwiftUI
import WidgetKit

// TEMPORARY LIVE ACTIVITY/BACKGROUND BLE DIAGNOSTICS: Remove after iOS testing.
@main
struct ScrbrdLiveActivityWidgetBundle: WidgetBundle {
  var body: some Widget {
    ScrbrdLiveActivityWidget()
  }
}

// TEMPORARY LIVE ACTIVITY/BACKGROUND BLE DIAGNOSTICS: Remove after iOS testing.
struct ScrbrdLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: ScrbrdActivityAttributes.self) { context in
      Text(context.state.status)
        .font(.headline)
        .padding()
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.center) {
          Text(context.state.status)
        }
      } compactLeading: {
        Text("S")
      } compactTrailing: {
        Text("BLE")
      } minimal: {
        Text("S")
      }
    }
  }
}
