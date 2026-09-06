# Fleet retirement deadline, from MongoDB's Server lifecycle table:
# https://www.mongodb.com/legal/support-policy/lifecycles (verified 2026-09-06).
# This is our Community retirement policy, not a commercial support entitlement.
# Pure evaluation: callers supply an ISO UTC date, never builtins.currentTime.
{
  date,
  configurations,
}: let
  endOfLife = "2029-10-31";
  consumers = builtins.filter (name: let
    mongo = configurations.${name}.config.services.mongodb;
  in
    mongo.enable && builtins.match "8\\.0(\\..*)?" mongo.package.version != null)
  (builtins.attrNames configurations);
in
  assert builtins.isString date && builtins.match "[0-9]{4}-[0-9]{2}-[0-9]{2}" date != null;
    if consumers != [] && date > endOfLife
    then
      throw ''
        MongoDB 8.0 EOL VIOLATION: ${builtins.concatStringsSep ", " consumers} still enables MongoDB 8.0 on ${date}; its retirement deadline was ${endOfLife}.
        Migrate the active consumer to a supported MongoDB series after checking UniFi compatibility and taking a tested backup, or disable the consumer. Do not bypass this guard or downgrade binaries against existing data.
        This blocks checks/rolling updates; it does NOT stop the running database.
      ''
    else true
