#!/usr/bin/env python3
"""Validate the project definitions in projects/ against the schema and against reality.

Two kinds of check, and both matter:
  * shape   - required keys, enums, name/filename agreement (the schema, enforced without a jsonschema dependency)
  * truth   - the solution, test project and any extra step files named in a project actually exist

A framework that accepts a project file pointing at a path that does not exist is not a framework, it is a
config file with ambitions.
"""
import json
import pathlib
import sys

try:
    import yaml
except ImportError:
    print("FAIL: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECTS = ROOT / "projects"
PROFILES = ROOT / "profiles"

ARTIFACT_TYPES = {"nuget", "msi", "zip"}
TARGETS = {"iis", "service", "none"}
VS_EDITIONS = {"buildtools", "community", "professional", "enterprise"}

fails, checks = [], 0


def check(cond, msg):
    global checks
    checks += 1
    if not cond:
        fails.append(msg)


def main():
    profiles = {p.stem for p in PROFILES.glob("*.yaml")}
    check(bool(profiles), "no profiles found in profiles/")

    files = sorted(p for p in PROJECTS.glob("*.yaml"))
    check(bool(files), "no project definitions in projects/")

    for path in files:
        name = path.stem
        try:
            p = yaml.safe_load(path.read_text(encoding="utf-8"))
        except yaml.YAMLError as e:
            fails.append(f"{name}: not valid YAML: {e}")
            continue
        if not isinstance(p, dict):
            fails.append(f"{name}: must be a mapping")
            continue

        for key in ("name", "profile", "solution", "artifact", "deploy"):
            check(key in p, f"{name}: missing required key '{key}'")
        check(p.get("name") == name, f"{name}: name '{p.get('name')}' must equal the filename")
        check(p.get("profile") in profiles, f"{name}: profile '{p.get('profile')}' has no file in profiles/")

        sol = p.get("solution")
        if sol:
            check((ROOT / sol).exists(), f"{name}: solution '{sol}' does not exist")
        tests = p.get("tests")
        if tests:
            check((ROOT / tests).exists(), f"{name}: tests '{tests}' does not exist")

        art = p.get("artifact") or {}
        check(art.get("type") in ARTIFACT_TYPES, f"{name}: artifact.type '{art.get('type')}' is not one of {sorted(ARTIFACT_TYPES)}")
        check(bool(art.get("id")), f"{name}: artifact.id is required")

        dep = p.get("deploy") or {}
        targets = dep.get("targets") or []
        check(bool(targets), f"{name}: deploy.targets must list at least one target")
        for t in targets:
            check(t in TARGETS, f"{name}: deploy target '{t}' is not one of {sorted(TARGETS)}")
        if "iis" in targets:
            iis = dep.get("iis") or {}
            for key in ("site", "app_pool", "port"):
                check(key in iis, f"{name}: deploy.targets includes iis but deploy.iis.{key} is missing")

        build = p.get("build") or {}
        if "vs_edition" in build:
            check(build["vs_edition"] in VS_EDITIONS, f"{name}: build.vs_edition '{build['vs_edition']}' is not one of {sorted(VS_EDITIONS)}")
        for step in build.get("extra_steps") or []:
            check((ROOT / step).exists(), f"{name}: extra step '{step}' does not exist")

        print(f"  {name}: profile={p.get('profile')} targets={','.join(targets)} "
              f"artifact={art.get('type')}:{art.get('id')}")

    print(f"{len(files)} project(s), {checks} checks, {len(fails)} failure(s)")
    for f in fails:
        print(f"  FAIL {f}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
