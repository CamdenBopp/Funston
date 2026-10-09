# Gunsmoke playback regression

This runner checks every reachable commit using a dedicated simulator and isolated source copies. It never resets the working checkout or clears phone data. The UI journey searches for GUNSMOKE01 and selects recording 1 (the current metadata resolves it to Billy the Kid), opens the real mini-player, waits for AVPlayer to report playing, verifies twelve seconds of sustained playback and a changing position, then pauses. The real live Archive audio URL is used. Each revision receives observational diagnostics; no transport logic is replaced.

Run `python3 Scripts/gunsmoke-regression/run_history.py`. Results, xcresults, UI trees/screenshots, compiler logs, and per-second player logs are retained under `output/gunsmoke-regression`. Existing manifest entries are resumable. The simulator UUID and package cache path at the top of the runner are machine specific. `python3 Scripts/gunsmoke-regression/summarize.py` derives a summary from the traces.

The initial runs used OTRR_Gunsmoke_Singles. That copy's Billy the Kid download returned HTTP 500 from one Archive media server, and the other listed server timed out. Those attempts are preserved in `original-copy` and `results-original-copy.jsonl`. Subsequent comparisons use the live alternate GUNSMOKE01 copy to distinguish transport code regressions from the unavailable original server.

A separate physical iPhone test uses the current build with artwork loading forcibly disabled. The no-artwork switch exists only in the isolated diagnostic snapshot. Its actual selected recording is identified in the JSON trace; the output filename `phone-production2-no-artwork` describes the intended control and must not be treated as proof that Production 2 was selected (recording 1 resolved to Billy the Kid).

The logs establish transport progress, item readiness, transferred bytes, volume/mute, audio session category, and output route. They do not record sound from the phone speaker. The source MP3 is independently decoded and checked for nonzero PCM samples. Actual audibility is corroborated by the user's report, rather than inferred from a Pause icon alone.
