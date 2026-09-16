# File Scavenger - Independent Evidence Cross-Check

- Lane: t_2db371fc (independent verification lane; read-only research)
- Artifact owner: this file only: `research/file-scavenger-cross-check.md`
- Retrieval date: 2026-09-16 (all HTTP retrievals 06:53-07:02 UTC / 08:53-09:02 CEST)
- Method: primary vendor pages + full crawl of the official 7.1 online manual + direct
  inspection of the vendor-supplied Windows binary (strings, PE headers, version resource)
  + domain-wide Wayback CDX negative search + one third-party repository search.
- Independence: all findings below were produced from vendor/primary retrieval performed
  in this lane. The parallel lane artifact `research/file-scavenger-official.md` had not
  been written at 07:02 UTC, so no line-by-line diff was possible; section 9 gives the
  claims that must match for the two lanes to be considered corroborated.

## 1. Verdict

1. No vendor-documented command line, batch, script, project/config or silent/unattended
   mode exists for File Scavenger on Windows. Every documented scan, save and validation
   step is a GUI step. Confidence: high.
2. The supported automation surface for a technician workflow is therefore:
   (a) process/executable launch and liveness checks, (b) UI Automation against documented
   English control captions, (c) file-system observation of vendor-documented output
   artifacts, (d) explicit manual operator gates for everything unverified. Confidence: high.
3. The only non-GUI command-line-looking tokens observed in the vendor binary are installer
   self-management arguments and internal diagnostics/mini-console usage strings. None of
   them perform a scan or a recovery, and none may be used as scanner automation.
   Confidence: medium-high (string evidence only; no runtime test).
4. Exact vendor terminology is "Quick scan" and "Long scan"; the save step is "Save"
   ("Step 2: Save", "Save to" folder), and scan completion is explicitly a different state
   from save/recovery completion. Confidence: high.
5. Product builds observed at retrieval time: File Scavenger 7.1 (download labelled
   "7.1 beta (stable)", installer file dated 2026/09/09, embedded version resource
   `7.1.1.13`) and File Scavenger 6.1 (previous stable download). Confidence: high.

## 2. Sources and retrieval ledger

