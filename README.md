# qt-static-windows

## What this is

A GitHub Actions workflow that builds a static Qt 6 (qtbase only, MSVC 2022 x64, `/MT` runtime) and publishes it as a release. It exists so that applications such as noite can link Qt statically into a single `.exe` without every developer building Qt for hours.

Each release is tagged `qt-<version>-msvc2022-x64-mt-<build>` (for example `qt-6.10.3-msvc2022-x64-mt-1`) and contains:

- `qt-<version>-static-msvc2022-x64-mt.zip`: the install tree (unzip anywhere, use as the prefix)
- `BUILD-INFO.txt`: Qt version, compiler, Windows SDK, exact configure command, date, build repo commit
- `SHA256SUMS.txt`: checksums of every other asset
- Qt's `LICENSES\*` files
- `qtbase-everywhere-src-<version>.tar.xz`: the exact Qt source that was built

## What's inside

Only `qtbase` (Core, Gui, Widgets, Network, Sql, ...), x64, release, built with:

```
configure -static -static-runtime -release -optimize-size -no-icu -no-opengl -nomake tests -nomake examples -no-ltcg -prefix <WorkDir>\install
```

`build.ps1` downloads the source from `download.qt.io`, verifies it against Qt's `.sha256` file (falling back to `md5sums.txt`), configures from a separate build directory, builds with `cmake --build . --parallel`, installs, and packages the result. Needs CMake and Ninja on `PATH` and an MSVC x64 environment (`ilammy/msvc-dev-cmd` in CI). Perl is not needed for qtbase; `windows-latest` has Strawberry Perl anyway.

Build in a short directory (the workflow uses `C:\q`): Qt's tree has deep paths and long ones hit `MAX_PATH`.

Local use: `powershell -File build.ps1 -QtVersion 6.10.3 -Build 1 -WorkDir C:\q -OutDir C:\qout` (add `-DryRun` to only print what it would do).

## Using it with CMake

Unzip the asset (for example to `C:\qt-static`) and point CMake at it. The runtime must match Qt's `/MT`:

```
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_PREFIX_PATH=C:\qt-static ^
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
```

A static Qt needs its platform plugin linked in explicitly:

```cmake
find_package(Qt6 REQUIRED COMPONENTS Widgets)
target_link_libraries(myapp PRIVATE Qt6::Widgets)
qt_import_plugins(myapp INCLUDE Qt6::QWindowsIntegrationPlugin)
```

Add further plugins (styles, image formats, SQL drivers) to `INCLUDE` as needed. `CMAKE_MSVC_RUNTIME_LIBRARY` must be `MultiThreaded` (not `MultiThreadedDLL`), and not the Debug variant, since only a release Qt is shipped.

## Licences

The binaries are Qt, available under LGPLv3 or GPLv3 (see the attached `LICENSES\*`). With a static build, LGPL obligations apply to your application: read them before shipping. The exact Qt source of each build is attached to its release as `qtbase-everywhere-src-<version>.tar.xz`. The scripts in this repository (`build.ps1`, the workflow) are MIT, see `LICENSE`.

## Building a new version

Actions -> build -> Run workflow, then enter `qt_version` (default `6.10.3`) and `build` (default `1`; raise it to rebuild the same Qt version). The workflow takes up to a few hours and creates the release on success. It fails if a release with that tag already exists.
