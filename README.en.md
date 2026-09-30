# Aduana

**Security kit for USB flash drives on Windows and macOS.** It checks the drives people lend you
before you trust them, and prepares your own before you lend them.

[Español](README.md)

> Aduana reduces risk, it does not remove it. Read [what it does not do](#what-it-does-not-do)
> before relying on it.

Aduana means *customs* in Spanish: inspection on the way in, declaration on the way out. The
commands are in Spanish and every one has an English alias (`inspect`, `copy`, `verify`,
`out prepare`...). Run `aduana help` to see them all.

## Why

A borrowed drive no longer runs anything by itself when plugged in: Windows dropped USB autorun in
2011 and macOS never had it. Today's risks are different:

- **Disguised files.** A shortcut with a folder icon replacing the real, now hidden, folder; an
  `invoice.pdf.exe`; or a name with invisible characters that flip the extension around.
- **Files from a USB drive carry no mark of origin.** A downloaded document opens in Protected View
  and a downloaded app goes through Gatekeeper, but the same file copied from a drive **does not get
  that mark** and the OS trusts it. Aduana copies files and adds the mark, so the built-in defenses
  work again.
- **The drive that is really a keyboard.** A BadUSB device announces itself as a keyboard and types
  commands at full speed. Scanning files is useless against it, so Aduana checks what else the device
  exposes, and can lock the session if a new keyboard shows up.

When lending your own drive the risk goes the other way: recoverable deleted files, photos with GPS
location, documents with your name and your company's, and the clutter each OS leaves behind.

## Usage

```sh
# Inbound: someone lends you a drive
aduana prepare-host                 # once, hardens this computer (restore-host undoes it)
aduana sentinel --durante 60        # optional, watches for a new keyboard while you plug it in
aduana mount <disk>                 # mounts it read-only
aduana inspect <volume>             # report of what is there and what it pretends to be
aduana copy <volume> <destination>  # copies what is not dangerous, with the mark of origin
aduana verify <volume>              # checks the signature if someone prepared it with Aduana

# Outbound: you prepare a drive to lend
aduana out prepare <disk>           # wipes and formats as exFAT
aduana out clean <volume>           # removes OS clutter and personal metadata
aduana out check-capacity <volume>  # detects drives that lie about their size
aduana out sign <volume> --clave ~/.ssh/id_ed25519
aduana out encrypt <folder>         # AES-256 encrypted archive, if 7-Zip is installed
```

On Windows the scripts are unsigned, so run them for that session only instead of relaxing the
policy for the whole machine:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\Aduana.ps1 help
```

Exit codes: `0` nothing dangerous or suspicious, `1` suspicious findings only, `2` dangerous findings
or failed signature, `3` usage or environment error. Every review command accepts `--json`.

## What it does not do

- It does not detect BadUSB from its files, because it needs none. It checks whether the device also
  announces a keyboard and can lock the session while watching. There is a race window.
- It does not read the drive's firmware, which can lie about what the device is.
- It does not protect against destructive hardware such as USB Killer.
- It does not protect against OS bugs in the USB stack or filesystem drivers, triggered on plug-in.
- It is not an antivirus. It uses the OS one and looks for deception patterns.
- On macOS it does not prevent automount. There is a window before Aduana remounts read-only.
- `out prepare` wiping is not forensic. Flash wear leveling keeps copies the OS cannot see.

If a drive truly worries you, do not plug it into your computer. Use a disposable machine, a VM, or
a dedicated station such as [CIRCLean](https://www.circl.lu/projects/CIRCLean/).

## Security

See [SECURITY.md](SECURITY.md). Please do not open public issues for vulnerabilities.

## License

[Apache-2.0](LICENSE).
