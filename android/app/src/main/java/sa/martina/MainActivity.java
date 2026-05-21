package sa.martina;

import android.Manifest;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.webkit.CookieManager;
import android.webkit.JavascriptInterface;

import com.getcapacitor.BridgeActivity;
import com.google.firebase.messaging.FirebaseMessaging;

import org.json.JSONObject;

import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executors;

public class MainActivity extends BridgeActivity {
    private static final String TAG = "MartinaPush";
    private static final String PUSH_PREFS_NAME = "MartinaPushPrefs";
    private static final String PUSH_TOKEN_KEY = "fcmToken";
    private static final int NOTIFICATION_PERMISSION_REQUEST_CODE = 1001;
    private static final String PUSH_REGISTER_URL = "https://www.martina.sa/api/push/register";

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getBridge().getWebView().addJavascriptInterface(new PushTokenBridge(), "MartinaNativePush");
        requestNotificationPermission();
    }

    private void requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            registerPushToken();
            return;
        }

        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            registerPushToken();
            return;
        }

        requestPermissions(
            new String[] { Manifest.permission.POST_NOTIFICATIONS },
            NOTIFICATION_PERMISSION_REQUEST_CODE
        );
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);

        if (requestCode != NOTIFICATION_PERMISSION_REQUEST_CODE) {
            return;
        }

        if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            registerPushToken();
        } else {
            Log.i(TAG, "Notification permission denied");
        }
    }

    private void registerPushToken() {
        FirebaseMessaging.getInstance().getToken()
            .addOnSuccessListener(token -> {
                Log.i(TAG, "FCM token generated");
                savePushToken(token);
                postPushToken(token);
            })
            .addOnFailureListener(error -> Log.w(TAG, "Failed to get FCM token", error));
    }

    private void savePushToken(String token) {
        getSharedPreferences(PUSH_PREFS_NAME, MODE_PRIVATE)
            .edit()
            .putString(PUSH_TOKEN_KEY, token)
            .apply();
    }

    private String getSavedPushToken() {
        SharedPreferences preferences = getSharedPreferences(PUSH_PREFS_NAME, MODE_PRIVATE);
        return preferences.getString(PUSH_TOKEN_KEY, "");
    }

    private void postPushToken(String token) {
        Executors.newSingleThreadExecutor().execute(() -> {
            HttpURLConnection connection = null;
            try {
                JSONObject payload = new JSONObject();
                payload.put("token", token);
                payload.put("platform", "ANDROID");
                payload.put("locale", "ar-SA");

                byte[] body = payload.toString().getBytes(StandardCharsets.UTF_8);
                URL url = new URL(PUSH_REGISTER_URL);
                connection = (HttpURLConnection) url.openConnection();
                connection.setRequestMethod("POST");
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
                connection.setRequestProperty("Accept", "application/json");
                String cookies = CookieManager.getInstance().getCookie(PUSH_REGISTER_URL);
                if (cookies != null && !cookies.isBlank()) {
                    connection.setRequestProperty("Cookie", cookies);
                }
                connection.setDoOutput(true);
                connection.setConnectTimeout(10000);
                connection.setReadTimeout(10000);

                try (OutputStream outputStream = connection.getOutputStream()) {
                    outputStream.write(body);
                }

                int responseCode = connection.getResponseCode();
                if (responseCode >= 200 && responseCode < 300) {
                    Log.i(TAG, "Push token registered");
                } else {
                    Log.w(TAG, "Push token registration failed with HTTP " + responseCode);
                }
            } catch (Exception error) {
                Log.w(TAG, "Push token registration request failed", error);
            } finally {
                if (connection != null) {
                    connection.disconnect();
                }
            }
        });
    }

    private class PushTokenBridge {
        @JavascriptInterface
        public void registerPushToken() {
            Log.i(TAG, "Push token registration requested from WebView");
            MainActivity.this.registerPushToken();
        }

        @JavascriptInterface
        public String getPushToken() {
            return MainActivity.this.getSavedPushToken();
        }
    }
}
