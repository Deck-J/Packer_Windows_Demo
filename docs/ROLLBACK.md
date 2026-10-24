# Rollback

Three levers, in order of preference.

## 1. Previous package version (no infrastructure change)

```bash
# pin the earlier version and re-run only the deploy + verify jobs
gh workflow run pipeline.yml -f skip_image_build=true
```

Because nodes install the package by version, rolling back the application is a version change, not a
rebuild. The image is unchanged by design.

## 2. Previous image

The image family `winbuild-app` keeps old versions. Pin a specific one instead of the family:

```bash
gcloud compute images list --filter="family=winbuild-app" --format='table(name,creationTimestamp)'
terraform -chdir=infra apply -var="image=projects/<project>/global/images/winbuild-app-<older>"
```

## 3. Previous infrastructure

`infra/` is versioned with the code: check out the tag that last worked and apply it. Nothing here is
stateful, so a rollback is a fresh create against the older definition — which is also why teardown is
always safe.

## What rollback is not

There is no "restore the machines": nodes are cattle, rebuilt from the image on every run. If a node holds
anything worth keeping, it is in the wrong place.
