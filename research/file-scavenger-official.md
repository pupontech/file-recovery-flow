# File Scavenger official automation research

## Scope and observation record

Research was performed against QueTek's public vendor pages and the linked File Scavenger 7.1 online help on 2026-09-16 (UTC).[1][8] The current workspace is Linux and has no installed or runnable Windows File Scavenger instance, so no live GUI, process, exit-code, UI Automation, or installed-license behavior was observed.[unverified]

The current QueTek download page is headed "Download File Scavenger 6.1 and version 7.1 beta (stable)". It lists a 6.1 x64 build, a 7.1 x64 beta marked stable with a 2026-09-09 date, a 6.1 32-bit build, and older 5.3/4.3/3.2 downloads.[1] The separate official `downloadv5.htm` page still presents File Scavenger 5.3 and dates its x64 download May 7, 2019.[2] The product page and the linked help tree identify the current product/help family as File Scavenger 7.1.[3][8]

The official `64fsu71.exe` download was also fetched for an artifact-level observation.[28] The response was HTTP 200 with `Last-Modified: Wed, 09 Sep 2026 16:30:04 GMT`, content length 11,164,584 bytes, and PE x86-64 format.[28] Its embedded version-resource strings reported `FileVersion`, `ProductVersion`, and `SpecialBuild` as `7.1.1.13`.[28] SHA-256 of the fetched file was `b63592d5677605681f03969c62c821b854445ab1bf00ccc2b5733d1b3d6708ff`.[28] This pins the inspected download, not an installed copy; the vendor's documented runtime version surface is Help > About (see below).[22][26]

## Determination: no supported unattended automation contract was verified

The reviewed official download, product, FAQ, and v7.1 help pages document a Windows GUI with menus, dialogs, buttons, and file artifacts.[1][8][23] A text sweep of the downloaded vendor documentation found no vendor-published command-line syntax, CLI switch table, general configuration-file schema, COM/SDK/API contract, event model, machine-readable state format, or exit-code contract.[1][8][23] This is a research finding about the public documentation reviewed, not proof that a private or undocumented interface does not exist.[unverified]

The File menu documentation does list `Scan`, `Save`, `Pause`, session Load/Save, and `Exit`; it also lists `Macros` as `Experimental`.[23] The downloaded 7.1 x64 artifact contains visible resource captions for loading/running a macro and macro files.[28] QueTek does not publish the macro grammar, commands, inputs, outputs, edition requirements, or completion semantics in the reviewed help.[8][23] The macro path must therefore remain unsupported/manual pending owner validation of the exact build; no macro syntax or switch should be invented.[7][23][28]

The project adapter should expose a manual gate for every scanner action unless a technician validates the exact installed build and records the observed interface.[unverified] Do not infer UI control names, command-line switches, macro syntax, COM selectors, completion rules, or license entitlements from the pages or binary strings.[unverified]

## Documented surface, by requested capability

