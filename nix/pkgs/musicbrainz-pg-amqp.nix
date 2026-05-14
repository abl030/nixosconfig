{
  clang,
  fetchFromGitHub,
  lib,
  postgresql,
  postgresqlBuildExtension,
}:
postgresqlBuildExtension (_finalAttrs: {
  pname = "musicbrainz-pg-amqp";
  version = "0.4.2-unstable-2024-12-20";

  src = fetchFromGitHub {
    owner = "mwiencek";
    repo = "pg_amqp";
    rev = "51497ac687f16989adff7729a303f9258706f663";
    hash = "sha256-s/KafzK21piCyhEIT2vVm68/Zhn91D4tf2msv1mK54w=";
  };

  makeFlags = ["PG_CPPFLAGS=-Wno-error=implicit-int"];
  nativeBuildInputs = [clang];

  meta = {
    description = "AMQP protocol support for PostgreSQL, pinned for MusicBrainz live indexing";
    homepage = "https://github.com/mwiencek/pg_amqp";
    license = with lib.licenses; [bsdOriginal mpl10];
    platforms = postgresql.meta.platforms;
  };
})
