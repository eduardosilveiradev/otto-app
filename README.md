# One scroll helper, Reduce Motion everywhere: screenshots

Recorded on an iPhone 17 Pro simulator (iOS 27), Debug builds of `main` and of this branch, both running the same
`-scrollLab` script (`-refThread -longRef -noNotificationPrompt -scrollLab`): an 84-message thread, numbered so a
jump can't hide behind repeats, and one scroll event every ~3.6 s.

- `video/`: the whole run, main and this branch, with Reduce Motion off and on.
- `steps/`: for each step, main before and after the step, then this branch before and after.
- `steps/motion-burst-frames.png`: every recorded frame while eight messages land at once.

Scroll offset (points from the top of the thread) before and after each step, as the lab prints it:

| Step | main | this branch |
| --- | --- | --- |
| Receive while scrolled up | 4369 → 4369 | 4369 → 4369 |
| Typing dots on, then off, while up | 4369 → 4369 | 4369 → 4369 |
| Keyboard up while up | 4369 → 5850 (to the bottom) | 4369 → 4670 (up by the keyboard, same bubbles in view) |
| Keyboard down while up | 5850 → 5561 | 4670 → 4381 |
| Scroll from 700 to 590, which loads the older page | → 2478 (oldest bubble snapped to the top: a ~590 pt jump) | → 3068 (590 + the page's 2478: nothing on screen moves) |
| Keyboard up, send, receive at the bottom | stays at the bottom | stays at the bottom |
| Eight messages at once | slides in over ~9 frames | in place in one frame |

Reduce Motion on gives the same offsets.

The Gate spinner and the Study card flip aren't in the recordings: no fixture reaches them without a server.
