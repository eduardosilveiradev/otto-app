# Search in the thread: screenshots

iPhone 18 Pro simulator, Debug build, against a local stand-in server whose
`/app/history` serves 120 made-up messages in English, Italian, Portuguese,
Japanese and emoji. The phone loads the newest 50 (`limit=50`), so the older 70
only turn up through search's one `limit=500` fetch. `-search <words>` opens the
search with those words typed, `-searchFocus` puts the keyboard up as a pull
does, and `-searchJump` taps the oldest match.

| # | State | How it was made |
|---|-------|-----------------|
| 1 | Idle | no search chrome: no button, no bar |
| 2 | Pulled open | the field under the header, keyboard up, composer out of the way |
| 3 | Matches for "perche" | finds "Perché", "perché" and "PERCHÉ"; Oct 9 and Oct 23 came from the 500 fetch, Nov 4 and Nov 10 were already on the phone. `-typing` is the same with the keyboard up |
| 4 | Other scripts | "coracao" finds "coração" (only in the older history), "駅" and "🍕" |
| 5 | No results | the system's search empty state |
| 6 | Searching older messages | history answers after 20 s |
| 7 | Fetch failed | history answers 500: "Couldn't load older messages · Retry", above the local matches or on its own |
| 8 | Largest text size | Accessibility XXXL; the results grow all the way, the bar stops at XXXL like the header |
| 9 | Jumped to an older match | the Oct 9 message, pulled into the thread with the ten before it, scrolled to the middle |

Light and dark for every state except 4. `overview-light.png` and
`overview-dark.png` put them side by side.
