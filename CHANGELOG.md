# Changelog

Versions follow semantic versioning once the repository is tagged; until then this is a record of what changed
and, where relevant, what it breaks.

## Unreleased

### Added
- Project definitions (`projects/`) with a schema and `bin/validate-projects.py`, so a second application is a
  YAML file rather than a fork of the pipeline.
- Build profiles (`profiles/`): `windows-iis`, `windows-service`, `installer-vdproj`, `library`.
- `bin/new-project.sh` to scaffold a project definition.
- Extensibility, contributing, security and support documents.

## 2026-10-24

### Added
- OpenTelemetry instrumentation in the sample app, with the endpoint supplied by configuration and `/telemetry`
  reporting what the instance decided.
- Dynatrace OneAgent installed at node startup with the token from Secret Manager; `DYNATRACE_DRY_RUN` proves the
  wiring without a tenant.
- Numbered phases (1–9) with banners and a summary table covering bootstrap → build → upload → deploy → test →
  teardown → cost audit.
- Streamed Cloud Build logs in the Actions log, with per-step groups and milestone notices.
- Visual Studio edition/workload switch, `DisableOutOfProcBuild`, and optional VSIX installation.
- A demo that builds with **MSBuild** and with **devenv** in one image, proven by `custom/tests/15-build-demo.Tests.ps1`.
- Environment gates (`gcp-test`, `gcp-prod`) and a tag→promote workflow that deploys the tested digests without
  rebuilding.

### Changed
- Infrastructure is Terraform and the image is Packer (ADR-0006), reversing ADR-0005.
- Windows management is SSH over IAP (ADR-0007); no WinRM listener exists.

### Fixed
- `dotnet build src` never worked (MSB1003) — a solution file now exists.
- OpenTelemetry 1.9.0 carried a known advisory; pinned to 1.20.1.
- The deploy-phase suite ran before the load balancer had answered.
- The Cloud Build log streamer reported failure on success, and printed annotated lines twice.
