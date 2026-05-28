package au.ablz.agentvoice;

import android.content.Context;
import android.content.Intent;
import android.widget.Toast;

final class TermuxCommand {
    private static final String TERMUX_PACKAGE = "com.termux";
    private static final String TERMUX_RUN_COMMAND_SERVICE = "com.termux.app.RunCommandService";
    private static final String ACTION_RUN_COMMAND = "com.termux.RUN_COMMAND";
    private static final String EXTRA_COMMAND_PATH = "com.termux.RUN_COMMAND_PATH";
    private static final String EXTRA_WORKDIR = "com.termux.RUN_COMMAND_WORKDIR";
    private static final String EXTRA_BACKGROUND = "com.termux.RUN_COMMAND_BACKGROUND";
    private static final String EXTRA_COMMAND_LABEL = "com.termux.RUN_COMMAND_LABEL";

    private static final String TERMUX_HOME = "/data/data/com.termux/files/home";
    private static final String SCRIPT_PATH = TERMUX_HOME + "/.local/share/agent-voice-input/agent-voice-input-termux.sh";

    private TermuxCommand() {
    }

    static void run(Context context) {
        Intent intent = new Intent(ACTION_RUN_COMMAND);
        intent.setClassName(TERMUX_PACKAGE, TERMUX_RUN_COMMAND_SERVICE);
        intent.putExtra(EXTRA_COMMAND_PATH, SCRIPT_PATH);
        intent.putExtra(EXTRA_WORKDIR, TERMUX_HOME);
        intent.putExtra(EXTRA_BACKGROUND, true);
        intent.putExtra(EXTRA_COMMAND_LABEL, "Agent voice input");

        try {
            context.startService(intent);
            Toast.makeText(context, "Agent voice trigger", Toast.LENGTH_SHORT).show();
        } catch (RuntimeException e) {
            Toast.makeText(context, "Could not run Termux command", Toast.LENGTH_LONG).show();
        }
    }
}