| Capability | Exact vendor-documented surface | Safe automation boundary |
|---|---|---|
| Launch and installation | The vendor provides x64/x86 downloads and says File Scavenger can run without installation. The v7.1 install guidance names `64fsu71.exe`, recommends an indirect USB procedure when recovering the boot drive, and says to choose run-without-installation; direct installation is described for a data drive.[1][16] | An adapter may discover and record an explicit executable path, but no launch arguments, unattended mode, or launch-result protocol was verified. Require an operator/owner gate for launch and capture the About version before scanner work. |
| CLI parameters | No public vendor command-line invocation or parameter list was found in the reviewed docs. | None verified. Do not construct `FileScavenger.exe` switches. Treat any future CLI claim as unverified until the vendor documents it or a technician records a reproducible exact-build observation. |
| Configuration files | Documented file-based artifacts are session files, long-scan journal folders, sector-exclusion CSV input, CSV display export, disk images, virtual disk files, and (for the relevant license flow) license files. No general settings/configuration file schema is documented.[18][29][30][23] | Session/journal/CSV artifacts are not a substitute for a scanner automation API. Their paths and contents must be operator-supplied or explicitly validated. |
| Source/drive selection | The main dialog's `Look in` selects a volume or disk. The Choose volumes dialog supports Entire drive and Specific volumes for Long scan, and an Add command for additional undetected volumes; the help says Add is internal and makes no drive changes.[11][12] A mapped network drive must be handled on the computer where the drive physically resides.[11][35] | Source selection is a GUI/manual boundary. The project must independently identify the source physical disk and reject a destination on that disk; vendor volume/disk labels alone are not sufficient. |
| Scan modes | Quick scan is fast and uses the Windows file-system structure; it is recommended first for accidental deletion and broken RAID/spanned cases. Long scan examines every sector, is slower and noisier, and is intended for reformatted, repartitioned, or corrupted drives. For a corrupted drive, the help says scanning the disk number may work better than scanning its drive letter.[10][35] | The mode choice can be represented in job state, but starting a scan and confirming its target remain manual until exact-build controls are validated. Never silently switch from Quick to Long. |
| Search criteria and execution | `Look for` accepts file extensions, a filename, `*`, comma-separated patterns, exclusions in angle brackets, and (in Quick scan) folder-path patterns. The File menu's Scan command starts the scan.[11][23] | These are documented GUI inputs, not CLI parameters. Do not pass a guessed pattern through an undocumented interface. Record the operator's exact criteria. |
| Post-scan search/filter | The Find dialog searches the displayed file list for a term, with whole-word, case, and direction options.[13] View filters show only matching files by criteria such as filename text, size, or modified date and do not require a rescan.[25] | Find/filter is a post-scan display operation. It does not prove that a file is recoverable and must not be confused with the initial scan criteria. Keep it manual unless controls are validated. |
| Result selection | After scanning, Step 2: Save is selected. The operator checks files; Tree View can select folders or the entire drive. Results can be sorted/filtered. The file status after scanning may be Good or Poor; after recovery it may be Saved, Failed, or Skipped.[9][11][25] | Selecting results and deciding what to recover are manual gates. A Saved status still requires opening/validating the output; the vendor explicitly says it does not guarantee intact content.[11][19] |
| Volume affiliation | The Volume column identifies the volume associated with a result. QueTek says correct affiliation is necessary for successful recovery and documents expert-only override options for ambiguous or undetected volumes.[33] | Do not automate expert affiliation or sector values. Surface ambiguity as a manual gate and record the selected volume/disk identity. |
| Recovery destination | `Save to` accepts a path or Browse selection and must not be on the drive holding the lost data. The Save command starts recovery.[11] The vendor's same-drive safety check can be overridden by typing `Yes`, but the vendor describes that as a risk of permanent loss.[20] | The project must never use the override. Require a destination on a different physical disk, create a unique case folder, and stop on destination loss, low space, or any mismatch; never redirect output. |
| Existing destination names | The documented Overwrite mode offers use-more-recent, generate-unique-name, overwrite, or skip; the vendor warns that overwrite/skip behavior can be unpredictable.[21] | The project must not overwrite an existing job. Use a newly verified case folder and do not automate the vendor Overwrite choice. |
| Completion/progress detection | Status Panel shows percentage, transfer rate, estimated remaining time, scan file counts, recovery status, and warning/error messages. During saving, messages are also written to `Recovery.log` in the Save to folder.[19] The main dialog documents Good/Poor scan status and Saved/Failed/Skipped recovery status.[11] | No vendor event, callback, JSON state, or exit-code completion contract was found. Do not treat process exit, disappearance of a window, or a displayed 100 percent alone as proof of successful recovery. Require an operator-visible completion check, inspect the log/status, and validate recovered files. |
| Graceful pause/close | Pause pauses scanning or saving and permits later resume or abort. File > Exit is documented as quitting File Scavenger.[9][23] | No external graceful-close command or acknowledgement was documented. Do not close while work is active. After the operator confirms the operation is finished, use the documented Exit surface and verify termination; force close is a guarded manual last resort only after active recovery is known to be finished. |
| Session/resume | A session file stores filenames and attributes/metadata, not recovered data, and can be loaded later without rescanning. It must be stored on a drive other than the one being scanned.[18] File > Session > Load/Save provides the GUI entry points.[23] | Treat session files as operator-selected checkpoints, not as an automation protocol or proof of output. Verify source/disk identity and job state before loading; never rerun a completed stage automatically. |
| Long-scan journaling | A long scan can store hints in a journal folder for later rescans. The journal must not be on the lost-data drive and a separate folder is required for each drive.[29] | Journaling is an optional, manually configured optimization. Do not enable it by guessing a path or treat a journal as a completed scan result. |
| Sector exclusion input | The Sector exclusion dialog can read a CSV in which each line is `first_sector,last_sector`.[30] | This is a narrowly documented input format, not a general config or command interface. Only use it after a technician supplies and verifies the ranges; never generate ranges from uncertain geometry. |
| Version reporting | Help > About displays the current software version and copyright statement; the About dialog documentation says the same.[22][26] | Capture the exact About version/build on every live case and bind any validated adapter behavior to that build. Do not infer the installed build from a download filename or stale web page. |
| Remote drives | The v7.1 help calls remote drives experimental and says the feature will be available in version 8.[31] | Treat remote-drive operation as unsupported/manual for this workflow. Do not use it as a substitute for running on the physical host. |

## Licensing and version differences

