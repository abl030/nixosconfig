# Real-time audio scheduling for the interactive desktop user.
#
# Moonlight (the game-stream client) raises its audio thread to a high priority
# for glitch-free playback. With the stock rtprio/nice ceilings of 0 that request
# fails — Moonlight logs:
#   "Unable to set audio thread to high priority: setpriority() failed"
# — so the audio thread stays preemptible and audio stutters/crackles under load
# while streaming (video stays smooth). Granting the login user a real-time
# scheduling ceiling lets the audio thread hold priority.
#
# rtkit is already enabled on these hosts; this adds the PAM rlimit ceilings that
# SDL's pthread_setschedparam (rtprio) and its setpriority (nice) fallback need.
# Shared by the Linux Moonlight clients (epi, framework). The blast radius is a
# personal single-user workstation, so @users (== the interactive user) is fine.
#
# See docs/wiki/services/apollo-gaming-vm.md — "audio stutter" section.
{...}: {
  security.pam.loginLimits = [
    {
      domain = "@users";
      type = "-";
      item = "rtprio";
      value = "95";
    }
    {
      domain = "@users";
      type = "-";
      item = "nice";
      value = "-15";
    }
  ];
}
