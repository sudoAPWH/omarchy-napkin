"""Reads and writes the napkin note store through file descriptors.

    python3 -I -S store-helper.py read  <absolute path>   -> store on stdout
    python3 -I -S store-helper.py write <absolute path>   <- store on stdin

Run by Store.qml as `/usr/bin/python3 -I -S store-helper.py ...`: an absolute
interpreter, `-I` so the environment and user site-packages can't influence it,
and `-S` so no site module runs either.

The panel never opens the store itself. Every folder from / down is opened with
O_DIRECTORY|O_NOFOLLOW and checked with fstat on the descriptor, and the file is
opened relative to that last descriptor, also with O_NOFOLLOW. Reads come from
the descriptor that was checked. Writes go to a fresh 0600 temporary created in
the same directory with O_CREAT|O_EXCL|O_NOFOLLOW, are fsynced, and then replace
the store by dir_fd. Nothing re-resolves a pathname after it has been checked,
so swapping a component or the destination afterwards cannot redirect a write:
the descriptors still point at what was verified.

Exit codes are turned into messages in Store.qml.
"""

import os
import stat
import sys

OK = 0
BAD_PATH = 10
NO_DIR = 2
SYMLINK_DIR = 3
NOT_DIR = 4
DIR_NOT_OURS = 5
DIR_OPEN_TO_OTHERS = 6
FILE_IS_SYMLINK = 7
NOT_REGULAR = 8
FILE_NOT_OURS = 9
FILE_OPEN_TO_OTHERS = 11
TOO_BIG = 12
PARENT_NOT_OURS = 13
IO_ERROR = 14
NO_FILE = 15

MAX_BYTES = 4 * 1024 * 1024


def fail(code):
    raise SystemExit(code)


def check_dir(fd, is_last, uid):
    info = os.fstat(fd)
    if not stat.S_ISDIR(info.st_mode):
        fail(NOT_DIR)
    mode = stat.S_IMODE(info.st_mode)
    if is_last:
        # The notes folder itself: ours, and closed to everyone else.
        if info.st_uid != uid:
            fail(DIR_NOT_OURS)
        if mode & 0o022:
            fail(DIR_OPEN_TO_OTHERS)
        return
    # A folder above it: root's or ours. Anyone else who can write in one could
    # replace what sits beneath it, except in a root-owned sticky folder like
    # /tmp, where the sticky bit already stops them renaming our entries.
    if info.st_uid not in (0, uid):
        fail(PARENT_NOT_OURS)
    if mode & 0o022 and not (info.st_uid == 0 and mode & stat.S_ISVTX):
        fail(DIR_OPEN_TO_OTHERS)


def open_dir(path, create):
    """Walk the folders of `path`, holding a descriptor for each in turn."""
    uid = os.geteuid()
    parts = [p for p in os.path.dirname(path).split("/") if p]

    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    check_dir(fd, not parts, uid)
    for index, part in enumerate(parts):
        if part == ".." or part == ".":
            os.close(fd)
            fail(BAD_PATH)
        try:
            nfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
        except FileNotFoundError:
            if not create:
                os.close(fd)
                fail(NO_FILE)
            try:
                os.mkdir(part, 0o700, dir_fd=fd)
                nfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except OSError:
                os.close(fd)
                fail(NO_DIR)
        except NotADirectoryError:
            # O_DIRECTORY|O_NOFOLLOW on a symlink gives ENOTDIR on Linux, not
            # ELOOP. The open has already been refused; this only picks which
            # message to report.
            try:
                is_link = stat.S_ISLNK(os.lstat(part, dir_fd=fd).st_mode)
            except OSError:
                is_link = False
            os.close(fd)
            fail(SYMLINK_DIR if is_link else NOT_DIR)
        except OSError as error:
            os.close(fd)
            # O_NOFOLLOW on a symlink is ELOOP, which is the whole point.
            fail(SYMLINK_DIR if error.errno == 40 else NO_DIR)
        os.close(fd)
        fd = nfd
        try:
            check_dir(fd, index == len(parts) - 1, uid)
        except SystemExit:
            os.close(fd)
            raise
    return fd


def check_file(fd, uid):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        fail(NOT_REGULAR)
    if info.st_uid != uid:
        fail(FILE_NOT_OURS)
    if stat.S_IMODE(info.st_mode) & 0o022:
        fail(FILE_OPEN_TO_OTHERS)


def read_store(dir_fd, name):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
    except FileNotFoundError:
        fail(NO_FILE)
    except OSError as error:
        fail(FILE_IS_SYMLINK if error.errno == 40 else IO_ERROR)
    try:
        check_file(fd, os.geteuid())
        # One byte past the cap, so "exactly at the cap" and "over it" differ.
        data = os.read(fd, MAX_BYTES + 1)
        while len(data) < MAX_BYTES + 1:
            chunk = os.read(fd, MAX_BYTES + 1 - len(data))
            if not chunk:
                break
            data += chunk
        if len(data) > MAX_BYTES:
            fail(TOO_BIG)
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    finally:
        os.close(fd)


def write_store(dir_fd, name):
    data = sys.stdin.buffer.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        fail(TOO_BIG)

    # Refuse to replace anything that isn't already our own regular file.
    try:
        existing = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
    except FileNotFoundError:
        existing = None
    except OSError as error:
        fail(FILE_IS_SYMLINK if error.errno == 40 else IO_ERROR)
    if existing is not None:
        try:
            check_file(existing, os.geteuid())
        finally:
            os.close(existing)

    temp = "." + name + "." + os.urandom(8).hex() + ".tmp"
    fd = os.open(
        temp,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
        dir_fd=dir_fd,
    )
    try:
        written = 0
        while written < len(data):
            written += os.write(fd, data[written:])
        os.fsync(fd)
    except OSError:
        os.close(fd)
        os.unlink(temp, dir_fd=dir_fd)
        fail(IO_ERROR)
    os.close(fd)

    try:
        os.replace(temp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    except OSError:
        os.unlink(temp, dir_fd=dir_fd)
        fail(IO_ERROR)
    os.fsync(dir_fd)


def main(argv):
    if len(argv) != 3:
        return BAD_PATH
    mode, path = argv[1], argv[2]
    if mode not in ("read", "write"):
        return BAD_PATH
    if not path.startswith("/") or path.endswith("/") or "\0" in path:
        return BAD_PATH
    name = os.path.basename(path)
    if name in ("", ".", ".."):
        return BAD_PATH

    try:
        dir_fd = open_dir(path, create=mode == "write")
    except SystemExit as exit_code:
        return exit_code.code
    try:
        if mode == "read":
            read_store(dir_fd, name)
        else:
            write_store(dir_fd, name)
    except SystemExit as exit_code:
        return exit_code.code
    except OSError:
        return IO_ERROR
    finally:
        os.close(dir_fd)
    return OK


if __name__ == "__main__":
    sys.exit(main(sys.argv))
