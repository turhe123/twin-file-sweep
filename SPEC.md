# TwinFileSweep — specification

**Tagline:** Find exact duplicate files in chosen folders and trash the extra copies safely with a clear keep-one preview.

**Category:** Files & Conversion

**Inspired by (paid):** Gemini 2 ($19.95 one-time)

**Frameworks:** SwiftUI, AppKit, Foundation, CryptoKit, UniformTypeIdentifiers

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does and evidence of demand. Gemini 2 from MacPaw finds duplicate and similar files, shows them in groups and lets you remove the extras. It costs about 19.95 dollars as a one-time purchase, is a long-time Setapp catalog title and gets recommended in cleanup threads on r/macapps and r/macos whenever someone has a messy Downloads or photo folder. Our version handles exact duplicates only, which covers the most common need and keeps the code small.

Feature set for our clean-room version. A window app. The user drops or chooses one or more folders, optionally sets a minimum file size such as 100 kilobytes, and presses Scan. The scanner groups files first by size, then by a quick hash of the first and last chunk, then by a full SHA-256 digest computed with CryptoKit in streaming chunks, so only plausible candidates are fully read. Results appear as groups. Each group shows file name, folder, size, modified date and a small Quick Look thumbnail. The app auto-selects extra copies by a rule chosen from a menu: keep oldest, keep newest, keep the one with the shortest path or keep the one in the first folder added. Totals show how much space will be reclaimed. Buttons: Move Selected to Trash, Reveal in Finder and Skip Group.

UI spec. One window with a left panel listing the folders with a plus button, a size threshold stepper and checkboxes for Include hidden files and Include packages. The main area is a list of groups with disclosure triangles and checkboxes per file. A footer shows total groups, total reclaimable size and the primary button. A progress bar with the current phase name (Sizing, Sampling, Hashing) shows during the scan along with a Cancel button. Empty state: a drop zone reading Drop folders to look for duplicates. After a scan with no results show a pleased no duplicates found message. Keyboard: Command O to add a folder, Command Return to scan, Delete to trash selection.

Technical approach. Enumerate with FileManager and URLResourceValues for size, is regular file and content modification date. Use a TaskGroup with limited concurrency to hash candidates in parallel, reading with FileHandle in 1 megabyte chunks and updating SHA256 from CryptoKit. Keep a safety rule that at least one file in every group must remain unselected, enforced in the model so the Trash button cannot be enabled otherwise. Trashing uses FileManager trashItem so everything is recoverable. Thumbnails come from QuickLookThumbnailing if desired, otherwise NSWorkspace file icons keep it simpler. Folder access prompts come from the system when reading protected locations, and the app is not sandboxed or uses user-selected file access via open panel or drag and drop, so no special entitlement flow is needed. Save the last folders and rule choice with AppStorage.

Edge cases and error handling. Skip symbolic links and aliases. Treat hard links to the same file identifier as one file so they are never reported as duplicates of each other. Ignore zero byte files. Handle files that vanish or change during the scan by dropping them from the group. Report unreadable files in a collapsible warnings section. Do not scan inside application bundles or the Photos library package by default, and warn if the user adds one. Cancel stops all child tasks quickly. Keep the code near 550 lines.