| # | URL | Retrieved | What it establishes |
|---|-----|-----------|---------------------|
| 1 | https://www.quetek.com/prod02.htm | 2026-09-16 06:53 UTC | Current product page: "File Scavenger(R) Version 7.1", supported Windows versions, file systems, licence tiers, "Advanced features in boldface require a premium or professional license" |
| 2 | https://www.quetek.com/download.htm | 2026-09-16 06:53 UTC | Download scope: "Download File Scavenger(R) 6.1 and version 7.1 beta (stable)"; 7.1 64-bit entry "(10.58 MB - 2026/09/09)"; 6.1 64-bit (6.85 MB); "You can run File Scavenger(R) without installing it on your computer."; download URL `https://www.quetek.com/bin/64fsu71.exe` |
| 3 | https://www.quetek.com/faq.htm | 2026-09-16 06:53 UTC | Administrator requirement; "When should I use the Quick versus Long scan?"; demo mode saves only the first 64 kilobytes of each file; same-drive save restriction; view filter usage |
| 4 | https://www.quetek.com/fs71man/FS_toc.htm | 2026-09-16 06:54 UTC | Manual table of contents (65 linked pages); menus listed are File/Edit/Options/View/Help - no command-line or scripting section |
| 5 | https://www.quetek.com/fs71man/afxc36xx.htm | 2026-09-16 06:54 UTC | "Select a scan mode": Quick scan (file system based, fast), Long scan (examines every sector), sequential naming `xlsx000001.xlsx`, scanning a disk number instead of a drive letter |
| 6 | https://www.quetek.com/fs71man/afxc9y91.htm | 2026-09-16 07:00 UTC | Four-step workflow: select scan mode, "Click Scan", "Click Pause at any time", "Step 2: Save", "Click Browse and choose a Save to folder on another drive", "Click Save", validate results |
| 7 | https://www.quetek.com/fs71man/afxc0ynh.htm | 2026-09-16 07:00 UTC | Main dialog controls: "Look for", "Look in", "Quick or Long scan", "Scan", file list status values, "Step 2: Save", "Save to", "Use folder names", "Save" |
| 8 | https://www.quetek.com/fs71man/afxc6s2v.htm | 2026-09-16 06:58 UTC | Status panel: Progress percentage, transfer rate, estimated remaining time, "Scan status", "Recovery status", message area; "If files are being saved, messages are also written to the file Recovery.log in the Save to folder." |
| 9 | https://www.quetek.com/fs71man/afxc0zmt.htm | 2026-09-16 07:00 UTC | Saving the current session: metadata-only session file, "The session can be restored and resumed later by reloading the session file. The disk does not have to be rescanned."; "Create a CSV file ... Saves the list of files being displayed to a CSV (comma-separated) file" |
| 10 | https://www.quetek.com/fs71man/afxc078l.htm | 2026-09-16 06:58 UTC | Scan log (journal) folder for long scans; "The scan journal folder must not reside on the drive holding the lost data."; "A separate scan journal folder must be used for each drive." |
| 11 | https://www.quetek.com/fs71man/afxc83mt.htm | 2026-09-16 06:55 UTC | "File Scavenger(R) has a safety check to prevent saving recovered files to the same drive being scanned."; override requires typing "Yes" in the "Overriding code" textbox |
| 12 | https://www.quetek.com/fs71man/afxc92b7.htm | 2026-09-16 07:00 UTC | File menu: Scan, Save, Pause, Advanced Volumes, Load VMDK/VHD/VHDX/sparse bundle, Properties/Preview, "Macros - Experimental.", Session (Load/Save), Disk Image, HexView, Exit |
| 13 | https://www.quetek.com/fs71man/afxc7j77.htm | 2026-09-16 07:00 UTC | Options menu: Scan options (Sector exclusion, Scan journal), Save options (Use Folder Names, Volume affiliation, Overwrite mode, Trace); "Trace - Use this command only if instructed by our Technical Support staff." |
| 14 | https://www.quetek.com/fs71man/afxc11b9.htm | 2026-09-16 07:00 UTC | Overwrite mode choices: "Use the more recent file" (default), "Generate a unique filename", "Overwrite", "Skip"; "Always use this response and do not ask this question again." |
| 15 | https://www.quetek.com/fs71man/afxc7jdz.htm | 2026-09-16 07:00 UTC | Sector exclusion; "Read from file - Loads the sector ranges from a CSV file ... Each line follows this format: first_sector,last_sector" |
| 16 | https://www.quetek.com/fs71man/afxc09wy.htm | 2026-09-16 07:00 UTC | Choose volumes dialog: "Entire drive (Long scan only)", "Specific volumes (Long scan only)", right-click "Add"; "Note that this command is internal to the program. It makes no changes to the drive." |
| 17 | https://www.quetek.com/afxc3wmk.htm | 2026-09-16 06:53 UTC | Install vs run-without-install procedure; "Use Windows Explorer to locate the file filescav.exe and double-click on it"; "Choose to run File Scavenger(R) without installation." |
| 18 | https://www.quetek.com/fs71man/afxc3ol4.htm | 2026-09-16 07:00 UTC | About dialog: "This window displays a copyright statement and the current software version number." |
| 19 | https://www.quetek.com/products3.htm | 2026-09-16 06:53 UTC | Editions Standard $69 / Premium $129 / Professional $249 for versions 6 and 7 |
| 20 | https://www.quetek.com/bin/64fsu71.exe | 2026-09-16 06:54 UTC | Binary actually downloaded and inspected in this lane (see section 3) |
| 21 | https://www.quetek.com/support2.htm | 2026-09-16 06:56 UTC | Support page: no occurrence of "command line", "batch", "script", "silent", "unattended", "SDK" or "API" |
| 22 | http://web.archive.org/cdx/search/cdx?url=quetek.com*&filter=original:.*(command\|batch\|script\|macro\|automat).* | 2026-09-16 06:59 UTC | Domain-wide URL index: one match, `quetek.com/dictionary/the-command-line.html`, which is a general "what is a command line" glossary page (now 404; retrieved via Wayback, content unrelated to File Scavenger) |
| 23 | https://api.github.com/search/repositories?q=%22file+scavenger%22+recovery | 2026-09-16 07:02 UTC | One repository, an unrelated "download File Scavenger Pro" page; no scripting/CLI wrapper projects found. GitHub code search was unavailable without authentication, so this is not exhaustive |

All URLs above returned HTTP 200 at retrieval time except item 22's live target page (404;
Wayback snapshot used).

## 3. Observed build / version evidence (primary, first-hand)

Vendor download inspected in this lane:

