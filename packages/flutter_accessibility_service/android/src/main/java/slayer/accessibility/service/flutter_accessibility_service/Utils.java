package slayer.accessibility.service.flutter_accessibility_service;

import static android.content.Context.MODE_PRIVATE;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.text.TextUtils;
import android.view.accessibility.AccessibilityNodeInfo;

import androidx.annotation.RequiresApi;

import org.json.JSONObject;

import java.util.HashMap;

public class Utils {

    public static boolean isAccessibilitySettingsOn(Context mContext) {
        int accessibilityEnabled = 0;
        // Match ANY accessibility service belonging to this package — supports subclasses
        // such as RoadMateAccessibilityService that extend AccessibilityListener.
        final String packagePrefix = mContext.getPackageName() + "/";
        try {
            accessibilityEnabled = Settings.Secure.getInt(mContext.getApplicationContext().getContentResolver(), android.provider.Settings.Secure.ACCESSIBILITY_ENABLED);
        } catch (Settings.SettingNotFoundException e) {
            return false;
        }
        TextUtils.SimpleStringSplitter mStringColonSplitter = new TextUtils.SimpleStringSplitter(':');
        if (accessibilityEnabled == 1) {
            String settingValue = Settings.Secure.getString(mContext.getApplicationContext().getContentResolver(), Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
            if (settingValue != null) {
                mStringColonSplitter.setString(settingValue);
                while (mStringColonSplitter.hasNext()) {
                    String accessibilityService = mStringColonSplitter.next();
                    if (accessibilityService.toLowerCase().startsWith(packagePrefix.toLowerCase())) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    /**
     * Returns the fully-qualified class name of the enabled accessibility service for this
     * package (e.g. "com.example.road_mate_flutter.RoadMateAccessibilityService").
     * Falls back to AccessibilityListener if none is found.
     */
    public static String getEnabledServiceClass(Context mContext) {
        final String packagePrefix = mContext.getPackageName() + "/";
        String settingValue = Settings.Secure.getString(
                mContext.getApplicationContext().getContentResolver(),
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        if (settingValue != null) {
            TextUtils.SimpleStringSplitter splitter = new TextUtils.SimpleStringSplitter(':');
            splitter.setString(settingValue);
            while (splitter.hasNext()) {
                String service = splitter.next();
                if (service.toLowerCase().startsWith(packagePrefix.toLowerCase())) {
                    int slash = service.indexOf('/');
                    if (slash >= 0 && slash < service.length() - 1) {
                        return service.substring(slash + 1);
                    }
                }
            }
        }
        return AccessibilityListener.class.getCanonicalName();
    }

    @RequiresApi(api = Build.VERSION_CODES.JELLY_BEAN_MR2)
    static AccessibilityNodeInfo findNode(AccessibilityNodeInfo nodeInfo, String nodeId) {
        if (nodeInfo.getViewIdResourceName() != null && nodeInfo.getViewIdResourceName().equals(nodeId)) {
            return nodeInfo;
        }
        for (int i = 0; i < nodeInfo.getChildCount(); i++) {
            AccessibilityNodeInfo child = nodeInfo.getChild(i);
            AccessibilityNodeInfo result = findNode(child, nodeId);
            if (result != null) {
                return result;
            }
        }
        return null;
    }

    @RequiresApi(api = Build.VERSION_CODES.JELLY_BEAN_MR2)
    static AccessibilityNodeInfo findNodeByText(AccessibilityNodeInfo nodeInfo, String text) {
        if (nodeInfo.getText() != null && nodeInfo.getText().equals(text)) {
            return nodeInfo;
        }
        for (int i = 0; i < nodeInfo.getChildCount(); i++) {
            AccessibilityNodeInfo child = nodeInfo.getChild(i);
            AccessibilityNodeInfo result = findNodeByText(child, text);
            if (result != null) {
                return result;
            }
        }
        return null;
    }


    @RequiresApi(api = Build.VERSION_CODES.LOLLIPOP)
    static Bundle bundleIdentifier(Integer actionType, Object extra) {
        Bundle arguments = new Bundle();
        if (extra == null) return null;
        if (actionType == AccessibilityNodeInfo.ACTION_SET_TEXT) {
            arguments.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, (String) extra);
        } else if (actionType == AccessibilityNodeInfo.ACTION_NEXT_AT_MOVEMENT_GRANULARITY) {
            arguments.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT, AccessibilityNodeInfo.MOVEMENT_GRANULARITY_CHARACTER);
            arguments.putBoolean(AccessibilityNodeInfo.ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN, (Boolean) extra);
        } else if (actionType == AccessibilityNodeInfo.ACTION_NEXT_HTML_ELEMENT) {
            arguments.putString(AccessibilityNodeInfo.ACTION_ARGUMENT_HTML_ELEMENT_STRING, (String) extra);
        } else if (actionType == AccessibilityNodeInfo.ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY) {
            arguments.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT, AccessibilityNodeInfo.MOVEMENT_GRANULARITY_CHARACTER);
            arguments.putBoolean(AccessibilityNodeInfo.ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN, (Boolean) extra);
        } else if (actionType == AccessibilityNodeInfo.ACTION_PREVIOUS_HTML_ELEMENT) {
            arguments.putString(AccessibilityNodeInfo.ACTION_ARGUMENT_HTML_ELEMENT_STRING, (String) extra);
        } else if (actionType == AccessibilityNodeInfo.ACTION_SET_SELECTION) {
            HashMap<String, Integer> map = (HashMap<String, Integer>) extra;
            arguments.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, map.get("start"));
            arguments.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, map.get("end"));
        } else {
            arguments = null;
        }
        return arguments;
    }
}
