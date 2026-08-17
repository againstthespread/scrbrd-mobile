import ActivityKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UIApplication.shared.registerForRemoteNotifications()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    print("APNs device token: \(token)")
    super.application(
      application,
      didRegisterForRemoteNotificationsWithDeviceToken: deviceToken
    )
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    print("APNs registration failed: \(String(reflecting: error))")
    super.application(
      application,
      didFailToRegisterForRemoteNotificationsWithError: error
    )
  }

  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    print("Background remote notification payload: \(userInfo)")
    completionHandler(.newData)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // TEMPORARY LIVE ACTIVITY/BACKGROUND BLE DIAGNOSTICS: Remove after iOS testing.
    let channel = FlutterMethodChannel(
      name: "com.againstthespread.scrbrd/live_activity_diagnostics",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      self.handleLiveActivityDiagnostic(call: call, result: result)
    }
  }

  // TEMPORARY LIVE ACTIVITY/BACKGROUND BLE DIAGNOSTICS: Remove after iOS testing.
  private func handleLiveActivityDiagnostic(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard #available(iOS 16.1, *) else {
      result(
        FlutterError(
          code: "live_activity_unavailable",
          message: "Live Activities require iOS 16.1 or newer.",
          details: nil
        )
      )
      return
    }

    switch call.method {
    case "startScrbrdLiveActivity":
      startScrbrdLiveActivity(result: result)
    case "endScrbrdLiveActivity":
      endScrbrdLiveActivity(result: result)
    case "isScrbrdLiveActivityActive":
      let isActive = !Activity<ScrbrdActivityAttributes>.activities.isEmpty
      print("TEMP LIVE ACTIVITY DIAGNOSTIC: active=\(isActive)")
      result(isActive)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // TEMPORARY LIVE ACTIVITY/BACKGROUND BLE DIAGNOSTICS: Remove after iOS testing.
  @available(iOS 16.1, *)
  private func startScrbrdLiveActivity(result: @escaping FlutterResult) {
    print("TEMP LIVE ACTIVITY DIAGNOSTIC: start attempt")

    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      let message = "Live Activities are disabled on this device."
      print("TEMP LIVE ACTIVITY DIAGNOSTIC: start failed: \(message)")
      result(
        FlutterError(
          code: "live_activity_disabled",
          message: message,
          details: nil
        )
      )
      return
    }

    if let activity = Activity<ScrbrdActivityAttributes>.activities.first {
      print(
        "TEMP LIVE ACTIVITY DIAGNOSTIC: already active; Activity ID=\(activity.id)"
      )
      result(activity.id)
      return
    }

    do {
      let activity = try Activity.request(
        attributes: ScrbrdActivityAttributes(name: "SCRBRD"),
        contentState: ScrbrdActivityAttributes.ContentState(
          status: "SCRBRD Active"
        ),
        pushType: nil
      )
      print(
        "TEMP LIVE ACTIVITY DIAGNOSTIC: successfully started; Activity ID=\(activity.id)"
      )
      result(activity.id)
    } catch {
      print(
        "TEMP LIVE ACTIVITY DIAGNOSTIC: start failed: \(String(reflecting: error))"
      )
      result(
        FlutterError(
          code: "live_activity_start_failed",
          message: "Unable to start the SCRBRD Live Activity.",
          details: String(reflecting: error)
        )
      )
    }
  }

  // TEMPORARY LIVE ACTIVITY/BACKGROUND BLE DIAGNOSTICS: Remove after iOS testing.
  @available(iOS 16.1, *)
  private func endScrbrdLiveActivity(result: @escaping FlutterResult) {
    let activities = Activity<ScrbrdActivityAttributes>.activities
    Task { @MainActor in
      for activity in activities {
        await activity.end(
          using: ScrbrdActivityAttributes.ContentState(status: "SCRBRD Ended"),
          dismissalPolicy: .immediate
        )
        print(
          "TEMP LIVE ACTIVITY DIAGNOSTIC: ended; Activity ID=\(activity.id)"
        )
      }
      if activities.isEmpty {
        print("TEMP LIVE ACTIVITY DIAGNOSTIC: end requested; no activity active")
      }
      result(nil)
    }
  }
}
