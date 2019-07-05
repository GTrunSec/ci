{ cipkgs, nixPath, config }: with cipkgs; let
  prefix = "ci";
  configBasePackages = config.basePackages or { };
  nixConfig = import <nix/config.nix>;
  nixConfigPaths = builtins.mapAttrs (k: v: builtins.storePath (/. + v + "/../..")) {
    # nix appears to expect these to be available in PATH
    inherit (nixConfig) tar gzip xz bzip2 shell;
  };
  inherit (nixConfigPaths) tar gzip bzip2 xz;
  coreutils = builtins.storePath (/. + nixConfig.coreutils + "/..");
  nix = builtins.storePath (/. + nixConfig.nixPrefix);
  runtimeShell = nixConfig.shell;
  cacert = let
    sslCertFile = builtins.getEnv "NIX_SSL_CERT_FILE";
  in if cipkgs.lib.isStorePath sslCertFile
  then builtins.storePath (/. + sslCertFile + "/../../../..")
  else cipkgs.cacert;
  cachix = if (config.cache.cachix or {}) != {}
    then cipkgs.cachix
    else null;
  trivialBuilders =
    # NOTE: older nixpkgs trivial-builders does not accept a runtimeShell argument
    cipkgs.lib.callPackageWith { inherit runtimeShell; } (import (cipkgs.path + "/pkgs/build-support/trivial-builders.nix")) {
      inherit (cipkgs) lib stdenv;
      inherit (cipkgs.xorg) lndir;
      inherit stdenvNoCC;
    };
  stdenvNoCC = with cipkgs.lib; cipkgs.stdenvNoCC.override (old: {
      name = "stdenv-ci";

      cc = null;
      extraNativeBuildInputs = [ ];
      shell = runtimeShell;
      extraAttrs = {
        noCC = true;
      };
      allowedRequisites = null;
      overrides = self: super: { };

      # missing vs standard common path: findutils, diffutils, gnused, gnugrep, gawk, gnumake, patch
      # gawk, patch, gnumake, gnused, gnugrep: only glibc dep, not so bad?
      # findutils+diffutils depend on coreutils for a silly reason...
      initialPath = [ nixConfigPaths.shell coreutils bzip2 gzip tar xz cipkgs.gawk ];
  });
  tools = import ./tools {
    pkgs = {
      callPackage = cipkgs.lib.callPackageWith (cipkgs // {
        inherit nix coreutils runtimeShell;
        substituteAll = cipkgs.substituteAll.override { inherit stdenvNoCC; };
      } // (cipkgs.lib.filterAttrs (_: p: p != null) configBasePackages));
    };
  };
  nixConfigFile = builtins.toFile "nix.conf" ''
    cores = 0
    max-jobs = 8
  '';
  packagesBase = with tools; {
    inherit nix cachix coreutils gzip tar xz bzip2;
    ci-dirty = (ci-dirty.override { inherit runtimeShell; });
    ci-query = (ci-query.override { inherit nix runtimeShell; });
  } // configBasePackages;
  packages = packagesBase // (config.packages or { }); # TODO: turn this into an overlay?
  bin = trivialBuilders.symlinkJoin {
    name = "ci-env-bin";
    paths = builtins.attrValues packagesBase;
  };
  glibcLocales = lib.listToAttrs (map (glibc:
    lib.nameValuePair (builtins.replaceStrings [ "." ] [ "_" ] glibc.version) "${glibc}/lib/locale/locale-archive"
  ) (config.glibcLocales or [ ]));
  envCommon = {
    inherit nix prefix cacert;

    passAsFile = [ "source" "env" ];

    ciRoot = toString ./.;
    nixPathStr = builtins.concatStringsSep ":" (builtins.attrValues (builtins.mapAttrs (k: v: "${k}=${v}") nixPath));
    glibcLocaleVars = lib.optionals hostPlatform.isLinux (lib.mapAttrsToList (name: path:
      "LOCALE_ARCHIVE_${name}=${path}"
    ) glibcLocales);
    env = ''
      ci_env_host() {
        export PATH=$HOST_PATH
      }

      ci_env_nix() {
        export PATH=$CI_PATH
      }

      ci_env_impure() {
        export PATH=$CI_PATH:$HOST_PATH
      }

      if [[ -n ''${CI_PATH-} ]]; then return; fi

      set -euo pipefail # why would you ever not want this by default..?
      ${lib.optionalString (config.closeStdin or false) "exec 0<&-"}

      export NIX_PATH=@nixPathStr@
      export NIX_PREFIX=@nix@
      export HOST_PATH=$PATH
      export CI_PATH=@bin@/bin:@out@/@prefix@/bin
      export CI_ROOT=@ciRoot@
      export NIX_SSL_CERT_FILE=@cacert@/etc/ssl/certs/ca-bundle.crt
      export TERMINFO_DIRS=''${TERMINFO_DIRS-}:/usr/share/terminfo:@bin@/share/terminal
      for locale in @glibcLocaleVars@; do
        export $locale
      done
    '';

    source = ''
      source @out@/@prefix@/env

      ci_env_nix
    '';
  };

  # second stage bootstrap env
  runtimeEnv = trivialBuilders.runCommandNoCC "ci-env-runtime" (envCommon // {
    bin = trivialBuilders.symlinkJoin {
      name = "ci-env-bin-runtime";
      paths = builtins.attrValues packages;
    };
  }) ''
    install -d $out/$prefix/bin
    ln -s $bin $out/bin
    substituteAll $sourcePath $out/$prefix/source
    substituteAll $envPath $out/$prefix/env
  '';

  env = trivialBuilders.runCommandNoCC "ci-env" (envCommon // {
    passAsFile = [ "setup" ] ++ envCommon.passAsFile;

    cachixUse = builtins.attrNames (config.cache.cachix or {});
    inherit (nixConfig) nixSysconfDir;
    allowRoot = config.allowRoot or "";
    inherit runtimeShell nixConfigFile cachix coreutils bin;
    setup = ''
      #!@runtimeShell@
      set -eu

      source @out@/@prefix@/env
      ci_env_impure

      asroot() {
        if [[ ! -w @nixSysconfDir@ && -n "@allowRoot@" ]]; then
          # optionally bring in sudo from cipkgs? setuid is complicated though
          sudo @coreutils@/bin/env PATH="$PATH" NIX_SSL_CERT_FILE=$NIX_SSL_CERT_FILE "$@"
        else
          "$@"
        fi
      }
      asroot @coreutils@/bin/mkdir -p @nixSysconfDir@/nix &&
      asroot @coreutils@/bin/tee -a @nixSysconfDir@/nix/nix.conf < @nixConfigFile@ ||
        echo failed to configure @nixSysconfDir@/nix/nix.conf >&2
      for cachixCache in @cachixUse@; do
        asroot @cachix@/bin/cachix use $cachixCache ||
          echo failed to add cache $cachixCache >&2
      done

      @nix@/bin/nix-build -o $CI_ENV @runtimeDrv@
    '';

    runtimeDrv = builtins.unsafeDiscardStringContext runtimeEnv.drvPath;
  }) ''
    install -d $out/$prefix/bin
    ln -s $bin $out/bin
    substituteAll $setupPath $out/$prefix/setup
    substituteAll $sourcePath $out/$prefix/source
    substituteAll $envPath $out/$prefix/env
    #ln -s $runtimeDrv $out/$prefix/runtimeDrv

    ln -s ../setup $out/$prefix/bin/ci-setup
    chmod +x $out/$prefix/setup
  '';
in env
