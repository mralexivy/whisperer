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
