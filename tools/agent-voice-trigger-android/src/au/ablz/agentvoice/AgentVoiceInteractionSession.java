package au.ablz.agentvoice;

import android.content.Context;
import android.os.Bundle;
import android.service.voice.VoiceInteractionSession;
import android.view.Gravity;
import android.view.View;
import android.widget.TextView;

public class AgentVoiceInteractionSession extends VoiceInteractionSession {
    public AgentVoiceInteractionSession(Context context) {
        super(context);
    }

    @Override
    public void onShow(Bundle args, int showFlags) {
        super.onShow(args, showFlags);
        TermuxCommand.run(getContext());
        finish();
    }

    @Override
    public View onCreateContentView() {
        TextView view = new TextView(getContext());
        view.setGravity(Gravity.CENTER);
        view.setText("Agent voice trigger");
        return view;
    }
}
