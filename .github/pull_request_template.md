## What changed

<!-- one paragraph, and the issue it closes -->

## Evidence

- [ ] `terraform -chdir=infra validate` clean
- [ ] `terraform -chdir=infra plan` reviewed (paste the plan summary, not the whole diff)
- [ ] `packer validate packer/` clean
- [ ] `dotnet test` green
- [ ] No new resource without `owner`/`run`/`ttl` labels
- [ ] No secret, key or token anywhere in the diff

## Cost

<!-- What does this add per run, and per idle month? -->
