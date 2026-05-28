package au.ablz.agentvoice;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.media.AudioManager;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.IBinder;
import android.view.KeyEvent;

public class TriggerService extends Service {
    static final String ACTION_MEDIA_BUTTON = "au.ablz.agentvoice.MEDIA_BUTTON";
    static final String EXTRA_KEY_EVENT = "key_event";

    private static final String CHANNEL_ID = "agent_voice_trigger";
    private static final int NOTIFICATION_ID = 30;

    private MediaSession mediaSession;
    private final AudioManager.OnAudioFocusChangeListener audioFocusListener =
        new AudioManager.OnAudioFocusChangeListener() {
            @Override
            public void onAudioFocusChange(int focusChange) {
            }
        };

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
        startMediaSession();
        requestMediaButtonFocus();
        startForeground(NOTIFICATION_ID, buildNotification());
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_MEDIA_BUTTON.equals(intent.getAction())) {
            KeyEvent event = intent.getParcelableExtra(EXTRA_KEY_EVENT);
            handleKeyEvent(event);
        }
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        if (mediaSession != null) {
            mediaSession.setActive(false);
            mediaSession.release();
        }
        super.onDestroy();
    }

    private void startMediaSession() {
        mediaSession = new MediaSession(this, "AgentVoiceTrigger");
        mediaSession.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS | MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS);
        mediaSession.setCallback(new MediaSession.Callback() {
            @Override
            public boolean onMediaButtonEvent(Intent mediaButtonIntent) {
                KeyEvent event = mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT);
                return handleKeyEvent(event);
            }

            @Override
            public void onPlay() {
                TermuxCommand.run(TriggerService.this);
            }

            @Override
            public void onPause() {
                TermuxCommand.run(TriggerService.this);
            }

            @Override
            public void onSkipToNext() {
                TermuxCommand.run(TriggerService.this);
            }

            @Override
            public void onSkipToPrevious() {
                TermuxCommand.run(TriggerService.this);
            }
        });
        mediaSession.setPlaybackState(new PlaybackState.Builder()
            .setActions(
                PlaybackState.ACTION_PLAY
                    | PlaybackState.ACTION_PAUSE
                    | PlaybackState.ACTION_PLAY_PAUSE
                    | PlaybackState.ACTION_SKIP_TO_NEXT
                    | PlaybackState.ACTION_SKIP_TO_PREVIOUS)
            .setState(PlaybackState.STATE_PLAYING, 0, 1.0f)
            .build());
        mediaSession.setActive(true);
    }

    private boolean handleKeyEvent(KeyEvent event) {
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

    private Notification buildNotification() {
        Notification.Builder builder = Build.VERSION.SDK_INT >= 26
            ? new Notification.Builder(this, CHANNEL_ID)
            : new Notification.Builder(this);

        builder
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Agent voice trigger")
            .setContentText("Listening for headset media buttons")
            .setOngoing(true);

        if (Build.VERSION.SDK_INT >= 21 && mediaSession != null) {
            builder.setStyle(new Notification.MediaStyle()
                .setMediaSession(mediaSession.getSessionToken())
                .setShowActionsInCompactView());
        }

        return builder.build();
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT < 26) {
            return;
        }
        NotificationChannel channel = new NotificationChannel(
            CHANNEL_ID,
            "Agent voice trigger",
            NotificationManager.IMPORTANCE_LOW
        );
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(channel);
    }

    @SuppressWarnings("deprecation")
    private void requestMediaButtonFocus() {
        AudioManager manager = (AudioManager) getSystemService(AUDIO_SERVICE);
        if (manager != null) {
            manager.requestAudioFocus(
                audioFocusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
            );
        }
    }
}
