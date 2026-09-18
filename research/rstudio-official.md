# R-Studio official handoff research

Research date: 2026-09-16 (UTC)

## Scope and result

This research covers the Windows desktop product named R-Studio for Windows, not the Posit RStudio IDE, R-Studio Agent, or R-Studio Emergency. The vendor download page observed the Windows installer `RStudio9.exe` at version 9.5 build 191810, released 2026-06-20; the same page lists separate Emergency and Agent utilities.[7]

The official Windows help pages retrieved for this report have a 2026 R-Tools Technology Inc. copyright footer, but the deployed application version is still a runtime fact that must be recorded by the workflow.[11] The live Windows product and its licensed controls were not available in this Linux workspace, so executable identity, window behavior, and GUI controls remain a technician validation gate.

Recommended boundary: launch a verified R-Studio for Windows executable with the vendor-documented `-safe` switch, optionally with `-log <filename>` pointing to a case log on a safe destination, and stop at the R-Studio main panel.[11][16] Do not pass an invented folder, project, report, scan, or recovery argument, and do not automate a source selection, scan, mark, recovery, or destination confirmation.

A client folder can be opened separately with the Windows shell without starting R-Studio recovery, but the R-Studio documentation does not describe a startup argument that opens a folder in R-Studio. The similarly named `Open local folder (folders) when done` control is a Recover-dialog post-action that opens the recovered-files folder only after recovery completes.[3] Therefore the handoff may expose the client folder as a separate Explorer action, but opening that folder inside R-Studio is manual/unsupported and must not be represented as a vendor-supported handoff feature.

## Executable discovery and product identity

The official installation instructions say to run the downloaded `RStudio9.exe` setup file, warn not to install the program on the disk containing lost files, and allow the operator to modify the program installation destination.[12] The documented installer name is not proof of the installed application path or the final GUI executable name.

The download page lists `RStudio9.exe` as the main Windows download and separately lists `RStudioEmg9.exe` for the Emergency GUI startup-media creator, `RStudioAgentEn9.exe` for the network agent, and `RStudioAgentPortableEn9.exe` for the portable network agent.[7] A local recovery handoff must not accidentally launch an Agent executable or an Emergency media creator.

The inspected vendor pages do not document a fixed Windows install directory, registry key, installed GUI executable path, window class, or UI Automation contract. Do not hard-code a guessed path such as a `Program Files` location. Require an explicit operator/configured executable path and verify that the selected file is the intended R-Studio for Windows build before launch; if that identity check cannot be completed, stop at a manual gate.

R-Studio Technician may be installed on and run from a removable device, and the vendor says its portable version has the functionality of the installable version.[14] A portable handoff therefore also needs an operator-supplied path and product/version verification; it does not provide a documented universal discovery path.

The vendor's Windows system-requirements page says administrative privileges are required to install and run R-Studio utilities.[18] The workflow should report an elevation or launch failure rather than silently retrying another product or path.

## Documented Windows command-line surface

The official Windows help page says switches are for problems starting or working with R-Studio and enumerates the following surface.[11]

| Switch | Vendor-documented effect | Handoff disposition |
| --- | --- | --- |
| `-all_drives` | Forces R-Studio to show all logical disks instead of only local drives.[11] | Do not add by default; it changes visibility, not the selected source, and can increase operator ambiguity. |
| `-debug` | Adds debug information and exposes `Create FS Snapshot`; the vendor says it greatly slows R-Studio.[11] | Technician troubleshooting only; not a normal handoff argument. |
| `-flush` | Flushes the log file after each write to log operations; the vendor says it greatly slows R-Studio.[11] | Use only when a technician is diagnosing log-cache behavior. |
| `-log <filename>` | Writes the R-Studio log into the specified file; `-flush` may be used if the log remains cached.[11] | Supported for evidence logging if the path is on a non-source destination and its failure is surfaced. |
| `-mem <size in MB>` | Sets a memory limit for reconstructing the file tree; the vendor gives `-mem 400` as an example.[11] | Technician-selected performance option only. |
| `-no_ide_ext` | Disables the inquiry about extended HDD information in Windows 9x/ME.[11] | Legacy troubleshooting only; do not use for modern Windows handoff. |
| `-no_int13` | Disables disk access through Int13 in Windows 9x/ME.[11] | Legacy troubleshooting only; do not use for modern Windows handoff. |
| `-no_ios` | Disables the Windows 9x/ME protected-mode I/O system.[11] | Legacy troubleshooting only; do not use for modern Windows handoff. |
| `-reset` | Resets an HDD controller each time R-Studio reads a bad sector.[11] | Technician-selected bad-sector troubleshooting only. |
| `-safe` | Disables automatic partition search, file-system recognition on partitions, and other potentially problematic operations; the vendor says `Find partition` must then be used manually.[11] | Best documented candidate for a cautious handoff, but it is not documented as a write-protection switch. Keep all analysis and recovery actions manual. |

