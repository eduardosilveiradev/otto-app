# The twelve axes

Score Otto and each rival from 1 to 10 on each.

1. First run and pairing
2. Thread and composer
3. Voice
4. Thinking and working
5. Background work and notifications
6. Memory
7. Approvals and trust
8. System integration
9. Motion and haptics
10. Visual craft
11. Empty, error and offline states
12. Perceived speed

## The rivals

What the names turned out to be: "Grokbot" is xAI's **Grok Bot** (App Store id6794501026, about
92% sure); "GPT Dots" is OpenAI's **ChatGPT dots**; "Muse Agent" is Meta's **Muse**; "OpenBot" is
**openbot.run** by nightly-labs (about 85% sure); "Claude Duet" is Anthropic's research preview.

Rival scores come from the notes in `rivals/` (official docs, App Store listings, launch coverage,
reviews). None of the rivals' screens could be seen first-hand, so a `~` marks a score resting on
thin evidence: "nothing found" scores 5 or lower, never higher.

Added 17 Nov 2026, after the second run: each rival's App Store listing images can be fetched
through Apple's lookup API (`https://itunes.apple.com/lookup?id=<id>&country=us`, field
`screenshotUrls`), which the App Store web page did not give up. Ids: Grok Bot 6794501026,
ChatGPT 6448311069 (its listing shows no dot), Muse from Meta 6760173601, Claude Duet 6803276000,
OpenBot.run 6807024266. Neither run's reviewers saw them, so a next run should put them in the
review folder. They are marketing images: none shows an error, an empty page or a notification.

## Axes that only partly fit Otto

The four cloud agents run on a computer of their own, so "keeps working with every device off"
doesn't apply to an assistant that lives on your Mac (OpenBot shares that). Push needs APNs, which
the free signing team can't have; the server's Bark push covers it.
