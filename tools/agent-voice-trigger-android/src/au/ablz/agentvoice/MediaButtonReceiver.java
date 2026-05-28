package au.ablz.agentvoice;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.view.KeyEvent;

public class MediaButtonReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null || !Intent.ACTION_MEDIA_BUTTON.equals(intent.getAction())) {
            return;
        }

        KeyEvent event = intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT);
        Intent service = new Intent(context, TriggerService.class);
        service.setAction(TriggerService.ACTION_MEDIA_BUTTON);
        service.putExtra(TriggerService.EXTRA_KEY_EVENT, event);

        if (Build.VERSION.SDK_INT >= 26) {
            context.startForegroundService(service);
        } else {
            context.startService(service);
        }
    }
}
