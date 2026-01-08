from __future__ import annotations
import argparse
from pathlib import Path
import sys

#Commands to run:
# python rename_files.py "WG_Users_CONF" --dry-run
# python rename_files.py "WG_Users_CONF"

def next_available_name(directory: Path, stem: str, ext: str) -> str:
    """Return a non-colliding filename like 'stem.ext', or 'stem-1.ext', ..."""
    candidate = f"{stem}{ext}"
    i = 1
    while (directory / candidate).exists():
        candidate = f"{stem}-{i}{ext}"
        i += 1
    return candidate


def compute_target_name(src: Path) -> str | None:
    """Given a .conf file Path, compute the new basename or None if unchanged."""
    # src.suffix is '.conf'; we want the portion before first '@'
    base = src.stem  # name without extension
    pre = base.split('@', 1)[0]
    if pre == base:
        return None  # no change
    return pre + src.suffix


def rename_in_directory(root: Path, recursive: bool = False, dry_run: bool = False) -> tuple[int, int]:
    """Rename all .conf files under 'root'. Returns (renamed_count, skipped_count)."""
    renamed = 0
    skipped = 0

    it = root.rglob('*.conf') if recursive else root.glob('*.conf')
    for file in it:
        if not file.is_file():
            continue
        target_basename = compute_target_name(file)
        if target_basename is None:
            skipped += 1
            continue
        target = file.with_name(target_basename)
        if target.exists():
            stem = target.stem
            ext = target.suffix
            target = file.with_name(next_available_name(file.parent, stem, ext))
        if dry_run:
            print(f"[DRY-RUN] {file.name} -> {target.name}")
        else:
            file.rename(target)
            print(f"Renamed: {file.name} -> {target.name}")
        renamed += 1

    return renamed, skipped


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="Rename .conf files by removing '@domain' from the filename.")
    p.add_argument('path', nargs='?', default='.', help='Directory to process (default: current directory)')
    p.add_argument('-r', '--recursive', action='store_true', help='Recurse into subdirectories')
    p.add_argument('--dry-run', action='store_true', help='Preview changes without renaming files')
    args = p.parse_args(argv)

    root = Path(args.path)
    if not root.is_dir():
        print(f"Error: '{root}' is not a directory", file=sys.stderr)
        return 1

    renamed, skipped = rename_in_directory(root, recursive=args.recursive, dry_run=args.dry_run)

    summary = "Dry-run complete." if args.dry_run else "Done."
    print(f"{summary} Renamed: {renamed}; Unchanged: {skipped}.")
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))