- URL: https://www.quetek.com/bin/64fsu71.exe
- Size: 11,164,584 bytes (download page states 10.58 MB, 2026/09/09)
- SHA-256: `b63592d5677605681f03969c62c821b854445ab1bf00ccc2b5733d1b3d6708ff`
- PE: 64-bit (`IMAGE_FILE_MACHINE_AMD64` 0x8664), 7 sections (.text .rdata .data .pdata
  .fptable .rsrc .reloc), PE link timestamp 2026-09-09T16:16:55Z, optional header magic
  0x20b (PE32+), subsystem 2 = `IMAGE_SUBSYSTEM_WINDOWS_GUI` (graphical application, no
  console subsystem)
- Embedded version resource (StringFileInfo 040904e4):
  - CompanyName: QueTek Consulting Corporation
  - FileDescription: File Scavenger (R) - Premium data recovery tool
  - FileVersion / ProductVersion / SpecialBuild: 7.1.1.13
  - InternalName / OriginalFilename: FileScav.exe (the vendor help text writes it as
    `filescav.exe`; Windows paths are case-insensitive, so discovery code must not assume
    one casing)
  - LegalCopyright: Copyrights (c) 1998-2026 QueTek Consulting Corporation. All rights reserved.
- Application framework markers: MFC document/view classes `CFilescavApp`, `CFilescavDoc`,
  `CFilescavView`, `CCommandLineInfo`, document template name `Filescav.Document`, debug
  path `C:\src\FileScavenger\x64\Unicode Release\FileScav.pdb`
- Localisation: UI strings present for English, Dutch, French, German, Italian, Portuguese,
  Spanish and Japanese. English captions are therefore available but a technician machine
  in another language will expose translated captions - UI Automation must not hardcode
  English-only Name matching without a documented fallback.
- Installer/self-management strings observed: `/uninstall`, `%s  /uninstall`,
  `"%s" /suicide %d`, `SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\QueTek %s`,
  `FileScavenger-Updater/1.0`, plus first-run prompts "Install File Scavenger on this
  computer." and "Start  File Scavenger without installation."
  -> these are installer/updater self-management arguments, not scanning switches.
- Internal diagnostic strings observed: `C:\quetek\$runs_list$.csv`,
  `c:\quetek\$runs_list$.*.csv`, `C:\quetek\$qcc_mxf$.csv`, `C:\quetek\$dumpall$.txt`,
  `C:\quetek\...` scratch paths, and a remote-drive socket mini-console
  ("Usage: open <filename> <mode>.", "Usage: read <handle> <offset> <size>.",
  "connect localhost 60001"). These are diagnostics/support surfaces; nothing in the
  vendor documentation exposes them and they must not be treated as automation interfaces.
  The `/MATCH:`, `/FIND:`, `/DEFINE:`, `/LOOKUP:` tokens in the same binary belong to the
  bundled libcurl DICT/HTTP client (neighbouring strings include `CLIENT libcurl 8.13.0-DEV`).

### 3.1 Negative evidence for a command-line interface

- Full crawl of the official 7.1 manual (`fs71man/`, all 65 pages linked from FS_toc.htm,
  fetched 2026-09-16 06:55 UTC) searched for: "command line", command-line switch/parameter
  wording, "batch", "script", "silent", "unattended", "automation/automate", "CLI",
  "command prompt", "exit code", "scheduled task", "SDK", "API".
  - Only hits: "automatically" (twice, in RAID/sector-value descriptions) and
    "command prompt window" (once, in the FAQ, describing where a user deleted files).
  - There is no page describing arguments, options, a config file, a project file, exit
    codes, or unattended operation.
- The download page, product page, support page and FAQ contain no CLI/batch/scripting
  text either.
- Domain-wide Wayback URL index found no QueTek page dedicated to a command line, batch
  file, script, macro or automation interface (single unrelated dictionary page).
- The downloaded binary contains no user-facing usage/help text for application arguments
  (no `Usage:`/`/?`/switch table for scanning; the `Usage:` strings found belong to an
  internal socket diagnostic mini-language).
- Residual uncertainty: manuals for older versions (3.2, 4.3, 5.3, 6.x) were not crawled
  page-by-page in this lane, only the 7.1 manual and the domain-wide URL index. If the
  project must support an older licensed build, that manual needs the same crawl.

## 4. Terminology map (use these exact words in code, logs and gates)

