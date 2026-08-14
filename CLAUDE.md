# NewOCR Project Instructions

## After Every Code Change

After making any change to source files, always:

1. **Build the app** by running `bash build.sh` from the project root (`/Users/saran/Documents/NewOCR`). Fix any compiler errors before proceeding.
2. **Commit and push** to GitHub:
   - Stage the changed files specifically (never `git add -A` blindly)
   - Commit with a short, descriptive message describing what changed
   - Push to `origin main`

Example workflow after a change:
```bash
bash build.sh
git add Sources/NewOCRApp.swift   # (or whichever files changed)
git commit -m "short description of what changed"
git push origin main
```

Do not report a task as done until the build succeeds and the commit is pushed.
