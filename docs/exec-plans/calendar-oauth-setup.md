# Calendar sign-in setup (Google, Microsoft)

Whisperer reads calendars by signing in to the provider directly. It does **not** use the
macOS Calendar app, EventKit or any macOS calendar permission.

| Source | Needs | Where in the app |
|---|---|---|
| Google Calendar | A Google OAuth client ID (below) | Settings → Calendar → Google Calendar → Sign In |
| Outlook / Microsoft 365 | A Microsoft Entra app registration (below) | Settings → Calendar → Outlook / Microsoft 365 → Sign In |

Both direct sign-ins use OAuth 2.0 with PKCE through the system sign-in sheet
(`ASWebAuthenticationSession`). There is **no client secret** in the app, access is read-only,
tokens are stored in the Keychain (`com.ivy.whisperer.calendar-accounts`, this device only), and
events are fetched straight from Google / Microsoft. Nothing passes through a Whisperer server.

The client IDs go in `Whisperer/Info.plist`. Until they are set, the Sign In buttons are disabled
and say "sign-in isn't set up in this build".

## Google Calendar

1. **Google Cloud Console** → create (or pick) a project → **APIs & Services → Library** →
   enable **Google Calendar API**.
2. **APIs & Services → OAuth consent screen**: user type **External**; app name *Whisperer*;
   add the scopes:
   - `openid`, `email`
   - `https://www.googleapis.com/auth/calendar.events.readonly`
   - `https://www.googleapis.com/auth/calendar.calendarlist.readonly`
   While the app is in *Testing*, add the Google accounts that may sign in as **test users**.
   Calendar scopes are *sensitive*: shipping to the public requires Google's OAuth app
   verification (privacy policy URL, scope justification, demo video).
3. **APIs & Services → Credentials → Create credentials → OAuth client ID** → application type
   **iOS** (this is the type Google uses for native Apple apps, macOS included) → bundle ID
   `com.ivy.whisperer`.
4. Copy the **Client ID** (`1234…-abc….apps.googleusercontent.com`) into
   `WhispererGoogleCalendarClientID` in `Whisperer/Info.plist`.

The redirect is derived from the client ID (`com.googleusercontent.apps.<id>:/oauth2redirect`);
nothing else to configure.

## Outlook / Microsoft 365

1. **Azure portal → Microsoft Entra ID → App registrations → New registration**: name
   *Whisperer*; supported account types **Accounts in any organizational directory and personal
   Microsoft accounts**.
2. **Authentication → Add a platform → Mobile and desktop applications** → custom redirect URI:
   `msauth.com.ivy.whisperer://auth`. Set **Allow public client flows** to *Yes*.
3. **API permissions → Add → Microsoft Graph → Delegated**: `Calendars.Read`, `User.Read`,
   `offline_access`, `openid`, `email`. (Work tenants may require an admin to consent to
   `Calendars.Read`.)
4. Copy the **Application (client) ID** into `WhispererMicrosoftCalendarClientID` in
   `Whisperer/Info.plist`.

## App Store

Sign-in works in the sandbox (`network.client` is already granted; `ASWebAuthenticationSession`
needs no entitlement). Review will ask why calendar data is read: reminders before scheduled
meetings, processed on device, never written.