| Concept | Vendor wording | Source |
|---------|----------------|--------|
| Fast scan using file system structures | "Quick scan" | FAQ, afxc36xx.htm, afxc0ynh.htm |
| Exhaustive sector-by-sector scan | "Long scan" | FAQ, afxc36xx.htm, afxc0ynh.htm |
| Scan mode selector label | "Quick or Long scan" | afxc0ynh.htm |
| Start scanning | "Scan" (File menu "Scan", main dialog button "Scan") | afxc9y91.htm, afxc0ynh.htm, afxc92b7.htm |
| Suspend a running scan or save | "Pause" (File menu); "resume or abort" | afxc9y91.htm, afxc92b7.htm |
| Second stage tab | "Step 2: Save" | afxc9y91.htm, afxc0ynh.htm |
| Recovery destination control | "Save to" (folder) | afxc0ynh.htm |
| Start recovery of selected files | "Save" | afxc0ynh.htm, afxc92b7.htm |
| Keep original folder structure | "Use folder names" (Save option: "Use Folder Names") | afxc0ynh.htm, afxc7j77.htm |
| Scan source selector | "Look in" | afxc0ynh.htm |
| Scan criteria selector | "Look for" | afxc0ynh.htm |
| Per-file state after scan | "Good" or "Poor" (blank if undeterminable) | afxc0ynh.htm |
| Per-file state after recovery | "Saved", "Failed", "Skipped" | afxc0ynh.htm |
| Progress display | "Status panel" with "Progress", "Scan status", "Recovery status" | afxc6s2v.htm |
| Session state file | "Session" (Load/Save); file type "File Scavenger Session (*.fss)" | afxc0zmt.htm, afxc92b7.htm |
| Machine-readable listing | "Create a CSV file" ("list of files being displayed") | afxc0zmt.htm |
| Long-scan rescan accelerator | "Scan journal" / "Scan log" folder, "Enable journaling" | afxc078l.htm, afxc7j77.htm |
| Name-conflict behaviour | "Overwrite mode" (Use the more recent file / Generate a unique filename / Overwrite / Skip) | afxc11b9.htm |
| Same-drive write protection | "safety check"; override by typing "Yes" in "Overriding code" | afxc83mt.htm |
| Exit | "Exit" (File menu); close prompt string observed in binary: "Close File Scavenger?" | afxc92b7.htm, binary strings |
| Unsupported/experimental | "Macros - Experimental." (File menu) | afxc92b7.htm |

No other scan or recovery stage names exist in the vendor documentation. In particular the
documentation never uses "short scan", "deep scan", "carve", "signature scan", or
"recover stage" - those words must not appear as claims about vendor behaviour.

## 5. Observable states that can be tested without screen coordinates

Vendor-documented and usable as primary signals (high confidence):

| Signal | How it is observed | Vendor evidence |
|--------|--------------------|-----------------|
| Installed/portable executable identity and version | Read the executable's version resource from disk, e.g. `(Get-Item $exe).VersionInfo` (ProductName "File Scavenger", ProductVersion 7.1.1.13 in the build inspected). No GUI needed | afxc3ol4.htm (About shows version), section 3 |
| Process liveness / exit | Process object for the executable name; the app is a GUI subsystem binary, so window-less console detection is not possible | section 3 |
| Window title / window presence | Window handle and caption of the main frame (MFC doc/view frame; title strings "File Scavenger" observed in binary) | binary strings; afxc0ynh.htm for the dialog layout |
| Recovery progress log on disk | Vendor states that when files are being saved, messages are written to `Recovery.log` in the "Save to" folder | afxc6s2v.htm |
| Recovered output tree | Files under the "Save to" folder, optionally mirroring original folders when "Use folder names" is set | afxc0ynh.htm, afxc7j77.htm |
| Session snapshot | `.fss` session file created by "Session / Save"; reloadable via "Session / Load" | afxc0zmt.htm, afxc92b7.htm |
| File-list export | `.csv` written by "Create a CSV file" in the save-session dialog | afxc0zmt.htm |
| Long-scan journal folder | Journal folder contents chosen in "Scan journal"; journal is drive-specific and must not sit on the source drive | afxc078l.htm, afxc7j77.htm |
| Sector ranges input | A CSV of `first_sector,last_sector` lines can be read by "Sector exclusion / Read from file" (input direction only, not an output signal) | afxc7jdz.htm |
| Installed-state marker | Uninstall registry key `SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\QueTek <name>` (installer-installed copies only; portable runs leave no such key) | binary string; afxc3wmk.htm for portable mode |
| Support/diagnostic files | `C:\quetek\*.csv` / `.txt` scratch outputs seen in binary strings - undocumented, support-only, must not be relied on | binary strings |

