# Issue 234 parent-breadcrumb renders

`before.png` is the reusable-widget render from unmodified devkit master
`097edcfb3a892ae2d2ed9e7edf55513a9507f968`. Its narrow 280px and wide 560px
rows overflowed (the yellow/black and red Flutter overflow indicators are part
of the captured result).

`after.png` is the same fixture rendered by this change: it labels both widths,
shows the leading omission marker, retains nearest crumbs, truncates the long
title, and leaves the visible close control inside the row. These are Flutter
widget-test renders with Roboto loaded through `golden_toolkit`, not browser
captures.

The private command receipts and SHA-256 values are retained outside git.