No path, folder, project, report, scan, recovery, source-selection, destination-selection, window-activation, or `open client folder` switch appears in this exhaustive Windows switch list.[11] Do not infer a positional path argument from another R-Tools product, another operating system, an installer filename, or a forum post.

The documented `-log <filename>` argument is a log destination, not a general report export or project file. The vendor separately documents GUI actions for saving scan information, event logs, recovery lists, and (Technician/T80+ only) forensic audit logs; those artifacts have different triggers and semantics.[4][5][15][19]

## Supported state and report-like artifacts

| Artifact or action | Officially documented behavior | Automation boundary |
| --- | --- | --- |
| Scan information, `*.scn` | Select an object and use `Save Scan Information`; the default extension is `*.scn`. The saved file contains information about the drive data structure gathered during the scan, not the actual drive data, and it can later be loaded with `Open Scan Information`.[4] | This is scan state, not a startup project or a drive image. Saving it to the object being scanned is explicitly unsafe.[4] Creation and loading remain technician-controlled unless a future vendor interface is verified on the target build. |
| Event log | R-Studio displays events in the Log panel; the operator can right-click the panel and select `Save Log to File`.[5] Settings also provide `Save log to file` and event-type filters.[6] | A log file can support case evidence, but it is not a documented report-generation command. The vendor warns never to write a log file on the disk from which data is being recovered.[6] |
| Recovery list | R-Studio can export a list of files/folders and import it later to mark files for recovery. All versions support a plain-text list with basic functionality; Technician/T80+ additionally supports HTML, XML, JSON, and CSV formats.[19] | An imported list marks files; it does not start recovery. Any list editing, import, marking, output-folder choice, and recovery confirmation must remain explicit operator actions. |
| Forensic audit log | Forensic Mode is available only in R-Studio Technician/T80+, is enabled from Settings, and creates an audit log during file recovery containing hardware-configuration information and MD5 values for recovered files.[15] | This is a recovery-time, license-specific audit feature, not a startup report or project. Enabling it, entering case information, selecting its output folder, and reviewing the result remain technician-controlled. |

The official Windows help navigation and switch page describe scan information, logs, recovery lists, and forensic mode, but do not document a general R-Studio project file or a command-line report export for the handoff.[11][4][5][15][19] Do not rename or treat a `.scn`, recovery list, or event log as a project without vendor evidence.

## Safe launch behavior

The main-panel documentation says that when R-Studio starts, its main panel appears on the Windows desktop.[16] The documented basic-recovery sequence then requires the operator to open a logical disk or select `Open Drive Files`, select files/folders, click `Recover` or `Recover Marked`, specify recovery options and an output folder, and click `OK`.[3]

The documented scan sequence likewise requires the operator to select an object, click `Scan`, specify scan parameters, and click `Scan` again.[4] These documented sequences support a narrow conclusion: launching the application to its main panel does not itself constitute a scan or file recovery action.[3][4][16]

The `-safe` switch is useful for handoff because it suppresses automatic partition search and file-system recognition until the operator invokes `Find partition` manually.[11] The switch does not promise that every possible write-capable or analysis-capable control is disabled.

