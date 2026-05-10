# Render an authorized_keys list that mixes plain strings (legacy) and
# structured entries (Phase 1 of #241).
#
# A structured entry is an attrset:
#   {
#     key         = "ssh-ed25519 AAAA... comment";  # required
#     from        = [ "100.64.0.0/10" "..." ];      # optional, becomes from="..."
#     expiryTime  = "20260901";                     # optional, OpenSSH 9.4+ expiry-time="..."
#     restrict    = false;                          # optional, adds the `restrict` keyword
#     command     = null;                           # optional, force-command="..."
#     extraOptions = [ ];                           # optional, raw extra option strings
#   }
#
# Plain strings are passed through unchanged so existing entries don't have
# to be migrated at once.
#
# Output: list of strings ready for users.users.<u>.openssh.authorizedKeys.keys.
{lib}: let
  renderEntry = entry:
    if builtins.isString entry
    then entry
    else let
      opts =
        lib.optional (entry.from or null != null)
        ''from="${lib.concatStringsSep "," entry.from}"''
        ++ lib.optional (entry.expiryTime or null != null)
        ''expiry-time="${entry.expiryTime}"''
        ++ lib.optional (entry.restrict or false) "restrict"
        ++ lib.optional (entry.command or null != null)
        ''command="${entry.command or ""}"''
        ++ (entry.extraOptions or []);
      prefix =
        if opts == []
        then ""
        else "${lib.concatStringsSep "," opts} ";
    in "${prefix}${entry.key}";
in {
  inherit renderEntry;
  renderList = lib.map renderEntry;
}
