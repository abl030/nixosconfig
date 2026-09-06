let
  guard = import ../lib/mongodb80-eol.nix;
  consumer = enable: version: {
    doc2.config.services.mongodb = {
      inherit enable;
      package = {inherit version;};
    };
  };
  check = date: enable: version:
    builtins.tryEval (guard {
      inherit date;
      configurations = consumer enable version;
    });
in
  assert (check "2029-10-30" true "8.0.29").success;
  assert (check "2029-10-31" true "8.0.29").success;
  assert !(check "2029-11-01" true "8.0.29").success;
  assert !(check "2030-01-01" true "8.0.99").success;
  assert (check "2029-11-01" false "8.0.29").success;
  assert (check "2029-11-01" true "8.3.8").success;
  assert (guard {
    date = "2029-11-01";
    configurations = {};
  });
  assert !(check "bad-date" true "8.0.29").success; "8 MongoDB EOL boundary/scope cases passed"
