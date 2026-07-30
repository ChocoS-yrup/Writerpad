#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

fail() {
    echo "9-2 Supabase auth foundation audit failed: $1" >&2
    exit 1
}

auth_files='WriterPad/Sync/KeychainSessionStore.swift WriterPad/Sync/SupabaseAuthService.swift'

rg -q 'actor KeychainSessionStore: SessionTokenStoring' \
    WriterPad/Sync/KeychainSessionStore.swift \
    || fail "KeychainSessionStore is not an actor boundary"
rg -q 'import Security' WriterPad/Sync/KeychainSessionStore.swift \
    || fail "Keychain storage does not use Security.framework"
rg -q 'kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly' \
    WriterPad/Sync/KeychainSessionStore.swift \
    || fail "Keychain accessibility policy is missing"

rg -q 'actor SupabaseAuthService: AuthenticationServicing' \
    WriterPad/Sync/SupabaseAuthService.swift \
    || fail "SupabaseAuthService is not an actor boundary"
rg -q 'setSession\(' WriterPad/Sync/SupabaseAuthService.swift \
    || fail "startup restoration has no server validation call"
for code in sessionExpired refreshTokenNotFound refreshTokenAlreadyUsed; do
    rg -q "\\.$code" WriterPad/Sync/SupabaseAuthService.swift \
        || fail "$code is not mapped distinctly"
done

rg -q 'let authenticationService: any AuthenticationServicing' \
    WriterPad/App/AppEnvironment.swift \
    || fail "AppEnvironment does not inject the auth protocol"
rg -q 'authenticationService\.restoreSession\(\)' \
    WriterPad/App/WriterPadApp.swift \
    || fail "app startup does not trigger asynchronous session restoration"

rg -q 'NonPersistingAuthLocalStorage' \
    WriterPad/Sync/SupabaseClientProvider.swift \
    || fail "Supabase SDK persistence has not been disabled"
rg -q 'autoRefreshToken: false' \
    WriterPad/Sync/SupabaseClientProvider.swift \
    || fail "Supabase SDK auto refresh has not been disabled"

if rg -n 'UserDefaults|@AppStorage' $auth_files >/dev/null; then
    fail "auth/session data is persisted outside Keychain"
fi
if rg -n \
    -e 'print\(' \
    -e 'debugPrint\(' \
    -e 'NSLog\(' \
    -e 'Logger\.' \
    -e 'os_log\(' \
    $auth_files >/dev/null; then
    fail "auth code contains logging that could expose credentials"
fi
if rg -n '(let|var)[[:space:]]+password[[:space:]]*[:=]' $auth_files >/dev/null; then
    fail "password is retained as stored state"
fi
if rg -n '(signUp|resetPassword|deleteAccount)' $auth_files >/dev/null; then
    fail "out-of-scope account management was added"
fi
if rg -n 'SupabaseClient' WriterPad/Features --glob '*.swift' >/dev/null; then
    fail "a View/ViewModel directly references SupabaseClient"
fi

echo "9-2 Supabase auth foundation audit passed."
