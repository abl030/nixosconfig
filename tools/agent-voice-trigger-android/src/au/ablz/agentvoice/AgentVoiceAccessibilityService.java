package au.ablz.agentvoice;

import android.accessibilityservice.AccessibilityService;
import android.view.KeyEvent;
import android.view.accessibility.AccessibilityEvent;

public class AgentVoiceAccessibilityService extends AccessibilityService {
    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
    }

    @Override
    public void onInterrupt() {
    }

    @Override
    protected boolean onKeyEvent(KeyEvent event) {
        if (event == null || event.getAction() != KeyEvent.ACTION_DOWN || event.getRepeatCount() > 0) {
            return false;
        }

        int code = event.getKeyCode();
        if (code == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
            || code == KeyEvent.KEYCODE_MEDIA_PLAY
            || code == KeyEvent.KEYCODE_MEDIA_PAUSE
            || code == KeyEvent.KEYCODE_HEADSETHOOK
            || code == KeyEvent.KEYCODE_MEDIA_NEXT
            || code == KeyEvent.KEYCODE_MEDIA_PREVIOUS) {
            TermuxCommand.run(this);
            return true;
        }
        return false;
    }
}
