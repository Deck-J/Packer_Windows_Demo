# ADR-0007 — SSH over IAP, never WinRM

**Status:** accepted. Applies to the Windows image build.

## Context

Packer can drive a Windows build over either communicator. WinRM is the traditional choice and the one most
GCP Windows examples use, but it needs a local-account password, a listener on 5985/5986, and — on a fresh
cloud image — usually Basic auth plus `AllowUnencrypted` before it will connect at all. SSH is the same job
with a key instead of a password.

## Decision

Use **SSH over an IAP tunnel** with a **per-build ed25519 keypair**. WinRM is not configured anywhere: no
listener, no firewall rule on 5985/5986, no password variable in the Packer template or the Cloud Build
config.

Mechanics: Cloud Build generates the keypair; the public half travels in instance metadata (`ssh-keys`);
the specialize script installs `OpenSSH.Server`, sets PowerShell as `DefaultShell`, writes
`administrators_authorized_keys` with `icacls /inheritance:r` (Administrators/SYSTEM), restarts `sshd`, and
admits port 22 from `35.235.240.0/20` only. Packer uses `communicator = "ssh"` with `use_iap = true`. Both
key halves are shredded when the Cloud Build step ends.

## Consequences

**Gained**

- No password exists anywhere: not in the repo, not in a var file, not in instance metadata, not in logs.
- Nothing listens on 5985/5986, so a misconfiguration cannot silently stand up an unencrypted management
  channel.
- Revocation is implicit — the key dies with the build, and there is no account to disable afterwards.

**Given up**

- `windows-restart` (a WinRM-era provisioner) cannot be used mid-build. Provisioning is therefore written
  with no mid-build restart: installers run with `--norestart` and accept exit code 3010; the only machine
  stop is sysprep at the end, which is meant to end the build.
- `elevated_user`/`elevated_password` are unreliable over SSH. The build user is a local administrator
  instead — the same privilege, fewer knobs.
- Windows OpenSSH has its own quirks (the `DefaultShell` registry value, ACL rules on the administrators
  file, a slow first start). They are handled once, in the specialize script, where anyone can read them.

## Revisit if

A step genuinely needs a restart mid-build. The answer then is a second build block or a reconnect attempt —
not a return to WinRM.
