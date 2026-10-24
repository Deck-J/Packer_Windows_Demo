# One image, two build toolchains

The demo image is built to do **both** kinds of build in a single run, because that is the realistic ask: a
modern SDK-style app *and* a legacy project that only an IDE toolchain can compile.

| step | toolchain | project | evidence |
|---|---|---|---|
| `build-and-publish` | `dotnet` (SDK) | `src/WinBuild.SampleApp` | publish output served by IIS |
| `msbuild-demo` | **MSBuild.exe** via vswhere | `src/WinBuild.MsBuildDemo` — legacy, non-SDK-style, .NET Framework 4.8 | `C:\packer\msbuild.log`, exe hash, and the exe is executed |
| `devenv-build` | **devenv.com** (the IDE) | `WinBuild.Demo.sln` containing the same legacy project | `C:\packer\devenv.log` + IDE build log |

Both demo steps append to `C:\packer\demo-manifest.json`, and `custom/tests/15-build-demo.Tests.ps1` fails the
build unless **both** entries exist, their artefacts exist, and their sha256 still matches. So the claim "this
image builds both ways" is checked, not asserted.

The image is built with `vs_edition=enterprise` by default now (the pipeline passes it), because a Build Tools
image has no `devenv` and the whole point is to demonstrate the IDE build. Switch it back with the
`VS_EDITION` repository variable when you want the smaller, agent-licensed image.

## Demonstrating a `devenv` build

`custom/scripts/25-devenv-build.ps1` builds `WinBuild.sln` with **`devenv.com`** and asserts the assembly —
not the exit code alone. It runs as a step in `custom/build.config.json`.

| image | behaviour |
|---|---|
| `vs_edition=buildtools` (default) | logs that `devenv` is absent and skips — a Build Tools image never claimed to have the IDE |
| `vs_edition=community\|professional\|enterprise` | locates `devenv.com` via `vswhere`, builds `Release\|x64`, prints the tail of the IDE build log, checks the DLL exists |

Evidence produced: `C:\packer\devenv.log` (what ran), `C:\packer\devenv-build.log` (the IDE's own build log),
the assembly path and its sha256.

## Why this matters

`dotnet build` and `msbuild` cover ordinary projects. Some project types only build through the IDE:

- **`.vdproj`** Visual Studio Installer Projects (produces the MSI)
- **SSDT / SSRS** report and database projects
- **VSTO / Office add-ins**
- projects whose targets arrive in a third-party VSIX

For those, two extra pieces are typically needed on top of the IDE:

1. **The extension** — e.g. *Microsoft Visual Studio Installer Projects* for `.vdproj`
2. **`vs_disable_out_of_proc_build=true`** — the per-user registry switch that stops `devenv` building out of
   process (see `docs/RUNBOOK.md` §3a)

## Turning this into a real `.vdproj` demo

1. Build the image with `-var vs_edition=enterprise`.
2. Install the Installer Projects VSIX in the image by passing its download URL:
   `-var "vs_extra_vsix_urls=https://.../vspackage"` — provisioning downloads and installs it with
   `VSIXInstaller.exe /q /a`, and fails the build if the URL cannot be fetched.
3. Add the `.vdproj` to the solution, then point the devenv step at it:
   `devenv.com WinBuild.sln /Build "Release|x64" /Project Installer`.
4. Assert the MSI: `Test-Path C:\packer\src\Installer\Release\WinBuild.SampleApp.msi`.

A hand-written `.vdproj` is deliberately **not** committed here: those files carry hundreds of GUIDs and the
project designer rewrites them, so a fabricated one would be a demo that fails for reasons unrelated to the
pipeline. Add yours from Visual Studio and the step above builds it unchanged.
