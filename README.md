# Offline is not "gone": screenshots

iPhone 17 Pro simulator (iOS 27), Debug build, against a stand-in server whose
`/app/file/<id>` answers in a chosen mode. Two short threads so each fits on one
screen: `a-*` is a photo and a file, `b-*` is a study set and a card with an image.

| # | State | How it was made |
|---|-------|-----------------|
| 1 | Slow response, colour not known | 8 s delay, stored colours cleared for the launch: still neutral box |
| 2 | Slow response, colour known | 8 s delay after one earlier load: the box is the photo's average colour |
| 3 | Loaded | normal answer |
| 4 | Server error (500) | light and dark: "Couldn't load · Retry" |
| 5 | Offline | stand-in stopped, app relaunched: "Couldn't load · Retry", Otto asleep |
| 6 | Back online | stand-in started again, no relaunch: everything loaded by itself |
| 7 | Gone (404) | the only state that says "no longer available" |
| 8 | Server error, largest text size | the copy wraps without stranding the dot |

`overview-*.png` puts states 1 to 7 side by side.
