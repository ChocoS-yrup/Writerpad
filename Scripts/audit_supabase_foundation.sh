#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

fail() {
    echo "9-1 Supabase foundation audit failed: $1" >&2
    exit 1
}

project=WriterPad.xcodeproj/project.pbxproj

rg -q 'repositoryURL = "https://github.com/supabase/supabase-swift.git";' "$project" \
    || fail "official supabase-swift package is not configured"
rg -q 'kind = exactVersion;' "$project" \
    || fail "package requirement is not an exact version"
rg -q 'version = 2\.46\.0;' "$project" \
    || fail "supabase-swift is not pinned to 2.46.0"

for environment in Debug Test Release; do
    test -f "Configuration/$environment.xcconfig" \
        || fail "$environment configuration is missing"
    rg -q "baseConfigurationReference = .* /\\* $environment\\.xcconfig \\*/;" "$project" \
        || fail "$environment configuration is not assigned to an Xcode target"
done
test -f Configuration/Supabase.local.xcconfig.example \
    || fail "tracked configuration example is missing"
git check-ignore -q Configuration/Supabase.Debug.local.xcconfig \
    || fail "actual local values are not ignored"

for key in WriterPadSupabaseURL WriterPadSupabasePublishableKey; do
    rg -q "<key>$key</key>" WriterPad/Info.plist \
        || fail "$key is not wired into Info.plist"
done

if rg -n -i \
    '(service[_ -]?role|sb_secret_|access[_ -]?token|refresh[_ -]?token|password|email)[^=]*=[[:space:]]*"[^"]+"' \
    WriterPad Configuration --glob '!Supabase.local.xcconfig.example' >/dev/null; then
    fail "a forbidden credential-like value exists in app/configuration sources"
fi
if rg -n -i \
    '<key>[^<]*(service[_ -]?role|secret|access[_ -]?token|refresh[_ -]?token|password|email)[^<]*</key>' \
    WriterPad --glob '*.plist' >/dev/null; then
    fail "a forbidden credential key exists in an app plist"
fi

if rg -n 'SupabaseClient|SupabaseClientProvider' \
    WriterPad/Features WriterPad/App --glob '*.swift' \
    --glob '!AppEnvironment.swift' >/dev/null; then
    fail "a View/ViewModel or app global creates or retains a concrete Supabase client"
fi
if rg -n '(static[[:space:]]+(let|var)[[:space:]]+shared|global)[^\\n]*Supabase' \
    WriterPad/Sync --glob '*.swift' >/dev/null; then
    fail "a global Supabase client/provider exists"
fi

rg -q 'let supabaseClientProvider: any SupabaseClientProviding' \
    WriterPad/App/AppEnvironment.swift \
    || fail "AppEnvironment does not inject the protocol service"

echo "9-1 Supabase foundation audit passed."
