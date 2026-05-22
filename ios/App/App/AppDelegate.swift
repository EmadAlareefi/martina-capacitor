import UIKit
import Capacitor
import UserNotifications
import WebKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate, WKScriptMessageHandler {

    var window: UIWindow?
    private let pushPrefsTokenKey = "MartinaPushToken"
    private let pushRegisterURL = URL(string: "https://www.martina.sa/api/push/register")!

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        logPushRuntimeConfiguration()
        installNativePushBridgeWhenReady()
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Called when the app was launched with a url. Feel free to add additional processing here,
        // but if you want the App API to support tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Called when the app was launched with an activity, including Universal Links.
        // Feel free to add additional processing here, but if you want the App API to support
        // tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

    @objc(application:didRegisterForRemoteNotificationsWithDeviceToken:)
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        NSLog("MartinaPush APNs token received, length \(token.count)")
        savePushToken(token)
        updateWebPushToken(token)
        postPushToken(token)
        NotificationCenter.default.post(
            name: .capacitorDidRegisterForRemoteNotifications,
            object: deviceToken
        )
    }

    @objc(application:didFailToRegisterForRemoteNotificationsWithError:)
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("MartinaPush failed to register for remote notifications: \(error.localizedDescription)")
        NotificationCenter.default.post(
            name: .capacitorDidFailToRegisterForRemoteNotifications,
            object: error
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "MartinaNativePush" else {
            return
        }

        if let body = message.body as? [String: Any],
           body["method"] as? String == "registerPushToken" {
            requestNotificationPermission()
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                NSLog("MartinaPush notification permission request failed: \(error.localizedDescription)")
                return
            }

            if !granted {
                NSLog("MartinaPush notification permission denied")
                return
            }

            DispatchQueue.main.async {
                NSLog("MartinaPush notification permission granted, registering for remote notifications")
                UIApplication.shared.registerForRemoteNotifications()
                self.logRemoteNotificationRegistrationState(after: 2.0)
            }
        }
    }

    private func logRemoteNotificationRegistrationState(after delay: TimeInterval) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSLog(
                    "MartinaPush APNs registration check: isRegistered=\(UIApplication.shared.isRegisteredForRemoteNotifications), authorizationStatus=\(settings.authorizationStatus.rawValue), savedTokenLength=\(self.getSavedPushToken().count)"
                )
            }
        }
    }

    private func logPushRuntimeConfiguration() {
        let bundleId = Bundle.main.bundleIdentifier ?? "missing"
        NSLog("MartinaPush runtime config: bundleId=\(bundleId)")
    }

    private func installNativePushBridgeWhenReady(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else {
                return
            }

            guard let webView = self.capacitorWebView() else {
                if attempt < 20 {
                    self.installNativePushBridgeWhenReady(attempt: attempt + 1)
                }
                return
            }

            let contentController = webView.configuration.userContentController
            contentController.add(self, name: "MartinaNativePush")

            let script = WKUserScript(
                source: self.nativePushBridgeScript(token: self.getSavedPushToken()),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            contentController.addUserScript(script)
            webView.evaluateJavaScript(script.source)
            NSLog("MartinaPush WebView bridge installed")
            self.requestNotificationPermission()
        }
    }

    private func capacitorWebView() -> WKWebView? {
        if let bridgeViewController = window?.rootViewController as? CAPBridgeViewController {
            return bridgeViewController.bridge?.webView
        }

        if let navigationController = window?.rootViewController as? UINavigationController,
           let bridgeViewController = navigationController.viewControllers.first as? CAPBridgeViewController {
            return bridgeViewController.bridge?.webView
        }

        return nil
    }

    private func nativePushBridgeScript(token: String) -> String {
        """
        (function () {
          var token = \(jsonStringLiteral(token));
          window.MartinaNativePush = {
            registerPushToken: function () {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.MartinaNativePush) {
                window.webkit.messageHandlers.MartinaNativePush.postMessage({ method: "registerPushToken" });
              }
            },
            getPushToken: function () {
              return token || "";
            },
            _setPushToken: function (value) {
              token = value || "";
            }
          };
        })();
        """
    }

    private func savePushToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: pushPrefsTokenKey)
    }

    private func getSavedPushToken() -> String {
        UserDefaults.standard.string(forKey: pushPrefsTokenKey) ?? ""
    }

    private func updateWebPushToken(_ token: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let webView = self.capacitorWebView() else {
                return
            }

            webView.evaluateJavaScript(
                """
                window.MartinaNativePush && window.MartinaNativePush._setPushToken(\(self.jsonStringLiteral(token)));
                window.dispatchEvent(new CustomEvent("martina:native-push-token", { detail: { token: \(self.jsonStringLiteral(token)) } }));
                """
            )
        }
    }

    private func postPushToken(_ token: String) {
        var request = URLRequest(url: pushRegisterURL)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = jsonData([
            "token": token,
            "platform": "IOS",
            "locale": "ar-SA",
        ])

        NSLog("MartinaPush posting token to backend")
        attachCookies(to: request) { requestWithCookies in
            URLSession.shared.dataTask(with: requestWithCookies) { data, response, error in
                if let error = error {
                    NSLog("MartinaPush token registration request failed: \(error.localizedDescription)")
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    return
                }

                if !(200..<300).contains(httpResponse.statusCode) {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    NSLog("MartinaPush token registration failed with HTTP \(httpResponse.statusCode): \(body)")
                    return
                }

                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                NSLog("MartinaPush token registered with backend: \(body)")
            }.resume()
        }
    }

    private func attachCookies(to request: URLRequest, completion: @escaping (URLRequest) -> Void) {
        DispatchQueue.main.async { [weak self] in
            var requestWithCookies = request
            guard let self = self,
                  let cookieStore = self.capacitorWebView()?.configuration.websiteDataStore.httpCookieStore else {
                completion(requestWithCookies)
                return
            }

            cookieStore.getAllCookies { cookies in
                let cookieHeader = cookies
                    .filter { $0.domain.hasSuffix("martina.sa") }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")

                if !cookieHeader.isEmpty {
                    requestWithCookies.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                }

                completion(requestWithCookies)
            }
        }
    }

    private func jsonData(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [])
    }

    private func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2 else {
            return "\"\""
        }

        return String(json.dropFirst().dropLast())
    }

}