R-Studio Settings documents an `Enable Write` option for Technician/T80+ that enables changes made in the text/hexadecimal editor and enables wiping objects in R-Studio and R-Studio Corporate.[6] The same page says R-Studio will never write anything on the drive from which data is being recovered or an image is being created, but this does not remove the need to keep the source read-only and to block write-capable features in this workflow.[6]

The basic-recovery documentation warns never to save recovered files/folders to the same logical disk where they reside.[3] If the destination has no space, the documented dialog offers another place, skipping the file, or aborting recovery; it does not authorize an automatic redirect.[3]

## Window activation and technician-controlled boundary

The official documentation identifies the main panel and menu/control names, but it does not specify a Windows window title/class, process-to-window contract, Win32 handle protocol, foreground/activation API, or UI Automation identifiers.[16][11] Window focus and activation are therefore not a vendor-supported automation surface. The implementation may launch the verified process and record its readiness, but must leave focus, source selection, scan configuration, file marking, recovery options, destination selection, and completion confirmation to the technician unless live validation proves a documented or stable target-build interface.

Technician-controlled actions are:

- verify the source device and keep it read-only;
- verify physical-disk separation of the recovery destination before any output action;
- choose whether to enumerate a partition, scan a drive, load `.scn` state, or stop;
- choose and review files or folders to recover;
- choose recovery options and the output folder;
- enable any license-specific forensic/audit mode and enter its case data;
- handle prompts for bad sectors, invalid names, low space, activation, and errors;
- never enable `Enable Write`, edit source metadata, wipe objects, or use a text/hexadecimal editor write path in this workflow.[3][4][6][15]

A safe implementation contract is:

1. Resolve an explicit operator/configured R-Studio for Windows path; verify product identity and record the observed file version/build.
2. Launch only the verified executable with `-safe`; add `-log <filename>` only when the log path is safe and writable. Do not pass the client folder as an undocumented R-Studio argument.[11]
3. If the user requirement is to expose the client folder, open it as a separate Windows Explorer action after verifying the folder path. Do not confuse that shell action with R-Studio folder opening.
4. Wait for and record process/window readiness, then require technician confirmation that the R-Studio main panel is visible. Do not use screen coordinates or guessed control names.
5. Surface every missing executable, launch failure, unexpected version, activation prompt, destination issue, or unsupported vendor operation as a stop/manual gate.

## Evidence limits and live validation

This report is based on the official R-Tools Technology Inc. Windows download page and Windows help pages retrieved on 2026-09-16, plus the linked official help topics cited below. The download page's current observation is 9.5 build 191810, but it does not prove that every installed or future build accepts identical behavior.[7]

A technician with the licensed target R-Studio edition must validate, on a disposable recovery case, the actual executable path, version/build reporting, startup arguments, `-safe` behavior, log output path, window readiness, and the exact boundaries around source selection and recovery. No claim in this document authorizes automatic scanning, recovery, destination selection, partition changes, wiping, or source writes.

## Sources

[3] https://www.r-studio.com/Unformat_Help/basicfilerecovery.html - Basic File Recovery
[4] https://www.r-studio.com/Unformat_Help/discscan.html - Drive Scan
[5] https://www.r-studio.com/Unformat_Help/eventlog.html - Event Log
[6] https://www.r-studio.com/Unformat_Help/r-studio_settings.html - R-Studio Settings
[7] https://www.r-studio.com/Data_Recovery_Download.shtml - R-Studio Download
[11] https://www.r-studio.com/Unformat_Help/r-studioswitches.html - R-Studio Switches
[12] https://www.r-studio.com/Data-Recovery-Install-Register-Activate.html - Installation, Activation and Uninstallation instructions for R-Studio
[14] https://www.r-studio.com/Unformat_Help/portable-version.html - Portable version
[15] https://www.r-studio.com/Unformat_Help/forensic_mode.html - Forensic Mode
[16] https://www.r-studio.com/Unformat_Help/r-studio_main_panel.html - R-Studio Main Panel
[18] https://www.r-studio.com/Unformat_Help/systemrequirements.html - System Requirements
[19] https://www.r-studio.com/Unformat_Help/lists_of_files_to_recover.html - Recovery Lists