The current product page lists File Scavenger 7.1 licensing as Standard (typical users, activation on 3 computers owned by the same person), Premium (power users, activation on 3 computers owned by the same person), Professional (data-recovery professionals, use on any computer by the registered licensee), and Company (negotiable).[3] The purchase page sells Standard, Premium, and Professional editions for versions 6 and 7 and states that a version 6 purchase on or after Jun 16 is valid for both version 6 and version 7.[4]

The v7 help describes Standard as standard features, Premium as standard plus advanced features for RAID/virtual-disk/advanced-file-system situations, and Professional as standard plus advanced and experimental features for data-recovery professionals.[14] The features page states that advanced features in boldface require a Premium or Professional license.[15] The help also documents demo mode: files smaller than 64 kilobytes may be saved, and picture files may be previewed.[14][17]

These pages do not map any edition to macro execution, a CLI/API, or unattended operation.[8][14][15][23] Do not assume that Premium or Professional licensing makes an undocumented automation surface supported.[unverified]

The public EULA page uses older Personal Use/Professional Use wording and older Windows version examples, grants only a non-exclusive right to use a copy, prohibits reverse engineering/disassembly/decompilation without written permission, disclaims recovered-data integrity, and describes three years of technical support.[7] Because this wording does not match every current product-page label,[3][7] record the exact installed version and license terms presented to the technician rather than resolving the discrepancy in code.[unverified]

## Implementation handoff and manual gates

1. Keep File Scavenger integration manual by default. The only safe prevalidated work is local job preparation, source/destination physical-disk checks, logging, and handoff prompts.[unverified]
2. At launch, require an explicit executable path, record the operator's About version/build, and stop if the version is not on the validated build list.[22][26]
3. Require the technician to select the source volume/disk, scan mode, search criteria, results, and destination.[9][11][12] Record each choice without relying on coordinates or guessed control names.[unverified]
4. Enforce a destination on a different physical disk and a new case folder. Never send the same-drive override, never redirect output, and stop on low space, destination loss, or an unclear application state.[20][21]
5. Treat Quick and Long as separate stages. A completed scan is not completed recovery. Require recovery status/log review and independent file validation before advancing.[9][11][19]
6. Use File > Exit only after the technician confirms scanning/recovery is complete. Verify the process/window state and surface uncertainty instead of force-closing silently.[23][unverified]
7. If unattended File Scavenger operation is required, obtain vendor documentation or an owner-run validation for the exact build that supplies the invocation, inputs, result selection, completion, failure, destination, and close semantics.[unverified] Until then, the adapter must report an unsupported/manual gate rather than guess.[unverified]

## Sources and method notes

The source list below is generated from the citation ledger.[unverified] Primary QueTek pages were preferred; search-engine results were not used as evidence.[unverified] Claims about the downloaded executable are artifact observations tied to the direct vendor URL, not claims that the binary exposes a supported API.[28] Live licensed Windows validation remains required.[unverified]

## Sources

[1] https://www.quetek.com/download.htm
[2] https://www.quetek.com/downloadv5.htm
[3] https://www.quetek.com/prod02.htm
[4] https://www.quetek.com/products3.htm
[7] https://www.quetek.com/eula.htm
[8] https://www.quetek.com/fs71man/FS_toc.htm
[9] https://www.quetek.com/fs71man/afxc9y91.htm
[10] https://www.quetek.com/fs71man/afxc36xx.htm
[11] https://www.quetek.com/fs71man/afxc0ynh.htm
[12] https://www.quetek.com/fs71man/afxc09wy.htm
[13] https://www.quetek.com/fs71man/afxc9pwk.htm
[14] https://www.quetek.com/fs71man/afxc7u79.htm
[15] https://www.quetek.com/fs71man/afxc86r7.htm
[16] https://www.quetek.com/fs71man/afxc3wmk.htm
[17] https://www.quetek.com/fs71man/trying_demo.htm
[18] https://www.quetek.com/fs71man/afxc0zmt.htm
[19] https://www.quetek.com/fs71man/afxc6s2v.htm
[20] https://www.quetek.com/fs71man/afxc83mt.htm
[21] https://www.quetek.com/fs71man/afxc11b9.htm
[22] https://www.quetek.com/fs71man/afxc181c.htm
[23] https://www.quetek.com/fs71man/afxc92b7.htm
[25] https://www.quetek.com/fs71man/afxc0853.htm
[26] https://www.quetek.com/fs71man/afxc3ol4.htm
[28] https://www.quetek.com/bin/64fsu71.exe
[29] https://www.quetek.com/fs71man/afxc078l.htm
[30] https://www.quetek.com/fs71man/afxc7jdz.htm
[31] https://www.quetek.com/fs71man/remote.htm
[33] https://www.quetek.com/fs71man/afxc1d0l.htm
[35] https://www.quetek.com/fs71man/faqs.htm
