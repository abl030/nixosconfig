{pkgs, ...}: {
  # https://github.com/systemd/systemd/issues/34304#issuecomment-2550498883
  systemd.package =
    pkgs.systemd.overrideAttrs
    (old: {
      patches =
        old.patches
        ++ [
          (pkgs.fetchurl {
            url = "https://github.com/wrvsrx/systemd/compare/tag_fix-hibernate-resume%5E...tag_fix-hibernate-resume.patch";
            hash = "sha256-Z784xysVUOYXCoTYJDRb3ppGiR8CgwY5CNV8jJSLOXU=";
          })
        ];
    });
}
