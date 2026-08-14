#!/usr/bin/env python3
"""Package this addon as a release zip.

Produces dist/<AddonName>-<version>.zip, with the addon files under a single
top-level <AddonName>/ folder — the layout WoW requires. The folder name is
taken from the .toc filename rather than from the working directory, so the
archive is correct even if you cloned into DeathlogWatch-main or similar.

Uses only the Python standard library.

    ./package.py                 build dist/DeathlogWatch-1.0.0.zip
    ./package.py --no-readme     omit README.md from the archive
    ./package.py --out /tmp      write the zip somewhere else
    ./package.py --list          show what would be packaged, build nothing
"""

from __future__ import annotations

import argparse
import fnmatch
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent

# Directories skipped wherever they appear.
EXCLUDE_DIRS = {
    ".git",
    ".github",
    ".idea",
    ".vscode",
    "__pycache__",
    "dist",
}

# Exact filenames skipped wherever they appear.
EXCLUDE_FILES = {
    ".gitignore",
    ".gitattributes",
    ".gitmodules",
    ".editorconfig",
    ".DS_Store",
    "Thumbs.db",
    "package.py",
    "luac.out",  # dropped by `luac -l` when inspecting bytecode
}

# Glob patterns matched against the filename.
EXCLUDE_GLOBS = [
    "*.zip",
    "*.bak",
    "*.orig",
    "*.rej",
    "*.swp",
    "*.swo",
    "*.pyc",
    "*~",
]

# The GPL requires the license text to travel with the work, so this is
# never dropped regardless of the flags passed.
ALWAYS_INCLUDE = {"LICENSE"}


def fail(msg: str) -> "None":
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(1)


def find_toc() -> Path:
    tocs = sorted(ROOT.glob("*.toc"))
    if not tocs:
        fail(f"no .toc file found in {ROOT}")
    if len(tocs) > 1:
        names = ", ".join(t.name for t in tocs)
        fail(f"expected exactly one .toc, found several: {names}")
    return tocs[0]


def read_version(toc: Path) -> str:
    for line in toc.read_text(encoding="utf-8-sig").splitlines():
        stripped = line.strip()
        if stripped.lower().startswith("## version:"):
            version = stripped.split(":", 1)[1].strip()
            if version:
                return version
    fail(f"no '## Version:' directive in {toc.name}")


def toc_referenced_files(toc: Path) -> list[str]:
    """File paths the .toc tells WoW to load, in order.

    Everything that is blank or starts with # is metadata or a comment.
    """
    refs = []
    for line in toc.read_text(encoding="utf-8-sig").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        refs.append(stripped.replace("\\", "/"))
    return refs


def is_excluded(path: Path, exclude_readme: bool) -> bool:
    if path.name in ALWAYS_INCLUDE:
        return False
    for part in path.parts[:-1]:
        if part in EXCLUDE_DIRS:
            return True
    if path.name in EXCLUDE_FILES:
        return True
    if exclude_readme and path.name.lower() in {"readme.md", "readme.txt", "readme"}:
        return True
    return any(fnmatch.fnmatch(path.name, pat) for pat in EXCLUDE_GLOBS)


def collect(exclude_readme: bool) -> list[Path]:
    """Every packaged file, as paths relative to ROOT, in stable order."""
    found = []
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(ROOT)
        if not is_excluded(rel, exclude_readme):
            found.append(rel)
    return sorted(found)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Package this addon as a release zip.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--no-readme",
        action="store_true",
        help="omit README.md (it doubles as the in-game usage guide, so it is kept by default)",
    )
    parser.add_argument("--out", metavar="DIR", default=str(ROOT / "dist"), help="output directory (default: ./dist)")
    parser.add_argument("--list", action="store_true", help="list what would be packaged, then exit")
    args = parser.parse_args()

    toc = find_toc()
    addon = toc.stem
    version = read_version(toc)

    if ROOT.name != addon:
        print(
            f"note: directory is '{ROOT.name}' but the addon is '{addon}'.\n"
            f"      The archive will use '{addon}/' as its top-level folder, which is what\n"
            f"      WoW requires — but rename the working directory to match, or the addon\n"
            f"      will not load when you run it from here.",
            file=sys.stderr,
        )

    files = collect(args.no_readme)
    if not files:
        fail("nothing to package")

    # A .toc that lists a file which is not in the archive loads silently
    # broken in-game, so check before shipping rather than after.
    packaged = {f.as_posix() for f in files}
    missing = [ref for ref in toc_referenced_files(toc) if ref not in packaged]
    if missing:
        for ref in missing:
            print(f"error: {toc.name} loads '{ref}' but it is not in the package", file=sys.stderr)
        fail("refusing to build a package the .toc cannot load")

    if args.list:
        for rel in files:
            print(f"{addon}/{rel.as_posix()}")
        print(f"\n{len(files)} files, version {version}")
        return 0

    out_dir = Path(args.out).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    zip_path = out_dir / f"{addon}-{version}.zip"

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for rel in files:
            zf.write(ROOT / rel, arcname=f"{addon}/{rel.as_posix()}")

    total = sum((ROOT / f).stat().st_size for f in files)
    print(f"{zip_path}")
    print(f"  {len(files)} files, {total / 1024:.1f} KiB -> {zip_path.stat().st_size / 1024:.1f} KiB")
    for rel in files:
        print(f"  {addon}/{rel.as_posix()}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
