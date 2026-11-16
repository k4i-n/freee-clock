# freee clock

A small macOS menu bar app that clocks you in and out on freee HR (freee 人事労務). On working days it punches at a random time inside a window you set, but only while you are actually using the Mac. It is one Swift file with no dependencies.

This is a personal hobby project. It is not made by or affiliated with freee K.K. Your attendance record is your responsibility: check that your company allows automatic clocking before you use it.

## What it does

- On working weekdays it clocks in at a random time between 08:15 and 09:00 and clocks out between 18:00 and 19:00. You can change both windows in Settings.
- It checks freee first and does nothing on holidays, days off, full-day leave, or when you already punched by hand. On partial leave (half day, hourly, morning or afternoon off) it notifies you to punch by hand.
- It punches only when the Mac has been used in the last 10 minutes. If you are away at the chosen time, it waits until you come back, up to the end of the window.
- 30 seconds before a punch, the icon flashes and you get a notification. The menu then offers Clock now, Delay 10 min and Skip.
- Late mode: if the Mac was off, asleep or unused for the whole clock-in window, it clocks in the next time you use the Mac, after a 30 second countdown. This is on by default for clock in (until the clock-out window starts) and off by default for clock out (until midnight).
- If a punch is missed and late mode is off, you get a notification so you can punch by hand.

The menu shows today's date and day type, and today's punches:

```
11-12: work day
● Clocked in     08:37
● Clocked out    18:20
```

## Requirements

- macOS 12 or later
- Xcode Command Line Tools (`xcode-select --install`), for `swiftc`
- A freee HR account where you are registered as an employee

## Setup

1. Clone the repository and run the installer. It builds the app, runs the self-test, and registers it as a launchd agent that starts at login and restarts if it stops.

   ```
   git clone <repo-url> ~/freee-clock
   ~/freee-clock/install.sh
   ```

   The app runs from the folder you cloned into, so keep that folder in place. To move it, run `install.sh uninstall`, move the folder, and run `install.sh` again.

2. On first start the app opens the "Sign in to freee" window. The app signs in through your own freee app, so no shared secret is built into this project.

   - Open the freee developers page from the window and create an app (it is free).
   - Set the app's callback URL to `http://127.0.0.1:8370/callback` (the window has a Copy button).
   - Give the app the HR (人事労務) permissions for work records and time clocks.
   - Paste the app's Client ID and Client Secret into the window and click "Sign in with freee".
   - Allow access in the browser. freee sends the browser back to the app, and the window closes.

3. If macOS asks whether `freee` may use the Keychain, choose "Always Allow". The app asks again after each rebuild, because a locally built binary gets a new signature every time.

## Settings

Click the clock icon, then Settings... (or press ⌘,):

- Clock in and clock out windows (start and end)
- Late mode for clock in and for clock out
- Account: who is signed in, and Sign out

Sign out removes the sign-in but keeps your app's Client ID and Secret, so signing in again only needs the browser step.

## Command line

`install.sh` links the `freee` command into `~/.local/bin`.

```
freee status          who you are, today's day type, what can be punched now
freee in | out        punch now
freee setup           open the sign-in window in the running app
freee demo [in|out]   40 second countdown in the menu bar, no punch
freee selftest        offline tests with a fake clock, fake freee and fake Keychain
```

## Where things are stored

- Login Keychain, service `freee-clock`: your app's Client ID and Secret, and the OAuth tokens
- `~/.config/freee-clock/config.json`: company and employee id
- `~/.config/freee-clock/settings.json`: your Settings
- `~/Library/Logs/freee-clock.log`: log

The app talks only to freee (`api.freee.co.jp`, `accounts.secure.freee.co.jp`). The sign-in listener on `127.0.0.1:8370` runs only while the sign-in window is waiting for the browser.

## Uninstall

```
~/freee-clock/install.sh uninstall
```

This stops the app and removes the launchd agent and the `freee` command. To also remove your data, delete `~/.config/freee-clock` and the `freee-clock` items in Keychain Access.

## License

MIT
