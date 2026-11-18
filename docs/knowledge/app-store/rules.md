# App Store rules (confirmed; apply by default)

1. **Every entitlement needs a feature, a usage string where macOS has one, and a sentence in the review notes.** Run
   `scripts/security/audit-entitlements.sh <absolute path to the archived .app>` on both editions before uploading. A new entitlement
   fails it until the script, the code and `reviewer-notes-template.md` / `china-edition.md` all know why it is there.
2. **Public text must not contradict the code.** The privacy policy, terms, in-app policy, listing and review notes describe the same
   behaviour. After any change to what is captured, sent or stored, grep all of them (`whisperer-landing/app/privacy`, `/terms`, their
   `china` pages, `Whisperer/Resources/PrivacyPolicy.md`, the ASC description and notes).
3. **Automated review runs before a human.** Apple's static analysis rejects an unexplained entitlement within hours. Put the explanation in
   App Review Information *before* submitting, not after the rejection.
4. **Do not write a custom EULA.** Apple's minimum terms are mandatory; the standard EULA plus our Terms page is safer.
5. **Both editions ship the same build number and are verified by the same script** (`scripts/release-editions.sh`): bundle id, China
   marker only in China, no AX/CGEvent symbols, no driver, `audit-app.sh`, `audit-entitlements.sh`.
6. **The compliance-guard hook inspects the command text.** Release commands live in a script file that exports `APP_STORE_GUARD_OK=1`;
   the hook's findings in `whisper.cpp/examples` and `Tools/dict-audit` are not shipped code. Re-check that claim, do not assume it.
7. **Release type is `AFTER_APPROVAL` (automatic) for both records.** The user wants an approved version to go live without a manual
   step. `PATCH /v1/appStoreVersions/{id}` `releaseType` works while the version waits for review.
8. **Say what was checked and what was not.** Never report approval odds from the banned-API scan alone: the entitlement audit and the
   public-claims grep are part of "checked".

- **A tax notice from Apple is audited against the real configuration, not assumed.** Read the app's and each IAP's tax category in the web
  UI (the API does not expose it), the base storefront and the scheduled `automaticPrices`; the answer for Whisperer on 2026-11-18 was
  "App Store software, nothing to change" (see `knowledge.md`). Re-audit when a subscription or Whisperer Cloud is added.

