# First CDJ test: USB export

About 30 minutes on any CDJ-2000NXS2, CDJ-3000 or XDJ. The full matrix is in `dj-usb-format.md` › Needs a real player; this is the first pass.

## Bring

- A USB stick formatted **exFAT** or **FAT32** with nothing on it (Disk Utility › Erase › MS-DOS (FAT) or ExFAT, Master Boot Record). A second stick that already has a rekordbox export is a bonus.
- A Mac build with this branch.
- In Prep, 4 to 8 local tracks: at least one mp3, one m4a/aac and one wav or aiff. Give at least two of them:
  - a locked beat grid (Set Downbeat and Lock);
  - hot cues A, B and H, one of them a hot loop;
  - a memory cue and a memory loop;
  - a comment and a track colour.
- Put them in two playlists, sharing one track.

## On the Mac

1. Plug in the blank stick. Prep › Export to USB… (⇧⌘E).
2. Tick both playlists. Mode: **Blank Stick (Root)**. Check that the Ready count matches and any tracks with no file are listed.
3. Export. Watch the stages finish. Note the time it took.
4. On "Done. You can unplug the stick.", pull the stick **without ejecting**. This is on purpose.

## On the player

Load the stick and check:

1. **Browse.** The stick mounts with no "repair" or "not rekordbox" warning. Playlist shows both playlists in the right order, with the shared track in both. Artist, Album, Key and BPM browsing work, and accented titles look right.
2. **Load and play** each format. Note anything that won't load.
3. **Beat grid.** The first beat and bar markers sit on the kick, and the BPM shown matches Prep. Quantise and beat sync to a second deck hold.
4. **Hot cues.** A, B and H are in the right places, with the right pad colours and names. The hot loop loops.
5. **Memory cues and loops.** They show on the waveform and in the memory list, in the right places with their comments. The loop length is right.
6. **Waveforms.** The overview and the zoomed waveform both draw. On a CDJ-3000, try the 3-Band waveform in settings.
7. **Seeking.** Jump around an mp3 using needle search and cue jumps. Check it stays in time.
8. **Settings survive.** Put the stick back in the Mac. Prep's source picker reads it back (Add Stick) with the same cues and grid.

If you have the stick with a rekordbox library on it, also run **Replace Library** on it. Check that the player sees the new library and that a `PIONEER.before-sounding-…` folder is left on the stick.

## Report back

- Player model and firmware, and the stick's format and size.
- For each of the 8 checks: pass or fail. For each fail, a phone photo of the screen.
- Any track that wouldn't load, with its format.
- How far off the grid or a cue was, in beats or ms, if it was off.
- The export time and the number of tracks.
- Zip `PIONEER/` and `SOUNDING-EXPORT.json` from the stick (not `Contents/`) and send them over.