Important limitations:

- The literal file name `Recovery.log` is documented by the vendor but was NOT found as a
  string in the binary inspected here (other log/journal strings were). Treat the exact
  file name and its format as "documented, not yet observed" and confirm it on the live
  machine before any automation depends on it.
- Whether the CSV export includes the per-file "Good/Poor" or "Saved/Failed/Skipped" status
  columns is not stated in the manual. Unknown until observed.
- No exit code, no result file, no machine-readable completion marker is documented.
  Completion detection must therefore combine: process state, Status panel state observed
  through UI Automation, and destination-folder evidence - with an operator gate.
- The status panel values ("Progress", "Scan status", "Recovery status", message area) are
  documented text labels, so UI Automation can read them by Name without screen
  coordinates, but this requires the live-machine validation gate (the app is a native MFC
  Windows app; actual exposed UIA/MSAA properties are unverified here).

## 6. Safety-relevant vendor behaviour (aligns with the repository invariants)

- Source is read-only by design: the program scans volumes directly and writes nothing to
  the source drive; the manual repeatedly warns not to write to the drive holding lost data
  (afxc83mt.htm, afxc078l.htm, afxc0zmt.htm, afxc7jdz.htm).
- Vendor's own same-drive protection: saving recovered files to the scanned drive is blocked
  by a "safety check"; overriding needs the text "Yes" in "Overriding code" (afxc83mt.htm).
  The workflow must never supply that override; it is an operator-only decision, and our
  contract already refuses same-physical-disk destinations.
- Destination/destination-loss rules: recovered output, session files and journal folders
  must all live off the source drive; CD/DVD destinations are rejected because they stage
  through the boot drive (faq.htm).
- Elevation: "Only accounts with Administrators privileges on a Windows(R) computer can run
  File Scavenger(R)." (faq.htm); the product page repeats the system-administrator
  requirement (prod02.htm). Preflight elevation checks remain mandatory.
