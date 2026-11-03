# Fridge

An iOS app that tracks what's in your fridge (by photo or manual entry) and generates recipes from it. See [DESIGN.md](DESIGN.md) and the per-feature [specs](specs/README.md).

## Layout

```
ios/        SwiftUI app. project.yml is the source of truth; the .xcodeproj is generated.
supabase/   Supabase config, migrations, seed data and Edge Functions
specs/      Feature specs
scripts/    Repo tooling
```

## Setup

### Tools
- **Xcode 16+**, with the iOS platform installed (Xcode → Settings → Components, or `xcodebuild -downloadPlatform iOS`).
- Point the command-line tools at Xcode: `sudo xcode-select -s /Applications/Xcode.app`
- **XcodeGen** and the **Supabase CLI**: `brew install xcodegen supabase/tap/supabase`, or download the binaries from their GitHub releases.

### Supabase (hosted, free tier)
The prototype uses one hosted project for both Dev and Prod. Docker / `supabase start` isn't needed yet.

1. Create a project at [supabase.com](https://supabase.com).
2. Link this repo to it: `supabase link --project-ref <project-ref>`
3. Set the Anthropic key as a function secret. It is never committed and never sent to the app:
   `supabase secrets set ANTHROPIC_API_KEY=sk-ant-...`
4. Deploy the functions: `supabase functions deploy`
5. Apply migrations: `supabase db push --remote`
6. In the dashboard, Settings → Data API → **Exposed schemas**: add `app` and `catalog`.
7. Load the ingredient catalog (safe to rerun): `supabase db query --remote -f supabase/seed/load_catalog.sql`
   To change items, edit `supabase/seed/catalog_items.csv` and rebuild with `python3 -I supabase/seed/build_catalog_seed.py <unzipped USDA SR Legacy CSV folder>` (see the script header).
8. Run the row-level security test (rolled back, leaves no data): `supabase db query --remote -f supabase/tests/rls_test.sql`. It prints `PASS` or the failed checks.

### iOS app
1. Put the project URL and **publishable** key (Project Settings → API Keys) in `ios/Config/Dev.xcconfig` and `ios/Config/Prod.xcconfig`. Both are public by design. Never put a secret key there: this repo is public.
2. Generate the Xcode project: `cd ios && xcodegen`
3. Plug in your iPhone (Developer Mode on, unlocked) and run `./scripts/run-on-iphone.sh` from the Terminal app.
   Xcode's Run button doesn't work with Xcode 16.4 and an iOS 27 iPhone (it fails extracting debug symbols); the script installs without them.
   With a free Apple ID the install expires after 7 days; run the script again to renew.

The app currently opens a debug screen that calls the `hello` function and shows whether the Anthropic key is configured.

## Checking the key never ships
After a build, this should print nothing:
```
grep -r "sk-ant-" ~/Library/Developer/Xcode/DerivedData/Fridge-*/Build/Products/*/Fridge.app
```
