# Working agreements

See `AGENTS.md` for project structure, build commands, and style conventions.

## Git

Commit and push after each change. Don't leave finished work sitting in the working
tree waiting to be asked about — once a change builds and its tests pass, commit it
with a short imperative message and push it. Separate logical changes get separate
commits.

Work happens directly on `main` unless asked otherwise. `main` is often behind
`origin/main`, so rebase before pushing:

```sh
git pull --rebase origin main && git push
```

Leave pre-existing unrelated modifications (for example Xcode's `project.pbxproj`
reordering churn) out of the commit unless they are part of the change.
