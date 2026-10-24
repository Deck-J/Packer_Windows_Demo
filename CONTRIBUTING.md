# Contributing

## Before you open a PR

```bash
python3 bin/validate-projects.py     # project definitions: shape and that the paths exist
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra validate
packer fmt -check -recursive packer
packer validate -var project_id=example -var service_account_email=sa@example.iam.gserviceaccount.com \
  -var ssh_private_key_file=/dev/null -var ssh_public_key=x -var image_version=0.0.0 -var app_version=0.0.0 packer
bash scripts/policy-check.sh
dotnet build WinBuild.sln -c Release && dotnet test WinBuild.sln -c Release
```

All of it also runs in CI; running it locally just saves you a round trip.

## Rules that are not negotiable

- **No secrets in the repository.** Not in a variable, not in a test, not in a comment. Secret Manager is the path.
- **Every resource carries `owner`, `run` and `ttl` labels.** The teardown sweep depends on them.
- **Nothing fails silently.** A step that cannot do its job exits non-zero and says why.
- **Docs describe what the code does.** If a change makes a sentence in `docs/` untrue, the change is not finished.
- **A new claim needs evidence.** "It works" means a log line, a file, or a test that would fail if it stopped
  working — not a paragraph in a README.

## Commits

Conventional-ish (`feat:`, `fix:`, `docs:`, `chore:`), one idea per commit, and the message says *why* when the
why is not obvious from the diff.