- Licence/demo behaviour affects validation: in demo mode the program "only saves the first
  64 kilobytes of each file" (faq.htm), so a demo-mode run can look successful while the
  output is truncated; a licensed install is required for a meaningful end-to-end gate.
  Licence tiers gate advanced features ("Advanced features in boldface require a premium or
  professional license", prod02.htm) - relevant to RAID/NAS/virtual-disk cases.
- Overwrite semantics: four documented "Overwrite mode" behaviours, including "Overwrite"
  and "Skip", plus "Always use this response and do not ask this question again"
  (afxc11b9.htm). Automation must not set the persistent "do not ask again" answer, and must
  not choose "Overwrite" on the operator's behalf.
- Close behaviour: the binary carries the confirmation string "Close File Scavenger?" and
  "File Scavenger must be restarted." / "File Scavenger muss neu gestartet werden." The
  documented graceful exit is File > Exit (afxc92b7.htm); a close request raises a
  confirmation. Force close remains a guarded last resort, exactly as the repository
  contract requires.
- Journal reuse prompt: "A scan journal already exists in the folder. Do you want to
  overwrite it?" (binary string). Automation must not silently answer yes - this is the
  same class of hazard as overwriting an existing job.

## 7. Automation boundary (what a workflow may and may not do)

Documented and safe to build on:

1. Executable discovery (installed or portable), version read-out, elevation preflight.
2. Launching the product and, via UI Automation on documented English captions, driving:
   "Look for", "Look in", "Quick or Long scan", "Scan", "Pause", "Step 2: Save", "Save to"
   (via the Windows folder browser), "Use folder names", "Save", "Session / Save",
   "Session / Load", "Create a CSV file", and File > Exit.
3. Observing: process state, window presence, destination folder growth, `Recovery.log`
   (after live confirmation), `.fss`/`.csv` artifacts, journal folder, Status panel text.

Manual gates (must remain operator decisions, never scripted):

1. Licence entry/activation and licence-level feature availability.
2. Any "Yes" override of the same-drive "Overriding code" safety check.
3. Overwrite-mode choice, and "Always use this response and do not ask this question again".
4. Scan journal overwrite prompts.
5. RAID/spanned reconstruction parameters and "Advanced Volumes" configuration.
6. Sector exclusion ranges (diagnostic evidence from Technical Support).
7. Answering "Trace" (support-directed) and any support-directed diagnostic console.
8. Accepting a "Close File Scavenger?" prompt while a scan or save may still be running.
9. Force-closing the application.
10. Validation of recovered file contents.

Explicitly NOT available (no documented interface, do not invent):

- Any command-line switch for scan mode, source/destination selection, starting a scan,
  starting a save, or querying status.
- Any batch/project/config file that predefines a job (`*.fss` sessions are GUI-saved
  state, not a documented input contract; see the unresolved item below).
- Any silent/unattended flag, exit code or status query.
- Any scripting API/SDK. The File menu "Macros - Experimental." entry is the only
  automation-flavoured command in the manual, with no documented language, file format,
  version scope or support statement; the binary contains "Load and run a macro",
  "Macro files" and "Error occurred while processing macro file: %s." but nothing in the
  vendor documentation describes how to author or rely on a macro file. Treat as
  unsupported/manual-only (and do not ship a macro-based path without vendor confirmation).

## 8. Unresolved questions (must be answered on a live machine, with a licensed install)

1. Does passing a `.fss` session path as a process argument open that session? The binary is
   an MFC document/view app with `CCommandLineInfo` and a `Filescav.Document` template, and
   MFC provides default file-open parsing, but no vendor documentation claims this and it
   was not testable here. Do not assume it; test it read-only and record the result.
2. Exact name, location, rotation and format of `Recovery.log` in the "Save to" folder, and
   whether it is written for a scan-only run or only when saving files.
3. Whether the CSV export contains per-file status columns (Good/Poor, Saved/Failed/Skipped)
   and which columns exist.
4. Whether the Status panel text and buttons are reachable through UI Automation
   (UIA/MSAA) with stable Name properties, and whether those Name values follow the OS UI
   language rather than the product language setting.
5. Whether a portable (run-without-install) copy leaves any registry trace, and what the
   canonical executable name/path is in each supported install mode.
6. Behaviour of the "Skip"/"Overwrite" modes when the destination already holds a recovered
   file with the same name across separate runs (the manual explicitly calls the order of
   recovery unpredictable).
7. Whether a Long scan can be paused, the session saved, and the machine rebooted, and then
   resumed from the saved session plus journal folder - the manual implies yes for both
   mechanisms separately, but the combined flow is undocumented.
8. Whether any older licensed version in the field (5.3, 6.1) exposes an interface absent
   from the 7.1 manual. The 6.1 manual and earlier manuals were not crawled page-by-page here.
9. Whether the "Macros - Experimental." command can load a documented, stable macro file in
   any released build (vendor question; unsupported for this project until answered).

Confidence summary: high on "GUI-only, no documented CLI/batch/project automation" and on
terminology; high on the observed build facts; medium-high on binary-derived absence claims
(string evidence, single build, no runtime test); low/unknown on every item in section 8.

## 9. Cross-check checklist against the parallel lane artifact

At 2026-09-16 07:02 UTC `research/file-scavenger-official.md` did not exist, so no diff was
made. When it lands, the two lanes corroborate only if they agree on all of:

1. No command-line/batch/silent interface is documented -> GUI plus manual gates only.
2. Scan-mode names are exactly "Quick scan" and "Long scan".
3. Scan completion and save/recovery completion are distinct states ("Step 2: Save").
4. Vendor same-drive save protection exists and requires an explicit "Yes" override.
5. Recovery destination must be off the source drive; session and journal too.
6. Administrator privileges are required to run the product.
7. `*.fss` session files and the CSV export exist; the CSV is a convenience listing.
8. `Recovery.log` in the "Save to" folder is the documented progress/log signal.
9. "Macros - Experimental." is the only automation-flavoured command, undocumented.
10. Version scope: 7.1 (download "7.1 beta (stable)"), 6.1 previous stable; observed binary
    version resource 7.1.1.13 with SHA-256
    b63592d5677605681f03969c62c821b854445ab1bf00ccc2b5733d1b3d6708ff.

Any disagreement - especially any claim of a working command-line switch - must be resolved
against a primary vendor page or a live observation before implementation relies on it.

## 10. Reproducibility notes for this lane

- Manual crawl: fetched all 65 `.htm` pages linked from
  https://www.quetek.com/fs71man/FS_toc.htm (2026-09-16 06:55 UTC) and searched them for
  the automation terms listed in 3.1. No non-vendor tooling was needed.
- Binary analysis: vendor download retrieved over HTTPS, then inspected offline for PE
  headers, version resource and string tables. Nothing was executed: the vendor binary was
  never run, and no Windows machine or installed product was touched by this lane.
- No repository file other than this artifact was created or modified; no commits or pushes
  were made.
