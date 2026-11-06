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

### Google verification (sensitive scopes) — status and submission text

Project `whisperer-491716`, client "Whisperer macOS" (iOS type, bundle `com.ivy.whisperer`), client
ID in `Info.plist`. Done 2026-11-06: Calendar API enabled, consent screen (External), test user
`ialex.ivy@gmail.com`, sign-in verified end to end in the Debug app. Later the same day: Branding
filled in (home, privacy, terms, authorized domain `whispererapp.com`) and **verified and
published**; Data Access lists `calendar.events.readonly` (sensitive),
`calendar.calendarlist.readonly`, `userinfo.email`, `openid`; publishing status **In production**
(anyone can sign in; Google's unverified-app warning and the 100-user cap stay until the
sensitive-scope review passes). Demo video recorded (3:44, sign-in → consent with both scopes →
connected → meeting with Join & Record → recording named after the invite → participants in
Speakers), uploaded unlisted: https://youtu.be/pScKXpS0IqI. Scope justification saved on Data
Access. **Submitted for verification 2026-11-06 18:39** — status "data access is under review";
Google writes to ialex.ivy@gmail.com. Until it passes: unverified-app warning, 100-user cap.

To publish and verify (Google Auth Platform):
1. **Branding** — home page `https://whispererapp.com`, privacy `https://whispererapp.com/privacy`
   (has the Calendar Data section and the Limited Use statement), terms
   `https://whispererapp.com/terms`, authorized domain `whispererapp.com`. Skip the logo: a logo
   triggers a separate brand review.
2. **Data Access** — add `.../auth/calendar.events.readonly` and
   `.../auth/calendar.calendarlist.readonly`. Justifications:
   - *calendar.events.readonly*: "Whisperer is a macOS meeting-notes app. It reads the user's
     upcoming events (title, time, meeting link, organizer and attendees) to remind them before a
     meeting, open the meeting link and start a recording in one click, and name the recording and
     its speakers after the invite. Read-only; event data stays on the user's Mac and is never sent
     to our servers (we have none)."
   - *calendar.calendarlist.readonly*: "Lists the user's calendars so they can choose which ones
     Whisperer uses for reminders. Read-only; stays on the Mac."
3. **Audience → Publish app** (moves to production; the unverified-app warning stays until
   verification passes, 100-user cap).
4. **Demo video** (YouTube, unlisted), recorded from the App Store build: Workspace → Calendar →
   Continue with Google → the consent screen with the client ID visible in the address bar → back
   in the app: account connected, calendars listed, an upcoming meeting with Join & Record, a
   reminder card, and a recording named after the invite with participants offered in Speakers.
5. **Verification Center → Submit**. Typical review: a few days to 2–3 weeks.

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
