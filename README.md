# TracePort

A Moonlight fork for people who have to *type* on the far end.

Moonlight streams your desktop to a phone very well. What it does not do well is let you work
once you get there. The on-screen keyboard has no modifiers, no arrows, no function keys, and it
covers the field you are typing into. TracePort is the same client with that part rebuilt.

Everything upstream does still works. This is a fork, not a rewrite — the protocol, the decoder
and the streaming path are Moonlight's.

## What is different

**A keyboard line that has the keys a keyboard has.** Modifiers, `esc`, `tab`, `return`,
`delete`, arrows, `home`/`end`/`page up`/`page down`, `insert`, F1–F12 — one scrolling row above
the system keyboard, no paging.

**Digits 1–9 in front of the arrows.** An input method offers you numbered candidates and the
on-screen keyboard cannot reach them, so Chinese, Japanese and Korean input never worked properly
from a phone. Now it does.

**A macro pad in the black margins.** The letterbox either side of a 16:9 stream on a phone is
dead space. It holds a short column of macros you choose, styled like the existing floating
controls. Long-press any key to add, move or remove it.

**Application launching.** A macro can open Spotlight, type an application's name and press
return, which is a faster way to switch applications than aiming at a dock icon over a video
stream.

**The picture moves so you can see what you are typing.** The keyboard covers half the screen
and the field you are typing into is usually in the covered half. TracePort asks the host where
its caret is and lifts the picture just far enough to clear it. When the focused application will
not report a caret — most will not — it uses the pointer instead, which is where you clicked to
start typing. When the host has nothing to offer, the picture stays where it is rather than
guessing.

> This one needs a host that answers `GET /caret`. That is not in released Sunshine yet; see
> [Host support](#host-support).

**Pinch to zoom** on the stream, so you can read a corner of a 4K desktop on a phone.

**Text as text.** Anything your phone's own keyboard composes — Chinese characters, emoji,
dictation — is sent as text rather than as keystrokes it cannot spell.

## Install

There are no binaries. Build it yourself:

```sh
git clone https://github.com/harrison001/traceport.git
cd traceport
xcodebuild -project Moonlight.xcodeproj -scheme Moonlight \
  -destination 'generic/platform=iOS' -configuration Release \
  -derivedDataPath build \
  DEVELOPMENT_TEAM=<your team id> \
  -allowProvisioningUpdates build

xcrun devicectl device install app --device <device id> \
  build/Build/Products/Release-iphoneos/TracePort.app
```

`xcrun devicectl list devices` will tell you the device id, and `security find-identity -v -p
codesigning` your team.

The bundle identifier is `io.traceone.port`, so it installs alongside the official Moonlight
rather than replacing it. Add `PRODUCT_BUNDLE_IDENTIFIER=<your own>` if you would rather it were
yours.

The scheme is still called Moonlight — the Xcode target keeps its upstream name so that merges
from upstream stay readable. Only the product it builds is renamed.

## Host support

Any Sunshine or GeForce Experience host works for everything except caret following.

Caret following needs the host to answer `GET /caret` with the focused application's insertion
point. That is [proposed upstream](https://github.com/LizardByte/Sunshine) and not in a release
yet, so until it lands you need a Sunshine built from that branch. Without it the client simply
never moves the picture; nothing else changes.

The caret is read through Accessibility, which only macOS exposes. On other hosts the answer falls
back to the pointer.

## Networking

TracePort talks to your host directly. There is no relay, no account, and nothing routed through
anyone else's servers — the same as upstream Moonlight.

Over the internet that means you need a way to reach your own machine. [Tailscale] is the
arrangement this is developed and tested against: the host and the phone join your tailnet, the
host keeps its usual ports, and nothing is exposed publicly. Any other private network works the
same way — a VPN, WireGuard, or being on the same LAN. None of it is a dependency; it is just
what remote access needs.

[Tailscale]: https://tailscale.com

## Status

Used daily against a macOS host. Tested on iPhone and iPad, iOS 15 and later.

Not tested: tvOS, Windows and Linux hosts beyond the pointer fallback, and anything to do with
gamepads, which this fork does not touch.

## Coming

- Two-way audio, so the far end can hear you and you can hear it.

## Licence and credit

GPL v3, inherited from [Moonlight] and unchanged. The streaming client this is built on is the
work of the Moonlight developers; this fork adds an input layer on top of it and claims nothing
else. Bugs you find here are almost certainly mine — report them here rather than upstream, and
please check them against stock Moonlight first.

"Moonlight" is their project name. This one is called something else so the two are not confused;
it is not endorsed by or affiliated with them.

[Moonlight]: https://github.com/moonlight-stream/moonlight-ios
