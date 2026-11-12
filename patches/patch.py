import pathlib
import sys

CHANGES = [
        ("name", "node.gyp", "'node_lib_target_name%': 'libnode',", "'node_lib_target_name%': 'libnode22',"),
        ("name", "configure.py", "  else:\n    shlib_suffix = 'so.%s'\n", "  else:\n    shlib_suffix = 'so'\n"),
]


def main():
        root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
        if not (root / "src" / "node.h").is_file():
                sys.exit(f"{root} isn't a Node source folder (no src/node.h)")
        for change, name, old, new in CHANGES:
                path = root / name
                text = path.read_bytes().decode()
                found = text.count(old)
                if found != 1:
                        sys.exit(f"{change}: {name}: the text to change was found {found} times, not once: Node's source has moved on, update patches/patch.py")
                path.write_bytes(text.replace(old, new).encode())
                print(f"{change}: {name}")


main()
