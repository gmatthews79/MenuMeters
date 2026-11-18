# MenuMeters 3.1.1

The disk meter can show how fast the startup disk is reading and writing, and
the disk menu works on macOS 27.

## New

- The disk meter can show the read and write speeds of the startup disk next
  to its activity indicator. Turn it on with "Show read and write speeds of the
  startup disk" in the Disk tab. Only the disk that macOS started from is
  counted: other disks are left out, and a disk image is counted once, as
  reads and writes of its file. The speeds refresh about once a second.

## Fixes

- On macOS 27 the disk menu showed a blank row for every volume. The rows are
  back, and clicking one opens or ejects the volume as before.

## New home

The website is https://menumeters-osx.github.io, and the source, releases and
issues are at https://github.com/menumeters-osx/MenuMeters.

# MenuMeters 3.1.0

The meters show the right numbers again, and MenuMeters now updates itself.

## Fixes

- The CPU meter shows the real load. It read close to 100% all the time,
  because idle time was counted as user time.
- Temperatures work again on Intel Macs. Every SMC request was the wrong size,
  so the temperature always read "??".
- The process list in the CPU menu includes system and other users' processes,
  which are often the busiest. It no longer shows the previous sample when the
  menu opens, and stays current while the menu is open.
- The network menu updates while it is open, instead of showing what it showed
  the last time. Link speeds are read without running a shell, and off the main
  thread. Connecting a VPN or PPP service from the menu can no longer crash
  MenuMeters.
- The disk menu no longer lists hidden system volumes or offers to unmount
  them, and a network server that stops answering no longer freezes it.
  External disks are ejected rather than only unmounted, and a failed eject
  says why.
- The memory menu shows the right cache hit rate (it showed 9530% for 95.3%)
  and memory pressure (it showed the memory still available).
- A meter turned back on after being dragged out of the menu bar appears
  again, instead of staying invisible.
- MenuMeters adds itself to the login items on first launch only. The new
  Startup checkbox in the About tab changes it.
- Starting an older copy while a newer one runs no longer shows every meter
  twice.

## Automatic updates

MenuMeters checks for updates once a day and asks before installing one. The
Updates checkbox in the About tab turns the check off, and Check Now runs one.
Updates must be signed with this fork's key.

## New identity

This fork has its own bundle identifier, `it.salamacchine.menumeters`. Your
settings are copied over from earlier versions on the first launch.
