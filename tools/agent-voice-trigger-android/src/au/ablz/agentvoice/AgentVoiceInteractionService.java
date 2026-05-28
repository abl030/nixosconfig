package au.ablz.agentvoice;

import android.os.Bundle;
import android.service.voice.VoiceInteractionService;
import android.service.voice.VoiceInteractionSession;

public class AgentVoiceInteractionService extends VoiceInteractionService {
    @Override
    public void onLaunchVoiceAssistFromKeyguard() {
        showSession(new Bundle(), VoiceInteractionSession.SHOW_WITH_ASSIST);
    }
}
