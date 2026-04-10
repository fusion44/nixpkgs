{
  lib,
  stdenv,
  callPackage,
  runCommand,
  writeText,
  pub2nix,
  dartHooks,
  makeWrapper,
  dart,
  nodejs,
  darwin,
  jq,
  yq,
}:

let
  # Arguments consumed by buildDartApplication itself; they are excluded
  # from the arguments forwarded to mkDerivation.
  removedDrvArgNames = [
    "gitHashes"
    "sdkSourceBuilders"
    "pubspecLock"
    "pubspecLockPackageFilter"
    "customSourceBuilders"
    "workspaceMembers"
    "workspaceMember"
    "workspaceDependencyGraph"
    "workspaceDependencyClosure"
    "workspaceIncludeDevDependencies"
  ];
in
lib.extendMkDerivation {
  constructDrv = stdenv.mkDerivation;

  excludeDrvArgNames = removedDrvArgNames;

  extendDrvArgs =
    finalAttrs:
    args@{
      src,
      sourceRoot ? "source",
      packageRoot ? (lib.removePrefix "/" (lib.removePrefix "source" sourceRoot)),
      gitHashes ? { },
      sdkSourceBuilders ? { },
      customSourceBuilders ? { },
      pubspecLockPackageFilter ? _name: _details: true,
      workspaceMembers ? null,
      workspaceMember ? null,
      workspaceDependencyGraph ? null,
      workspaceDependencyClosure ? null,
      workspaceIncludeDevDependencies ? true,

      sdkSetupScript ? "",
      extraPackageConfigSetup ? "",

      # Output type to produce. Can be any kind supported by dart
      # https://dart.dev/tools/dart-compile#types-of-output
      # If using jit, you might want to pass some arguments to `dartJitFlags`
      dartOutputType ? "exe",
      dartCompileCommand ? "dart compile",
      dartCompileFlags ? [ ],
      # These come at the end of the command, useful to pass flags to the jit run
      dartJitFlags ? [ ],

      # Attrset of entry point files to build and install.
      # Where key is the final binary path and value is the source file path
      # e.g. { "bin/foo" = "bin/main.dart";  }
      # Set to null to read executables from pubspec.yaml
      dartEntryPoints ? null,
      # Used when wrapping aot, jit, kernel, and js builds.
      # Set to null to disable wrapping.
      dartRuntimeCommand ?
        if dartOutputType == "aot-snapshot" then
          "${dart}/bin/dartaotruntime"
        else if (dartOutputType == "jit-snapshot" || dartOutputType == "kernel") then
          "${dart}/bin/dart"
        else if dartOutputType == "js" then
          "${nodejs}/bin/node"
        else
          null,

      runtimeDependencies ? [ ],
      extraWrapProgramArgs ? "",

      autoPubspecLock ? null,
      pubspecLock ?
        if autoPubspecLock == null then
          throw "The pubspecLock argument is required. If import-from-derivation is allowed (it isn't in Nixpkgs), you can set autoPubspecLock to the path to a pubspec.lock instead."
        else
          assert builtins.pathExists autoPubspecLock || throw "The pubspec.lock file could not be found!";
          lib.importJSON (
            runCommand "${lib.getName args}-pubspec-lock-json" {
              nativeBuildInputs = [ yq ];
            } ''yq . '${autoPubspecLock}' > "$out"''
          ),
      ...
    }:
    let
      workspaceDependencyClosure' =
        if workspaceDependencyClosure != null then
          workspaceDependencyClosure
        else if workspaceMember != null then
          let
            # The check lives on the demanded path: an unused binding with an
            # assert would never be forced under lazy evaluation.
            _graph =
              if workspaceDependencyGraph == null then
                throw "workspaceDependencyGraph is required when workspaceMember is set"
              else
                workspaceDependencyGraph;
            _roots = _graph.roots or { };
            _packages = _graph.packages or { };
            _root =
              _roots.${workspaceMember}
                or (throw "workspace member '${workspaceMember}' is missing from workspaceDependencyGraph.roots");
            _start =
              [ workspaceMember ]
              ++ (_root.main or [ ])
              ++ lib.optionals workspaceIncludeDevDependencies (_root.dev or [ ]);
          in
          map (item: item.key) (
            builtins.genericClosure {
              startSet = map (name: { key = name; }) _start;
              operator = item: map (name: { key = name; }) (_packages.${item.key} or [ ]);
            }
          )
        else
          null;

      workspaceDependencyClosureSet =
        if workspaceDependencyClosure' == null then
          null
        else
          lib.genAttrs workspaceDependencyClosure' (_: true);

      memberPackageFilter =
        if workspaceDependencyClosureSet == null then
          _name: _details: true
        else
          name: _details: builtins.hasAttr name workspaceDependencyClosureSet;

      # Both filters always compose: the closure (explicit or derived)
      # narrows the lock to one member's dependencies, and
      # pubspecLockPackageFilter additionally drops packages that cannot be
      # built (e.g. Flutter SDK entries).  An explicit
      # workspaceDependencyClosure replaces only the graph traversal, not
      # the user filter.
      effectivePubspecLockPackageFilter =
        name: details:
        (memberPackageFilter name details)
        && (pubspecLockPackageFilter name details);

      # Workspace members whose sources are injected into
      # package_config.json.  Explicit workspaceMembers wins; otherwise,
      # when a dependency graph is available, the members reachable from
      # workspaceMember are derived from it (graph roots ∩ closure); with
      # neither, all members from pubspec.yaml are injected at build time.
      workspaceMembers' =
        if workspaceMembers != null then
          workspaceMembers
        else if workspaceMember != null && workspaceDependencyGraph != null then
          builtins.filter (
            name: builtins.hasAttr name (workspaceDependencyGraph.roots or { })
          ) workspaceDependencyClosure'
        else
          null;

      generators = callPackage ./generators.nix { inherit dart; } { buildDrvArgs = args; };

      # Serialize the filtered view so pubspec.lock and package_config.json
      # in the build environment always cover the same package set.
      pubspecLockFile = builtins.toJSON (
        pubspecLock
        // {
          packages = lib.filterAttrs effectivePubspecLockPackageFilter (pubspecLock.packages or { });
        }
      );
      pubspecLockData = pub2nix.readPubspecLock {
        inherit
          src
          packageRoot
          pubspecLock
          gitHashes
          customSourceBuilders
          ;
        pubspecLockPackageFilter = effectivePubspecLockPackageFilter;
        sdkSourceBuilders = {
          # https://github.com/dart-lang/pub/blob/e1fbda73d1ac597474b82882ee0bf6ecea5df108/lib/src/sdk/dart.dart#L80
          "dart" =
            name:
            runCommand "dart-sdk-${name}" { passthru.packageRoot = "."; } ''
              for path in '${dart}/pkg/${name}'; do
                if [ -d "$path" ]; then
                  ln -s "$path" "$out"
                  break
                fi
              done

              if[ ! -e "$out" ]; then
                echo 1>&2 'The Dart SDK does not contain the requested package: ${name}!'
                exit 1
              fi
            '';
        }
        // sdkSourceBuilders;
      };
      packageConfig = generators.linkPackageConfig {
        inherit pubspecLock;
        packageConfig = pub2nix.generatePackageConfig {
          pname = if args.pname != null then "${args.pname}-${args.version}" else null;

          dependencies =
            # Ideally, we'd only include the main dependencies and their transitive
            # dependencies.
            #
            # The pubspec.lock file does not contain information about where
            # transitive dependencies come from, though, and it would be weird to
            # include the transitive dependencies of dev and override dependencies
            # without including the dev and override dependencies themselves.
            builtins.concatLists (builtins.attrValues pubspecLockData.dependencies);

          inherit (pubspecLockData) dependencySources;
        };
        extraSetupCommands = extraPackageConfigSetup;
      };

      inherit (dartHooks.override { inherit dart; })
        dartConfigHook
        dartBuildHook
        dartInstallHook
        dartFixupHook
        ;

    in
    assert
      !(builtins.isString dartOutputType && dartOutputType != "")
      -> throw "dartOutputType must be a non-empty string";

    (builtins.removeAttrs args removedDrvArgNames)
    // {
      inherit
        pubspecLockFile
        packageConfig
        sdkSetupScript
        dartCompileCommand
        dartOutputType
        dartRuntimeCommand
        dartCompileFlags
        dartJitFlags
        ;

      outputs = [
        "out"
        "pubcache"
      ]
      ++ args.outputs or [ ];

      dartEntryPoints =
        if (dartEntryPoints != null) then
          writeText "entrypoints.json" (builtins.toJSON dartEntryPoints)
        else
          null;

      runtimeDependencies = map lib.getLib runtimeDependencies;

      nativeBuildInputs =
        (args.nativeBuildInputs or [ ])
        ++ [
          dart
          dartConfigHook
          dartBuildHook
          dartInstallHook
          dartFixupHook
          makeWrapper
          jq
        ]
        ++ lib.optionals stdenv.hostPlatform.isDarwin [
          darwin.sigtool
        ]
        ++
          # Ensure that we inherit the propagated build inputs from the dependencies.
          builtins.attrValues pubspecLockData.dependencySources;

      preConfigure = args.preConfigure or "" + ''
        ln -sf "$pubspecLockFilePath" pubspec.lock
      '';

      # When stripping, it seems some ELF information is lost and the dart VM cli
      # runs instead of the expected program. Don't strip if it's an exe output.
      dontStrip = args.dontStrip or (dartOutputType == "exe");

      # The workspace member list travels to dart-config-hook.sh as a file
      # via passAsFile ($workspaceMembersJsonPath) so the setup hooks stay
      # constant store paths shared across packages.
      workspaceMembersJson =
        if workspaceMembers' == null then null else builtins.toJSON workspaceMembers';

      passAsFile = [
        "pubspecLockFile"
      ]
      ++ lib.optional (workspaceMembers' != null) "workspaceMembersJson";

      passthru = {
        pubspecLock = pubspecLockData;
      }
      // (args.passthru or { });

      meta = (args.meta or { }) // {
        platforms = args.meta.platforms or dart.meta.platforms;
      };
    };
}
