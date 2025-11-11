# Releasing psych-pure

This project uses GitHub Actions to automatically publish new versions to RubyGems when a version tag is pushed.

## Releasing a New Version

1. Update the version in `lib/psych/pure/version.rb`
2. Update `CHANGELOG.md` with the new version and changes
3. Commit the changes:
   ```bash
   git add lib/psych/pure/version.rb CHANGELOG.md
   git commit -m "Bump version to X.X.X"
   ```
4. Create and push a tag:
   ```bash
   git tag vX.X.X
   git push origin main --tags
   ```

GitHub Actions will automatically:
- Build the gem
- Push it to RubyGems.org

## Manual Release (if needed)

If automated release fails or you need to publish manually:

```bash
gem build psych-pure.gemspec
gem push psych-pure-X.X.X.gem
```
