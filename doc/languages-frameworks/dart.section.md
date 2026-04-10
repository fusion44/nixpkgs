# Dart {#sec-language-dart}

## Dart applications {#ssec-dart-applications}

The function `buildDartApplication` builds Dart applications managed with pub.

It fetches its Dart dependencies automatically through `pub2nix`, and (through a series of hooks) builds and installs the executables specified in the pubspec file. The hooks can be used in other derivations, if needed. The phases can also be overridden to do something different from installing binaries.

If you are packaging a Flutter desktop application, use [`buildFlutterApplication`](#ssec-dart-flutter) instead.

`pubspecLock` is the parsed pubspec.lock file. pub2nix uses this to download required packages.
This can be converted to JSON from YAML with something like `yq . pubspec.lock`, and then read by Nix.

Alternatively, `autoPubspecLock` can be used instead, and set to a path to a regular `pubspec.lock` file. This relies on import-from-derivation, and is not permitted in Nixpkgs, but can be useful at other times.

::: {.warning}
When using `autoPubspecLock` with a local source directory, make sure to use a
concatenation operator (e.g. `autoPubspecLock = src + "/pubspec.lock";`), and
not string interpolation.

String interpolation will copy your entire source directory to the Nix store and
use its store path, meaning that unrelated changes to your source tree will
cause the generated `pubspec.lock` derivation to rebuild!
:::

If the package has Git package dependencies, the hashes must be provided in the `gitHashes` set. If a hash is missing, an error message prompting you to add it will be shown.

The `dart` commands run can be overridden through `pubGetScript` and `dartCompileCommand`; you can also add flags using `dartCompileFlags` or `dartJitFlags`.

Dart supports multiple [outputs types](https://dart.dev/tools/dart-compile#types-of-output); you can choose between them using `dartOutputType` (defaults to `exe`). If you want to override the binaries path or the source path they come from, you can use `dartEntryPoints`. Outputs that require a runtime will automatically be wrapped with the relevant runtime (`dartaotruntime` for `aot-snapshot`, `dart run` for `jit-snapshot` and `kernel`, `node` for `js`); this can be overridden through `dartRuntimeCommand`.

```nix
{
  lib,
  buildDartApplication,
  fetchFromGitHub,
}:

buildDartApplication (finalAttrs: {
  pname = "dart-sass";
  version = "1.62.1";

  src = fetchFromGitHub {
    owner = "sass";
    repo = "dart-sass";
    tag = finalAttrs.version;
    hash = "sha256-U6enz8yJcc4Wf8m54eYIAnVg/jsGi247Wy8lp1r1wg4=";
  };

  pubspecLock = lib.importJSON ./pubspec.lock.json;
})
```

### Building a single member of a Dart workspace {#ssec-dart-applications-workspace}

A [Dart workspace](https://dart.dev/tools/pub/workspaces) has a single shared `pubspec.lock` covering all workspace members.
When building only one member (e.g. a pure-Dart PWA) from a workspace that also contains a Flutter member, three problems arise:

1. **Lock file contains Flutter SDK entries.**
   The shared lock lists Flutter SDK packages (`source: sdk, description: flutter`).
   `buildDartApplication` does not know how to build Flutter SDK sources and will fail with "No SDK source builder has been given for flutter!" when it encounters them.

2. **Workspace member list includes Flutter members.**
   During the configure phase, `dartConfigHook` injects all workspace members declared in `pubspec.yaml` into `.dart_tool/package_config.json`.
   If a Flutter member is included, tools like `build_runner` will crash trying to resolve its Flutter imports at build time.

3. **Shared lock contains packages from unrelated members.**
   A workspace lock is the union of all member dependencies.
   If dependency sources are built from the full lock, unrelated packages (including Git dependencies) may be fetched even when the selected member does not use them.

The following parameters solve these problems independently:

**`pubspecLockPackageFilter`** is a function `(name: details: bool)` called for each entry in `pubspecLock.packages` before any package derivations are built.
Packages for which it returns `false` are silently dropped.
This solves problem 1: drop Flutter SDK entries so `buildDartApplication` never tries to build them.

```nix
# Drop Flutter SDK packages; keep Dart SDK packages and all hosted packages.
pubspecLockPackageFilter = _name: details:
  details.source != "sdk" || details.description == "dart";
```

::: {.note}
`pubspecLockPackageFilter` can only filter by fields present in `pubspec.lock` (`source`, `description`, `version`, `dependency`).
For member-specific builds, prefer `workspaceMember` + `workspaceDependencyGraph` below instead of trying to encode complex member logic in this predicate.
:::

**`workspaceMembers`** is a list of workspace member *package names* to inject into `package_config.json` during the configure phase.
It is the sole authority on member injection: a list injects exactly the named members, and an empty list injects none.
When `null` (the default) and `workspaceMember` + `workspaceDependencyGraph` are set, the members reachable from `workspaceMember` are derived from the graph automatically.
When `null` without a graph, all members declared in the workspace root `pubspec.yaml` are injected.
This solves problem 2: exclude Flutter workspace members so `build_runner` never sees their Flutter imports.

```nix
# Only inject the pure-Dart workspace members; exclude the Flutter app member.
workspaceMembers = [ "common" "pwa" ];
```

**`workspaceMember`** selects a single workspace member package name as the build root (for example, `"pwa"` or `"radrss_flutter"`).

**`workspaceDependencyGraph`** is a JSON dependency graph generated outside Nix evaluation (for example from `dart pub deps --json`) that contains:

- `roots.<member>.main` - direct runtime dependencies of each workspace member
- `roots.<member>.dev` - direct development dependencies of each workspace member
- `packages.<name>` - direct dependencies for each package

When both `workspaceMember` and `workspaceDependencyGraph` are set, `buildDartApplication` computes the transitive closure for that member and only keeps lock entries in that closure before building dependency sources.
This solves problem 3: unrelated workspace packages are excluded automatically.

**`workspaceIncludeDevDependencies`** controls whether `roots.<member>.dev` is included when computing the closure (defaults to `true`).
Keep this enabled when the build uses tools from `dev_dependencies` (for example `build_runner`).

**`workspaceDependencyClosure`** can be used as an explicit precomputed package list.
When set, it replaces the graph traversal only; `pubspecLockPackageFilter` still applies on top, so entries in the closure that the filter rejects are dropped.

A typical mixed workspace derivation using the parameters together:

```nix
buildDartApplication {
  # ...
  sourceRoot = "source/my_workspace";

  pubspecLock = lib.importJSON ./pubspec.lock.json;

  # Drop Flutter SDK packages from the lock (problem 1).
  pubspecLockPackageFilter = _name: details:
    details.source != "sdk" || details.description == "dart";

  # Keep only the transitive closure of one workspace member (problem 3).
  # The members to inject into package_config.json (problem 2) are derived
  # from the graph automatically; set workspaceMembers to override.
  workspaceMember = "pwa";
  workspaceDependencyGraph = lib.importJSON ./workspace_dependency_graph.json;

  # Include root dev_dependencies in the closure (default: true).
  workspaceIncludeDevDependencies = true;
}
```

Example minimal graph shape:

```json
{
  "version": 1,
  "roots": {
    "pwa": {
      "main": ["common", "jaspr"],
      "dev": ["build_runner"]
    }
  },
  "packages": {
    "common": ["http"],
    "jaspr": ["meta"],
    "build_runner": ["build"]
  }
}
```

### Patching dependencies {#ssec-dart-applications-patching-dependencies}

Some Dart packages require patches or build environment changes. Package derivations can be customised with the `customSourceBuilders` argument.

A collection of such customisations can be found in Nixpkgs, in the `development/compilers/dart/package-source-builders` directory.

This allows fixes for packages to be shared between all applications that use them. It is strongly recommended to add to this collection instead of including fixes in your application derivation itself.

### Running executables from dev_dependencies {#ssec-dart-applications-build-tools}

Many Dart applications require executables from the `dev_dependencies` section in `pubspec.yaml` to be run before building them.

This can be done in `preBuild`, in one of two ways:

1. Packaging the tool with `buildDartApplication`, adding it to Nixpkgs, and running it like any other application
2. Running the tool from the package cache

Of these methods, the first is recommended when using a tool that does not need
to be of a specific version.

For the second method, the `packageRun` function from the `dartConfigHook` can be used.
This is an alternative to `dart run` that does not rely on Pub.

e.g., for `build_runner`:

```bash
packageRun build_runner build
```

Do _not_ use `dart run <package_name>`, as this will attempt to download dependencies with Pub.

### Usage with nix-shell {#ssec-dart-applications-nix-shell}

#### Using dependencies from the Nix store {#ssec-dart-applications-nix-shell-deps}

As `buildDartApplication` provides dependencies instead of `pub get`, Dart needs to be explicitly told where to find them.

Run the following commands in the source directory to configure Dart appropriately.
Do not use `pub` after doing so; it will download the dependencies itself and overwrite these changes.

```bash
cp --no-preserve=all "$pubspecLockFilePath" pubspec.lock
mkdir -p .dart_tool && cp --no-preserve=all "$packageConfig" .dart_tool/package_config.json
```

## Flutter applications {#ssec-dart-flutter}

The function `buildFlutterApplication` builds Flutter applications.

See the [Dart documentation](#ssec-dart-applications) for more details on required files and arguments.
`buildFlutterApplication` is implemented on top of `buildDartApplication`, so workspace-related arguments such as `workspaceMembers`, `workspaceMember`, `workspaceDependencyGraph`, `workspaceDependencyClosure`, and `workspaceIncludeDevDependencies` are available here as well.

`flutter` in Nixpkgs always points to `flutterPackages.stable`, which is the latest packaged version. To avoid unforeseen breakage during upgrade, packages in Nixpkgs should use a specific flutter version, such as `flutter335` and `flutter338`, instead of using `flutter` directly.

```nix
{ flutter335, fetchFromGitHub }:

flutter335.buildFlutterApplication (finalAttrs: {
  pname = "firmware-updater";
  version = "0-unstable-2025-09-09";

  # To build for the Web, use the targetFlutterPlatform argument.
  # targetFlutterPlatform = "web";

  src = fetchFromGitHub {
    owner = "canonical";
    repo = "firmware-updater";
    rev = "402e97254b9d63c8d962c46724995e377ff922c8";
    hash = "sha256-nQn5mlgNj157h++67+mhez/F1ALz4yY+bxiGsi0/xX8=";
    fetchSubmodules = true;
  };

  pubspecLock = lib.importJSON ./pubspec.lock.json;

  sourceRoot = "${finalAttrs.src.name}/apps/firmware_updater";

  gitHashes.fwupd = "sha256-l/+HrrJk1mE2Mrau+NmoQ7bu9qhHU6wX68+m++9Hjd4=";
})
```

### Usage with nix-shell {#ssec-dart-flutter-nix-shell}

Flutter-specific `nix-shell` usage notes are included here. See the [Dart documentation](#ssec-dart-applications-nix-shell) for general `nix-shell` instructions.

#### Entering the shell {#ssec-dart-flutter-nix-shell-enter}

By default, dependencies for only the `targetFlutterPlatform` are available in the
build environment. This is useful for keeping closures small but can be problematic
during development. It's common, for example, to build Web apps for Linux during
development to take advantage of native features such as stateful hot reload.

To enter a shell with all the usual target platforms available, use the `multiShell` attribute.

e.g. `nix-shell '<nixpkgs>' -A fluffychat-web.multiShell`.
