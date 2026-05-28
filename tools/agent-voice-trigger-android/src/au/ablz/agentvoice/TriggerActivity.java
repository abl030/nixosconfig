package au.ablz.agentvoice;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

public class TriggerActivity extends Activity {
    private static final int PERMISSION_REQUEST = 1001;
    private static final String TERMUX_RUN_COMMAND_PERMISSION = "com.termux.permission.RUN_COMMAND";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        requestNeededPermissions();
        startTriggerService();
        maybeTriggerFromAssistIntent(getIntent());
        setContentView(buildView());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        maybeTriggerFromAssistIntent(intent);
    }

    private LinearLayout buildView() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        int pad = dp(20);
        root.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText("Agent Voice Trigger");
        title.setTextSize(24);
        title.setGravity(Gravity.CENTER);
        root.addView(title, new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ));

        TextView body = new TextView(this);
        body.setText("Leave this listener running. The app button works now. Headset play/pause is unreliable on Android; use a headset assistant gesture or dedicated button if available.");
        body.setTextSize(16);
        body.setPadding(0, dp(16), 0, dp(16));
        root.addView(body, new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ));

        Button run = new Button(this);
        run.setText("Trigger Now");
        run.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                TermuxCommand.run(TriggerActivity.this);
            }
        });
        root.addView(run, new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ));

        Button settings = new Button(this);
        settings.setText("Open App Settings");
        settings.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                Intent intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
                intent.setData(Uri.parse("package:" + getPackageName()));
                startActivity(intent);
            }
        });
        root.addView(settings, new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ));

        Button accessibility = new Button(this);
        accessibility.setText("Open Accessibility Settings");
        accessibility.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS));
            }
        });
        root.addView(accessibility, new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ));

        Button assistant = new Button(this);
        assistant.setText("Open Default Apps");
        assistant.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                startActivity(new Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS));
            }
        });
        root.addView(assistant, new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ));

        return root;
    }

    private void maybeTriggerFromAssistIntent(Intent intent) {
        if (intent == null) {
            return;
        }

        String action = intent.getAction();
        if (Intent.ACTION_ASSIST.equals(action) || Intent.ACTION_VOICE_COMMAND.equals(action)) {
            TermuxCommand.run(this);
        }
    }

    private void requestNeededPermissions() {
        if (Build.VERSION.SDK_INT < 23) {
            return;
        }
        if (checkSelfPermission(TERMUX_RUN_COMMAND_PERMISSION) == PackageManager.PERMISSION_GRANTED
            && (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)) {
            return;
        }

        if (Build.VERSION.SDK_INT >= 33) {
            requestPermissions(new String[] {
                TERMUX_RUN_COMMAND_PERMISSION,
                Manifest.permission.POST_NOTIFICATIONS
            }, PERMISSION_REQUEST);
        } else {
            requestPermissions(new String[] {
                TERMUX_RUN_COMMAND_PERMISSION
            }, PERMISSION_REQUEST);
        }
    }

    private void startTriggerService() {
        Intent intent = new Intent(this, TriggerService.class);
        if (Build.VERSION.SDK_INT >= 26) {
            startForegroundService(intent);
        } else {
            startService(intent);
        }
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
