# Privacy Policy

**TracePort collects nothing.**

There is no analytics, no crash reporting, no account, no telemetry and no server of mine
anywhere in it. Nothing about you or your device is sent to me, because there is nowhere for it
to be sent to.

Last updated 17 August 2026.

## What the app talks to

Only the computer you point it at.

TracePort is a client for [Sunshine](https://github.com/LizardByte/Sunshine) and other hosts
speaking the same protocol. When you connect, it talks directly to that machine — on your local
network, or across whatever private network you have arranged, such as a VPN or
[Tailscale](https://tailscale.com). Traffic does not pass through any service operated by me.

Pairing with a host exchanges certificates with that host. Those certificates stay on your device
and on your computer.

## What is stored on your device

Your host list, pairing certificates, streaming preferences, and the keys you have put on the
macro pad. All of it lives in the app's own storage on your device and is removed when you delete
the app. None of it is uploaded.

## Permissions

**Local network.** Required to find and reach your computer. iOS asks for this the first time you
connect.

**Bluetooth.** Only if you use a Citrix X1 mouse. Declined or unused otherwise.

**Game controllers, keyboards and pointing devices.** Used to send your input to the computer you
are streaming from, and for nothing else.

## Children

TracePort is not directed at children and collects no information from anyone, including
children.

## The source

TracePort is free software under the GPL v3, and the complete source is at
[github.com/harrison001/traceport](https://github.com/harrison001/traceport). You do not have to
take any of the above on trust — every line that could collect anything is there to read, and you
can build the app yourself from it.

## Changes

If this policy ever changes it will change here, with the date above updated. Given that the
policy is "nothing is collected", the only change worth expecting is a clarification.

## Contact

Questions, or anything here that looks wrong: open an issue at
[github.com/harrison001/traceport/issues](https://github.com/harrison001/traceport/issues).
