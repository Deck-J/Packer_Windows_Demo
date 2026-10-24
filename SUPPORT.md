# Support

This is a demonstration repository, maintained by John Decker.

- **Something is broken in a run?** `docs/RUNBOOK.md` §3 lists the failure modes and where to look first.
- **A build of yours fails on the image?** Check `docs/RUNBOOK.md` §3a — it may need the full IDE, an extra
  workload, or the out-of-proc switch.
- **A change broke your project definition?** `bin/validate-projects.py` is the contract; the CI job `projects`
  enforces it.
- **Security issue?** See `SECURITY.md` — private advisory, not an issue.

There is no support SLA. The honest expectation: this repository is a working reference you can copy, and its
quality bar is the tests in it, not a promise.
