# ADR-0007: Menu-bar lifecycle and independent launch/card preferences

Date: 2026-10-05  
Status: Accepted from owner feedback

## Context

Closing the import window left the Dock icon visible while scans continued. The owner wants background operation to remain available through the menu bar, with an optional window on launch and optional login startup. New-photo counts and richer status-icon updates are explicitly deferred.

## Decision

- Set `LSUIElement` and initially use AppKit's accessory activation policy. New installations start without a window. Persist `launchInBackground`, defaulting to true when missing; preserve destination, templates, presets, and existing card preferences.
- Showing a window restores regular activation policy, application menus, and Dock presence. Closing the last visible or minimized normal titled window returns to accessory mode. A separate notices/About window keeps normal presence until it too closes. Minimizing retains the Dock for restoration.
- Closing a window does not cancel scans or imports. Quit remains explicit and retains the existing confirmation/verified-copy handling during an import.
- Keep launch preference separate from card-insertion preference. New installations scan in the background; existing show-and-scan or availability-only preferences stay intact. An already-mounted card may scan at startup without overriding the launch preference. New insertions can scan quietly, show-and-scan, or remain available for manual selection. Never interrupt ongoing work or start copying automatically.
- Provide **Login Items…** via `SMAppService.openSystemSettingsLoginItems()`. The user adds the installed app in macOS Open at Login. No automatic login registration, launch agent, helper, or signing account is introduced.
- Preserve current status-icon behavior. New-photo counts and richer hover/click progress remain future work.

## Validation

Isolated synthetic GUI exercises cover background launch, tray reopening, hiding/restoring Dock presence, scans while hidden, settings persistence, a separate notices window, minimization, and a fresh foreground launch. Settings tests cover defaults, migration, and round trips. Package verification asserts `LSUIElement` in the extracted app. Import safety and full byte-verification exercises remain required. Physical Login Items enrollment and login after reboot are user-managed and have not been exercised.
