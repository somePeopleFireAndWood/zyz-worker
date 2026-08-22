#!/usr/bin/env python3
"""Descriptor-only physical snapshot engine used by runtime_state.

The scanner deliberately has no Git command dependency.  It pins the caller's
cwd, discovers the first reciprocal worktree root through fd ancestry, binds
the task runtime component-by-component, writes raw length-prefixed spill
records, and externally merges them under real deadline/RSS/AS/temp ceilings.
"""
from __future__ import annotations

import base64
import ctypes
import errno
import hashlib
import heapq
import hmac
import json
import os
import resource
import stat
import struct
import sys
import time
from dataclasses import dataclass
from pathlib import Path


class NativeSnapshotError(Exception):
    pass


def _write_all(fd: int, payload: bytes, what: str) -> None:
    view=memoryview(payload)
    injected=os.environ.get("ZYZ_TEST_SHORT_WRITE") == what
    while view:
        amount=min(len(view),max(1,len(view)//2)) if injected else len(view)
        written=os.write(fd,view[:amount])
        if written <= 0:
            raise NativeSnapshotError(f"{what} write made no progress")
        view=view[written:]
        if injected:
            raise NativeSnapshotError(f"injected {what} short write")


AT_FDCWD = -100
AT_SYMLINK_NOFOLLOW = 0x100
AT_EMPTY_PATH = 0x1000
STATX_BASIC_STATS = 0x7FF
STATX_MNT_ID = 0x1000


class StatxTimestamp(ctypes.Structure):
    _fields_ = [("tv_sec", ctypes.c_int64), ("tv_nsec", ctypes.c_uint32), ("reserved", ctypes.c_int32)]


class Statx(ctypes.Structure):
    _fields_ = [
        ("mask", ctypes.c_uint32), ("blksize", ctypes.c_uint32),
        ("attributes", ctypes.c_uint64), ("nlink", ctypes.c_uint32),
        ("uid", ctypes.c_uint32), ("gid", ctypes.c_uint32),
        ("mode", ctypes.c_uint16), ("spare0", ctypes.c_uint16),
        ("ino", ctypes.c_uint64), ("size", ctypes.c_uint64),
        ("blocks", ctypes.c_uint64), ("attributes_mask", ctypes.c_uint64),
        ("atime", StatxTimestamp), ("btime", StatxTimestamp),
        ("ctime", StatxTimestamp), ("mtime", StatxTimestamp),
        ("rdev_major", ctypes.c_uint32), ("rdev_minor", ctypes.c_uint32),
        ("dev_major", ctypes.c_uint32), ("dev_minor", ctypes.c_uint32),
        ("mnt_id", ctypes.c_uint64), ("dio_mem_align", ctypes.c_uint32),
        ("dio_offset_align", ctypes.c_uint32), ("spare3", ctypes.c_uint64 * 12),
    ]


class AttrList(ctypes.Structure):
    _fields_ = [("bitmapcount", ctypes.c_uint16), ("reserved", ctypes.c_uint16),
                ("commonattr", ctypes.c_uint32), ("volattr", ctypes.c_uint32),
                ("dirattr", ctypes.c_uint32), ("fileattr", ctypes.c_uint32),
                ("forkattr", ctypes.c_uint32)]


def _mount_id_at(dirfd: int, name: bytes, opened_fd: int | None = None) -> str:
    libc = ctypes.CDLL(None, use_errno=True)
    if os.uname().sysname == "Linux" and hasattr(libc, "statx"):
        def call(fd: int, path: bytes, flags: int) -> int:
            value = Statx()
            if libc.statx(fd, path, flags, STATX_BASIC_STATS | STATX_MNT_ID, ctypes.byref(value)) != 0:
                raise OSError(ctypes.get_errno(), "statx")
            if not value.mask & STATX_MNT_ID:
                raise NativeSnapshotError("statx did not return STATX_MNT_ID")
            return int(value.mnt_id)
        by_name = call(dirfd, name, AT_SYMLINK_NOFOLLOW)
        if opened_fd is not None and call(opened_fd, b"", AT_EMPTY_PATH) != by_name:
            raise NativeSnapshotError("opened fd mount identity differs from name binding")
        return f"linux-statx:{by_name}"
    if os.uname().sysname == "Darwin" and hasattr(libc, "getattrlistat"):
        attrs = AttrList(5, 0, 0x00000004, 0, 0, 0, 0)  # ATTR_CMN_FSID
        buffer = ctypes.create_string_buffer(64)
        func = libc.getattrlistat
        func.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.POINTER(AttrList),
                         ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong]
        func.restype = ctypes.c_int
        if func(dirfd, name, ctypes.byref(attrs), buffer, len(buffer), 1) != 0:  # FSOPT_NOFOLLOW
            raise OSError(ctypes.get_errno(), "getattrlistat(ATTR_CMN_FSID)")
        length = struct.unpack_from("=I", buffer.raw, 0)[0]
        if length < 12 or length > len(buffer):
            raise NativeSnapshotError("invalid native FSID response")
        fsid = buffer.raw[4:12].hex()
        if opened_fd is not None:
            # fstatfs provides the same native fsid for the opened vnode.  The
            # opaque buffer is intentionally oversized; fsid_t begins after
            # the two uint32 and five uint64 fields in Darwin struct statfs.
            fsbuf = ctypes.create_string_buffer(4096)
            if libc.fstatfs(opened_fd, fsbuf) != 0:
                raise OSError(ctypes.get_errno(), "fstatfs")
            fd_fsid = fsbuf.raw[48:56].hex()
            if fd_fsid != fsid:
                raise NativeSnapshotError("opened fd native FSID differs from name binding")
        # FSID is filesystem-wide and cannot distinguish a second same-FSID
        # mount instance/bind boundary.  Until macOS exposes a per-mount vnode
        # identifier through this nofollow API, fail closed instead of claiming
        # that FSID satisfies the mount-instance contract.
        raise NativeSnapshotError("macOS per-vnode mount-instance identity is unavailable")
    raise NativeSnapshotError("native per-vnode mount identity is unavailable")


def mount_id_path(path: Path) -> str:
    parent = os.open(os.fsencode(path.parent), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) |
                     getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
    fd = -1
    try:
        fd = os.open(os.fsencode(path.name), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) |
                     getattr(os, "O_CLOEXEC", 0), dir_fd=parent)
        return _mount_id_at(parent, os.fsencode(path.name), fd)
    finally:
        if fd >= 0: os.close(fd)
        os.close(parent)


def _same_identity(left: os.stat_result, right: os.stat_result) -> bool:
    return _integrity_tuple(left) == _integrity_tuple(right)


def _integrity_tuple(value: os.stat_result) -> tuple[int, ...]:
    return (value.st_mode,value.st_rdev,value.st_dev,value.st_ino,value.st_nlink,
            value.st_size,value.st_mtime_ns,value.st_ctime_ns)


def _integrity_record(value: os.stat_result, mount_id: str) -> dict:
    return {"mode":value.st_mode,"rdev":value.st_rdev,"dev":value.st_dev,
            "ino":value.st_ino,"nlink":value.st_nlink,"size":value.st_size,
            "mtime_ns":value.st_mtime_ns,"ctime_ns":value.st_ctime_ns,
            "mount_id":mount_id}


def _record_integrity_tuple(value: dict) -> tuple[int, ...]:
    required={"mode","rdev","dev","ino","nlink","size","mtime_ns","ctime_ns","mount_id"}
    if not isinstance(value,dict) or set(value) != required or not isinstance(value["mount_id"],str):
        raise NativeSnapshotError("spill integrity identity schema is invalid")
    fields=("mode","rdev","dev","ino","nlink","size","mtime_ns","ctime_ns")
    if any(not isinstance(value[name],int) or isinstance(value[name],bool) for name in fields):
        raise NativeSnapshotError("spill integrity identity values are invalid")
    return tuple(value[name] for name in fields)


def _open_dir_at(parent: int, name: bytes) -> int:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    return os.open(name, flags, dir_fd=parent)


def _open_absolute_nofollow(path: bytes, directory: bool) -> int:
    if not path.startswith(b"/"):
        raise NativeSnapshotError("native absolute binding requires an absolute path")
    fd = _open_dir_at(AT_FDCWD, b"/")
    parts = [part for part in path.split(b"/") if part]
    try:
        for index, part in enumerate(parts):
            if part in (b".", b".."):
                raise NativeSnapshotError("dot components are forbidden in native binding")
            final = index == len(parts) - 1
            if final and not directory:
                child = os.open(part, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) |
                                getattr(os, "O_CLOEXEC", 0), dir_fd=fd)
            else:
                child = _open_dir_at(fd, part)
            os.close(fd); fd = child
        return fd
    except Exception:
        os.close(fd)
        raise


def _read_bounded_stable(fd: int, limit: int, what: str) -> tuple[bytes, os.stat_result]:
    """Read exactly through EOF while proving one stable regular-file object."""
    before=os.fstat(fd)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink < 1 or before.st_size > limit:
        raise NativeSnapshotError(f"{what} is not a bounded linked regular file")
    os.lseek(fd,0,os.SEEK_SET); chunks=[]; total=0
    while True:
        chunk=os.read(fd,min(65536,limit+1-total))
        if not chunk: break
        chunks.append(chunk); total+=len(chunk)
        if total > limit:
            raise NativeSnapshotError(f"{what} exceeds its byte ceiling")
    after=os.fstat(fd)
    if not _same_identity(before,after) or total != before.st_size:
        raise NativeSnapshotError(f"{what} changed during bounded read")
    return b"".join(chunks),after


def _child_name(parent_fd: int, child_stat: os.stat_result) -> bytes:
    matches = []
    with os.scandir(parent_fd) as entries:
        for entry in entries:
            name = os.fsencode(entry.name)
            try:
                observed = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            except OSError:
                continue
            if stat.S_ISDIR(observed.st_mode) and (observed.st_dev, observed.st_ino) == (child_stat.st_dev, child_stat.st_ino):
                matches.append(name)
    if len(matches) != 1:
        raise NativeSnapshotError("cwd ancestry has ambiguous or missing parent binding")
    return matches[0]


def _git_binding(root_fd: int) -> dict | None:
    try:
        entry = os.stat(b".git", dir_fd=root_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    if stat.S_ISDIR(entry.st_mode):
        fd = _open_dir_at(root_fd, b".git")
        try:
            after = os.fstat(fd)
            if not _same_identity(entry, after):
                raise NativeSnapshotError(".git directory binding changed")
            return {"kind": "directory", "dev": after.st_dev, "ino": after.st_ino,
                    "mount_id": _mount_id_at(root_fd, b".git", fd)}
        finally:
            os.close(fd)
    if not stat.S_ISREG(entry.st_mode) or entry.st_size > 4096:
        raise NativeSnapshotError(".git is neither a directory nor bounded gitfile")
    fd = os.open(b".git", os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0), dir_fd=root_fd)
    try:
        raw,after = _read_bounded_stable(fd,4096,"linked-worktree gitfile")
        if not _same_identity(entry, after) or not raw.startswith(b"gitdir: "):
            raise NativeSnapshotError("linked-worktree gitfile is invalid")
        # The gitfile bytes and inode are a reciprocal binding input.  Opening
        # an absolute gitdir here would reintroduce pathname trust, so linked
        # worktrees are accepted only after the admin backlink bytes are read
        # through an already-open gitfile and matched to this exact inode.
        gitdir = raw[8:].strip()
        if not gitdir.startswith(b"/"):
            raise NativeSnapshotError("relative linked-worktree gitdir is unsupported")
        admin = _open_absolute_nofollow(gitdir, True)
        try:
            backlink_fd = os.open(b"gitdir", os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=admin)
            try:
                backlink_raw,backlink_stat = _read_bounded_stable(
                    backlink_fd,4096,"linked-worktree admin backlink")
                backlink = backlink_raw.rstrip(b"\r\n")
            finally:
                os.close(backlink_fd)
            expected_suffix = b"/.git"
            if not backlink.endswith(expected_suffix):
                raise NativeSnapshotError("linked-worktree admin backlink is invalid")
            backlink_gitfile = _open_absolute_nofollow(backlink, False)
            try:
                if not _same_identity(entry, os.fstat(backlink_gitfile)):
                    raise NativeSnapshotError("linked-worktree backlink does not bind this gitfile")
            finally:
                os.close(backlink_gitfile)
            ast = os.fstat(admin)
            commondir_fd = os.open(b"commondir", os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=admin)
            try:
                commondir_raw,cst = _read_bounded_stable(
                    commondir_fd,4096,"linked-worktree commondir")
                commondir = commondir_raw.rstrip(b"\r\n")
            finally: os.close(commondir_fd)
            if not commondir or len(commondir) > 4096:
                raise NativeSnapshotError("linked-worktree commondir is invalid")
            common_path = commondir if commondir.startswith(b"/") else gitdir + b"/" + commondir
            common = _open_absolute_nofollow(os.path.normpath(common_path), True)
            try:
                common_stat = os.fstat(common)
            finally: os.close(common)
            return {"kind": "gitfile", "dev": entry.st_dev, "ino": entry.st_ino,
                    "mount_id": _mount_id_at(root_fd, b".git", fd),
                    "gitfile_sha256": hashlib.sha256(raw).hexdigest(),
                    "admin_dev": ast.st_dev, "admin_ino": ast.st_ino,
                    "backlink_sha256": hashlib.sha256(backlink_raw).hexdigest(),
                    "backlink_dev":backlink_stat.st_dev,"backlink_ino":backlink_stat.st_ino,
                    "backlink_nlink":backlink_stat.st_nlink,"backlink_size":backlink_stat.st_size,
                    "backlink_mtime_ns":backlink_stat.st_mtime_ns,
                    "backlink_ctime_ns":backlink_stat.st_ctime_ns,
                    "commondir_sha256":hashlib.sha256(commondir_raw).hexdigest(),
                    "commondir_file_dev":cst.st_dev,"commondir_file_ino":cst.st_ino,
                    "commondir_file_nlink":cst.st_nlink,"commondir_file_size":cst.st_size,
                    "commondir_file_mtime_ns":cst.st_mtime_ns,
                    "commondir_file_ctime_ns":cst.st_ctime_ns,
                    "common_dev":common_stat.st_dev,"common_ino":common_stat.st_ino}
        finally:
            os.close(admin)
    finally:
        os.close(fd)


@dataclass
class BoundRoot:
    fd: int
    identity: tuple[int, int]
    mount_id: str
    git: dict
    cwd_chain_digest: str
    ancestry: list[tuple[int, bytes, tuple[int, int, int, int]]]
    parent_fd: int
    parent_name: bytes
    parent_identity: tuple[int, int, int, int, int, int]
    root_identity: tuple[int, ...]


def discover_root() -> BoundRoot:
    current = _open_dir_at(AT_FDCWD, b".")
    chain = hashlib.sha256()
    ancestry = []
    while True:
        st = os.fstat(current)
        git = _git_binding(current)
        if git is not None:
            mount = _mount_id_at(current, b".", current)
            parent = _open_dir_at(current, b"..")
            parent_stat = os.fstat(parent)
            if (parent_stat.st_dev,parent_stat.st_ino) == (st.st_dev,st.st_ino):
                os.close(parent); os.close(current)
                raise NativeSnapshotError("filesystem root cannot be a worktree root")
            root_name = _child_name(parent, st)
            return BoundRoot(current, (st.st_dev, st.st_ino), mount, git,
                             chain.hexdigest(), ancestry, parent, root_name,
                             (parent_stat.st_dev,parent_stat.st_ino,parent_stat.st_mode,
                              parent_stat.st_nlink,parent_stat.st_mtime_ns,parent_stat.st_ctime_ns),
                             _integrity_tuple(st))
        parent = _open_dir_at(current, b"..")
        pst = os.fstat(parent)
        if (pst.st_dev, pst.st_ino) == (st.st_dev, st.st_ino):
            os.close(parent); os.close(current)
            raise NativeSnapshotError("no reciprocal worktree root found")
        name = _child_name(parent, st)
        reopened = _open_dir_at(parent, name)
        try:
            if not _same_identity(st, os.fstat(reopened)):
                raise NativeSnapshotError("cwd ancestry binding changed")
        finally:
            os.close(reopened)
        chain.update(struct.pack(">I", len(name))); chain.update(name)
        chain.update(struct.pack(">QQ", st.st_dev, st.st_ino))
        ancestry.append((os.dup(parent), name,
                         (st.st_dev, st.st_ino, stat.S_IFMT(st.st_mode), st.st_nlink)))
        os.close(current); current = parent


def revalidate_ancestry(root: BoundRoot) -> None:
    parent = os.fstat(root.parent_fd)
    if ((parent.st_dev,parent.st_ino,parent.st_mode,parent.st_nlink,parent.st_mtime_ns,parent.st_ctime_ns) !=
            root.parent_identity):
        raise NativeSnapshotError("worktree root parent changed after discovery")
    rebound = os.stat(root.parent_name, dir_fd=root.parent_fd, follow_symlinks=False)
    if (rebound.st_dev,rebound.st_ino) != root.identity:
        raise NativeSnapshotError("worktree root name binding changed after discovery")
    for parent_fd, name, expected in root.ancestry:
        observed = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (observed.st_dev, observed.st_ino, stat.S_IFMT(observed.st_mode), observed.st_nlink) != expected:
            raise NativeSnapshotError("cwd ancestry binding changed after discovery")


def close_root(root: BoundRoot) -> None:
    for parent_fd, _, _ in root.ancestry:
        try: os.close(parent_fd)
        except OSError: pass
    os.close(root.parent_fd); os.close(root.fd)


def bind_task_runtime(root_fd: int, task_id: str) -> tuple[int, dict]:
    if not task_id or len(os.fsencode(task_id)) > 128 or task_id in (".", "..") or b"/" in os.fsencode(task_id):
        raise NativeSnapshotError("task id is outside the namespace grammar")
    fd = os.dup(root_fd)
    observed = []
    try:
        for component in (b".zyz-worker", b"tasks", os.fsencode(task_id), b"runtime"):
            child = _open_dir_at(fd, component)
            st = os.fstat(child)
            mount = _mount_id_at(fd, component, child)
            observed.append((component.hex(), st.st_dev, st.st_ino, mount))
            os.close(fd); fd = child
        return fd, {"components": observed,
                    "digest": hashlib.sha256(json.dumps(observed, separators=(",", ":")).encode()).hexdigest()}
    except Exception:
        os.close(fd)
        raise


def owner_binding(task_id: str) -> dict:
    """Return the same descriptor-derived binding used by the scanner child."""
    authority = open_owner_binding(task_id)
    try:
        return dict(authority.record)
    finally:
        authority.close()


@dataclass
class OwnerBindingAuthority:
    task_id: str
    root: BoundRoot
    runtime_fd: int
    task_fd: int
    runtime_binding: dict
    record: dict
    task_identity: tuple[int, int, int, int, int, int]
    runtime_identity: tuple[int, int, int, int, int, int]

    def revalidate(self) -> dict:
        revalidate_ancestry(self.root)
        root_st = os.fstat(self.root.fd)
        if (_integrity_tuple(root_st) != self.root.root_identity or
                _mount_id_at(self.root.fd, b".", self.root.fd) != self.root.mount_id or
                _git_binding(self.root.fd) != self.root.git):
            raise NativeSnapshotError("retained root/Git authority changed")
        task_st, runtime_st = os.fstat(self.task_fd), os.fstat(self.runtime_fd)
        stable = lambda value: (value.st_dev,value.st_ino,value.st_mode,value.st_nlink,
                                value.st_mtime_ns,value.st_ctime_ns)
        if stable(task_st) != self.task_identity or stable(runtime_st) != self.runtime_identity:
            raise NativeSnapshotError("retained task/runtime authority changed")
        rebound_fd, rebound = bind_task_runtime(self.root.fd, self.task_id)
        try:
            if not _same_identity(runtime_st, os.fstat(rebound_fd)) or rebound != self.runtime_binding:
                raise NativeSnapshotError("retained runtime name authority changed")
        finally:
            os.close(rebound_fd)
        return dict(self.record)

    def close(self) -> None:
        if self.task_fd >= 0:
            os.close(self.task_fd); self.task_fd = -1
        if self.runtime_fd >= 0:
            os.close(self.runtime_fd); self.runtime_fd = -1
        if self.root is not None:
            close_root(self.root); self.root = None


def open_owner_binding(task_id: str) -> OwnerBindingAuthority:
    """Pin the complete descriptor authority until its caller explicitly closes it."""
    root = discover_root(); runtime_fd = task_fd = -1
    try:
        runtime_fd, runtime = bind_task_runtime(root.fd, task_id)
        task_fd = _open_dir_at(runtime_fd, b"..")
        task = os.fstat(task_fd); root_stat = os.fstat(root.fd); run = os.fstat(runtime_fd)
        stable = lambda value: (value.st_dev,value.st_ino,value.st_mode,value.st_nlink,
                                value.st_mtime_ns,value.st_ctime_ns)
        binding = binding_record(root, runtime)
        record = {
            "task_identity_digest": hashlib.sha256(json.dumps(
                {"dev":task.st_dev,"ino":task.st_ino},sort_keys=True,separators=(",", ":")).encode()+b"\n").hexdigest(),
            "root_identity_digest": hashlib.sha256(json.dumps(
                {"dev":root_stat.st_dev,"ino":root_stat.st_ino},sort_keys=True,separators=(",", ":")).encode()+b"\n").hexdigest(),
            "runtime_identity_digest": hashlib.sha256(json.dumps(
                {"dev":run.st_dev,"ino":run.st_ino},sort_keys=True,separators=(",", ":")).encode()+b"\n").hexdigest(),
            "runtime_mount_id": _mount_id_at(runtime_fd,b".",runtime_fd),
            "native_binding_digest": hashlib.sha256(json.dumps(
                binding,sort_keys=True,separators=(",", ":")).encode()+b"\n").hexdigest(),
        }
        return OwnerBindingAuthority(task_id,root,runtime_fd,task_fd,runtime,record,
                                     stable(task),stable(run))
    except Exception:
        if task_fd >= 0: os.close(task_fd)
        if runtime_fd >= 0: os.close(runtime_fd)
        close_root(root)
        raise


def binding_record(root: BoundRoot, runtime: dict) -> dict:
    return {"root_dev":root.identity[0],"root_ino":root.identity[1],
            "root_mount_id":root.mount_id,"git_binding":root.git,
            "cwd_chain_digest":root.cwd_chain_digest,"runtime_binding":runtime}


def binding_digest(root: BoundRoot, runtime: dict) -> str:
    return hashlib.sha256(json.dumps(binding_record(root, runtime), sort_keys=True,
                                     separators=(",", ":")).encode()+b"\n").hexdigest()


def _rss_bytes() -> int:
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return int(value if os.uname().sysname == "Darwin" else value * 1024)


def _checked_add(left: int, right: int, ceiling: int, what: str) -> int:
    if not isinstance(left, int) or not isinstance(right, int) or left < 0 or right < 0:
        raise NativeSnapshotError(f"invalid {what} accounting operand")
    if right > ceiling - left:
        raise NativeSnapshotError(f"snapshot {what} ceiling exceeded before allocation")
    return left + right


def _allocated_bytes(st: os.stat_result) -> int:
    """Conservative charge for an existing file on sparse/non-sparse filesystems."""
    blocks = getattr(st, "st_blocks", 0)
    physical = blocks * 512 if isinstance(blocks, int) and blocks > 0 else 0
    return max(int(st.st_size), physical)


def _reserve_file_allocation(fd: int, target_size: int, already_charged: int,
                             ceiling: int) -> int:
    if target_size < 0:
        raise NativeSnapshotError("negative file allocation request")
    block = max(512, int(os.fstatvfs(fd).f_frsize or 4096))
    conservative = ((target_size + block - 1) // block) * block
    _checked_add(already_charged, conservative, ceiling, "temp")
    if not hasattr(os, "posix_fallocate"):
        raise NativeSnapshotError("pre-write filesystem allocation guarantee is unavailable")
    os.posix_fallocate(fd, 0, target_size)
    charged = _allocated_bytes(os.fstat(fd))
    _checked_add(already_charged, charged, ceiling, "temp")
    return charged


def _frame(path: bytes, canonical: bytes, integrity: bytes) -> bytes:
    body = struct.pack(">III", len(path), len(canonical), len(integrity)) + path + canonical + integrity
    return body + hashlib.sha256(body).digest()


def _read_frame(stream):
    header = stream.read(12)
    if not header:
        return None
    if len(header) != 12:
        raise NativeSnapshotError("truncated spill frame")
    a, b, c = struct.unpack(">III", header)
    if a > 4096 or b > 8192 or c > 8192:
        raise NativeSnapshotError("oversized spill frame")
    data = stream.read(a + b + c + 32)
    if len(data) != a + b + c + 32:
        raise NativeSnapshotError("truncated spill frame body")
    body = header + data[:a+b+c]
    if hashlib.sha256(body).digest() != data[a+b+c:]:
        raise NativeSnapshotError("spill frame checksum mismatch")
    return data[:a], data[a:a+b], data[a+b:a+b+c]


SNAPSHOT_MAGIC = b"ZYZSNAP2\0"
SNAPSHOT_HEADER_SIZE = 96


def _canonical_frame(path: bytes, canonical: bytes) -> bytes:
    body = struct.pack(">II", len(path), len(canonical)) + path + canonical
    return body + hashlib.sha256(body).digest()


def _canonical_json(raw: bytes) -> dict:
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise NativeSnapshotError("snapshot canonical record has a duplicate key")
            value[key] = item
        return value
    try:
        value = json.loads(raw, object_pairs_hook=unique)
    except NativeSnapshotError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise NativeSnapshotError("snapshot canonical record JSON is invalid")
    if (not isinstance(value, dict) or
            json.dumps(value, sort_keys=True, separators=(",", ":")).encode() != raw):
        raise NativeSnapshotError("snapshot canonical record is not canonical JSON")
    typ = value.get("type")
    common = {"type", "permissions", "size", "payload"}
    if typ in ("block", "char"):
        required = common | {"major", "minor"}
    else:
        required = common
    if set(value) != required or typ not in (
            "regular", "symlink", "directory", "fifo", "socket", "block", "char", "absent"):
        raise NativeSnapshotError("snapshot canonical record schema/type is invalid")
    permissions, size, payload = value.get("permissions"), value.get("size"), value.get("payload")
    if (not isinstance(permissions, int) or isinstance(permissions, bool) or not 0 <= permissions <= 0o7777 or
            not isinstance(size, int) or isinstance(size, bool) or size < 0 or not isinstance(payload, str)):
        raise NativeSnapshotError("snapshot canonical record numeric/payload fields are invalid")
    if typ == "regular":
        if not re_hex64(payload):
            raise NativeSnapshotError("snapshot regular content digest is invalid")
    elif typ == "symlink":
        if permissions != 0 or size != 0 or not re_hex64(payload):
            raise NativeSnapshotError("snapshot symlink canonical fields are invalid")
    elif typ in ("directory", "fifo", "socket"):
        if size != 0 or payload != "":
            raise NativeSnapshotError("snapshot special/directory canonical fields are invalid")
    elif typ in ("block", "char"):
        if (size != 0 or payload != "" or not isinstance(value["major"], int) or
                isinstance(value["major"], bool) or value["major"] < 0 or
                not isinstance(value["minor"], int) or isinstance(value["minor"], bool) or value["minor"] < 0):
            raise NativeSnapshotError("snapshot device canonical fields are invalid")
    elif typ == "absent" and (permissions != 0 or size != 0 or payload != ""):
        raise NativeSnapshotError("snapshot absent canonical fields are invalid")
    return value


def re_hex64(value: str) -> bool:
    return len(value) == 64 and all(ch in "0123456789abcdef" for ch in value)


class SnapshotRecordStream:
    def __init__(self, path: os.PathLike | bytes | str, max_records: int, max_bytes: int,
                 expected_identity: dict | None = None):
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
        if hasattr(path, "open_snapshot_fd"):
            if expected_identity is None:
                raise NativeSnapshotError("retained snapshot artifact requires expected identity")
            try: self.fd, opened_mount = path.open_snapshot_fd()
            except Exception as exc:
                raise NativeSnapshotError(f"retained snapshot artifact open failed: {exc}")
        else:
            bound_path = Path(path)
            parent = os.open(os.fsencode(bound_path.parent),os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|
                             getattr(os,"O_NOFOLLOW",0)|getattr(os,"O_CLOEXEC",0))
            try:
                self.fd = os.open(os.fsencode(bound_path.name), flags, dir_fd=parent)
                opened_mount = (_mount_id_at(parent,os.fsencode(bound_path.name),self.fd)
                                if expected_identity is not None else None)
            finally: os.close(parent)
        self.max_records = max_records; self.max_bytes = max_bytes
        self.whole = hashlib.sha256(); self.digest = hashlib.sha256(); self.consumed = self.index = 0
        self.prior = None; self.finished = False
        self.before = os.fstat(self.fd)
        if expected_identity is not None:
            expected = (expected_identity.get("dev"),expected_identity.get("ino"),
                        expected_identity.get("nlink"),expected_identity.get("size"),
                        expected_identity.get("mtime_ns"))
            observed = (self.before.st_dev,self.before.st_ino,self.before.st_nlink,
                        self.before.st_size,self.before.st_mtime_ns)
            if observed != expected or opened_mount != expected_identity.get("mount_id"):
                self.close(); raise NativeSnapshotError("snapshot records do not match inventory identity")
        if (not stat.S_ISREG(self.before.st_mode) or self.before.st_nlink < 1 or
                self.before.st_size < SNAPSHOT_HEADER_SIZE or
                self.before.st_size > max_bytes + SNAPSHOT_HEADER_SIZE):
            self.close(); raise NativeSnapshotError("snapshot records artifact identity/size is invalid")
        header = self._read_exact(SNAPSHOT_HEADER_SIZE); self.whole.update(header)
        if header[:9] != SNAPSHOT_MAGIC:
            self.close(); raise NativeSnapshotError("snapshot records header is truncated or unsupported")
        self.count, self.records_bytes = struct.unpack(">QQ", header[9:25]); self.declared_digest = header[25:57]
        if (header[57:64] != b"\0" * 7 or
                not hmac.compare_digest(hashlib.sha256(header[:64]).digest(),header[64:96]) or
                self.count > max_records or self.records_bytes > max_bytes or
                self.before.st_size != SNAPSHOT_HEADER_SIZE + self.records_bytes):
            self.close(); raise NativeSnapshotError("snapshot records declared count/length is invalid")

    def _read_exact(self, amount: int) -> bytes:
        value = bytearray()
        while len(value) < amount:
            chunk = os.read(self.fd, min(131072, amount - len(value)))
            if not chunk:
                raise NativeSnapshotError("snapshot record frame is truncated")
            value.extend(chunk)
        return bytes(value)

    def next(self):
        if self.finished:
            return None
        if self.index == self.count:
            self.finish(); return None
        prefix = self._read_exact(8); self.whole.update(prefix)
        path_len, body_len = struct.unpack(">II", prefix)
        if path_len > 4096 or body_len > 8192:
            raise NativeSnapshotError("snapshot record frame lengths exceed schema ceilings")
        frame_len = _checked_add(8, path_len, self.max_bytes, "record")
        frame_len = _checked_add(frame_len, body_len, self.max_bytes, "record")
        frame_len = _checked_add(frame_len, 32, self.max_bytes, "record")
        self.consumed = _checked_add(self.consumed, frame_len, self.records_bytes, "records")
        tail = self._read_exact(path_len + body_len + 32); self.whole.update(tail)
        body = prefix + tail[:path_len + body_len]
        if not hmac.compare_digest(hashlib.sha256(body).digest(), tail[path_len + body_len:]):
            raise NativeSnapshotError("snapshot record frame checksum mismatch")
        raw_path = tail[:path_len]
        if (not raw_path or raw_path.startswith(b"/") or b"\0" in raw_path or
                any(part in (b"", b".", b"..") for part in raw_path.split(b"/")) or
                (self.prior is not None and raw_path <= self.prior)):
            raise NativeSnapshotError("snapshot record paths are empty, invalid, duplicate, or unordered")
        canonical_raw = tail[path_len:path_len + body_len]
        canonical = _canonical_json(canonical_raw)
        self.prior = raw_path; self.index += 1; self.digest.update(body + tail[path_len + body_len:])
        return raw_path, canonical

    def finish(self):
        if self.finished: return
        if self.index != self.count or self.consumed != self.records_bytes or os.read(self.fd, 1):
            raise NativeSnapshotError("snapshot records count/length has trailing or missing data")
        after = os.fstat(self.fd)
        stable = lambda value: (value.st_dev,value.st_ino,value.st_nlink,value.st_size,
                                value.st_mtime_ns,value.st_ctime_ns)
        if stable(self.before) != stable(after) or not hmac.compare_digest(self.digest.digest(), self.declared_digest):
            raise NativeSnapshotError("snapshot records artifact changed or its digest mismatches")
        self.finished = True

    def close(self):
        if self.fd >= 0: os.close(self.fd); self.fd = -1


def read_snapshot_records(path: os.PathLike | bytes | str, max_records: int,
                          max_bytes: int, visitor=None, expected_identity: dict | None = None) -> dict:
    """Strictly validate and stream a published ZYZSNAP2 records artifact.

    Returned rows retain raw path bytes and the decoded canonical record.  The
    caller supplies the frozen baseline ceilings, so malformed length fields
    are rejected before allocation or conversion.
    """
    stream = SnapshotRecordStream(path, max_records, max_bytes, expected_identity)
    try:
        while True:
            row = stream.next()
            if row is None: break
            raw_path, canonical = row
            if visitor is not None:
                visitor(raw_path, canonical)
        return {"path_count": stream.count, "records_bytes": stream.records_bytes,
                "records_sha256": stream.digest.hexdigest(), "whole_sha256": stream.whole.hexdigest()}
    finally:
        stream.close()


def compare_snapshot_records(left, right, max_records: int, max_bytes: int,
                             left_expected: dict | None = None,
                             right_expected: dict | None = None) -> dict:
    """Stream the baseline union current with explicit absent-side records."""
    a = SnapshotRecordStream(left, max_records, max_bytes, left_expected)
    b = SnapshotRecordStream(right, max_records, max_bytes, right_expected)
    left_digest = hashlib.sha256(); right_digest = hashlib.sha256(); union_count = 0
    absent = {"type":"absent","permissions":0,"size":0,"payload":""}
    try:
        av = a.next(); bv = b.next()
        while av is not None or bv is not None:
            if bv is None or (av is not None and av[0] < bv[0]):
                path, lv, rv = av[0], av[1], absent; av = a.next()
            elif av is None or bv[0] < av[0]:
                path, lv, rv = bv[0], absent, bv[1]; bv = b.next()
            else:
                path, lv, rv = av[0], av[1], bv[1]; av = a.next(); bv = b.next()
            union_count = _checked_add(union_count, 1, max_records * 2, "comparison path")
            left_digest.update(_canonical_frame(path, json.dumps(lv,sort_keys=True,separators=(",", ":")).encode()))
            right_digest.update(_canonical_frame(path, json.dumps(rv,sort_keys=True,separators=(",", ":")).encode()))
        a.finish(); b.finish()
        left_hex, right_hex = left_digest.hexdigest(), right_digest.hexdigest()
        return {"union_count":union_count,"left_digest":left_hex,"right_digest":right_hex,
                "changed":not hmac.compare_digest(left_hex,right_hex),
                "left_artifact_sha256":a.whole.hexdigest(),"right_artifact_sha256":b.whole.hexdigest()}
    finally:
        a.close(); b.close()
class Scanner:
    def __init__(self, root: BoundRoot, runtime_fd: int, runtime_binding: dict,
                 temp_fd: int, policy: dict):
        self.root, self.runtime_fd, self.runtime_binding = root, runtime_fd, runtime_binding
        self.temp_fd, self.policy = temp_fd, policy
        self.deadline = time.monotonic() + policy["ZYZ_NO_OUTPUT_SNAPSHOT_TIMEOUT_SEC"]
        self.paths = self.files = self.read_bytes = self.temp_bytes = 0
        self.inventory_bytes = 0
        self.chunk = []
        self.chunk_bytes = 0
        self.chunk_memory_bytes = sys.getsizeof(self.chunk)
        self.chunks: list[bytes] = []
        self.root_stat = os.fstat(root.fd)

    def barrier(self, point: str):
        root = os.environ.get("ZYZ_TEST_SNAPSHOT_BARRIER_DIR")
        requested = os.environ.get("ZYZ_TEST_SNAPSHOT_BARRIER_POINT")
        if not root or requested != point:
            return
        barrier = Path(root); barrier.mkdir(mode=0o700, parents=True, exist_ok=True)
        ready = barrier / "ready"
        fd = os.open(os.fsencode(ready), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try: _write_all(fd,point.encode(),"snapshot barrier"); os.fsync(fd)
        finally: os.close(fd)
        deadline = time.monotonic() + 5
        while not (barrier / "go").is_file():
            if time.monotonic() >= deadline:
                raise NativeSnapshotError("snapshot test barrier timed out")
            time.sleep(.005)

    def check(self):
        if time.monotonic() >= self.deadline:
            raise NativeSnapshotError("snapshot deadline exceeded")
        if _rss_bytes() > self.policy["ZYZ_NO_OUTPUT_MAX_RSS_BYTES"]:
            raise NativeSnapshotError("snapshot RSS ceiling exceeded")
        if self.temp_bytes > self.policy["ZYZ_NO_OUTPUT_MAX_TEMP_BYTES"]:
            raise NativeSnapshotError("snapshot temp ceiling exceeded")

    def revalidate_spill_path(self, raw_path: bytes, integrity_raw: bytes) -> None:
        try:
            integrity=json.loads(integrity_raw)
        except (UnicodeDecodeError,json.JSONDecodeError):
            raise NativeSnapshotError("spill integrity record JSON is invalid")
        if not isinstance(integrity,dict) or set(integrity) != {"leaf","ancestors"}:
            raise NativeSnapshotError("spill path-chain schema is invalid")
        expected=_record_integrity_tuple(integrity["leaf"])
        ancestors=integrity["ancestors"]
        components=raw_path.split(b"/")
        if (not raw_path or any(part in (b"",b".",b"..") for part in components) or
                b"\0" in raw_path or not isinstance(ancestors,list) or
                len(ancestors) != len(components)-1):
            raise NativeSnapshotError("spill raw path is invalid")
        fd=os.dup(self.root.fd)
        leaf_fd=-1
        try:
            for index,component in enumerate(components[:-1]):
                observed=os.stat(component,dir_fd=fd,follow_symlinks=False)
                record=ancestors[index]
                if (not isinstance(record,dict) or set(record) != {"name_b64","identity"} or
                        os.fsencode(os.fsdecode(component)) != component):
                    raise NativeSnapshotError("spill ancestor record is invalid")
                try: recorded_name=base64.b64decode(record["name_b64"],validate=True)
                except Exception: raise NativeSnapshotError("spill ancestor name is invalid")
                expected_ancestor=_record_integrity_tuple(record["identity"])
                if not stat.S_ISDIR(observed.st_mode):
                    raise NativeSnapshotError("spill ancestor is no longer a directory")
                child=_open_dir_at(fd,component)
                if (recorded_name != component or _integrity_tuple(observed) != expected_ancestor or
                        _integrity_tuple(os.fstat(child)) != expected_ancestor or
                        _mount_id_at(fd,component,child) != record["identity"]["mount_id"] or
                        record["identity"]["mount_id"] != self.root.mount_id):
                    os.close(child); raise NativeSnapshotError("spill ancestor name/mount binding changed")
                os.close(fd); fd=child
            name=components[-1]
            observed=os.stat(name,dir_fd=fd,follow_symlinks=False)
            if (_integrity_tuple(observed) != expected or
                    _mount_id_at(fd,name) != integrity["leaf"]["mount_id"] or
                    integrity["leaf"]["mount_id"] != self.root.mount_id):
                raise NativeSnapshotError("spill leaf identity/mount changed before publication")
            if stat.S_ISREG(observed.st_mode) or stat.S_ISDIR(observed.st_mode):
                flags=os.O_RDONLY|getattr(os,"O_NOFOLLOW",0)|getattr(os,"O_CLOEXEC",0)
                if stat.S_ISDIR(observed.st_mode): flags|=getattr(os,"O_DIRECTORY",0)
                leaf_fd=os.open(name,flags,dir_fd=fd)
                if (_integrity_tuple(os.fstat(leaf_fd)) != expected or
                        _mount_id_at(fd,name,leaf_fd) != integrity["leaf"]["mount_id"]):
                    raise NativeSnapshotError("spill leaf opened identity changed before publication")
        finally:
            if leaf_fd >= 0: os.close(leaf_fd)
            os.close(fd)

    def add(self, path: bytes, canonical: dict, integrity: dict):
        if self.paths + 1 > self.policy["ZYZ_NO_OUTPUT_MAX_PATHS"]:
            raise NativeSnapshotError("snapshot path ceiling exceeded")
        # json.dumps, the encoded strings, the framed bytes and the eventual
        # tuple/list slot all exist concurrently.  Reserve their schema-bounded
        # worst case before constructing any of them; the exact persistent
        # charge is checked again before the list is allowed to grow.
        projected = 8192 + 8 * (len(path) + 8192 + 8192)
        _checked_add(_rss_bytes(), projected,
                     self.policy["ZYZ_NO_OUTPUT_MAX_RSS_BYTES"], "RSS")
        c = json.dumps(canonical, sort_keys=True, separators=(",", ":")).encode()
        i = json.dumps(integrity, sort_keys=True, separators=(",", ":")).encode()
        frame = _frame(path, c, i)
        if self.inventory_bytes + len(frame) > self.policy["ZYZ_NO_OUTPUT_MAX_INVENTORY_BYTES"]:
            raise NativeSnapshotError("snapshot inventory ceiling exceeded")
        self.paths += 1
        self.inventory_bytes += len(frame)
        item = (path, frame)
        persistent = sys.getsizeof(path) + sys.getsizeof(frame) + sys.getsizeof(item)
        # A CPython list slot is one pointer, but use two pointers as a
        # conservative implementation-independent growth allowance.  This is
        # checked before append, so append cannot be the first observation of
        # an over-ceiling allocation.
        list_growth = 2 * struct.calcsize("P")
        _checked_add(_rss_bytes(), persistent + list_growth,
                     self.policy["ZYZ_NO_OUTPUT_MAX_RSS_BYTES"], "RSS")
        next_memory = _checked_add(self.chunk_memory_bytes, persistent + list_growth,
                                   self.policy["ZYZ_NO_OUTPUT_MAX_RSS_BYTES"], "RSS")
        self.check()
        self.chunk.append(item); self.chunk_bytes += len(frame)
        self.chunk_memory_bytes = next_memory
        self.check()
        if self.chunk_bytes >= min(1048576, self.policy["ZYZ_NO_OUTPUT_MAX_INVENTORY_BYTES"]):
            self.flush()

    def flush(self):
        if not self.chunk:
            return
        self.check()
        self.chunk.sort(key=lambda item: item[0])
        intended = sum(len(frame) for _, frame in self.chunk)
        if self.temp_bytes + intended > self.policy["ZYZ_NO_OUTPUT_MAX_TEMP_BYTES"]:
            raise NativeSnapshotError("snapshot temp ceiling exceeded before spill")
        name = b"snapshot-spill-" + os.urandom(16).hex().encode()
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os,"O_CLOEXEC",0),
                     0o600, dir_fd=self.temp_fd)
        charge = _reserve_file_allocation(fd, intended, self.temp_bytes,
                                          self.policy["ZYZ_NO_OUTPUT_MAX_TEMP_BYTES"])
        with os.fdopen(fd, "wb") as out:
            for _, frame in self.chunk:
                out.write(frame)
            out.flush(); os.fsync(out.fileno())
        observed_charge = _allocated_bytes(os.stat(name,dir_fd=self.temp_fd,follow_symlinks=False))
        if observed_charge > charge: raise NativeSnapshotError("spill allocation grew beyond reservation")
        self.temp_bytes = _checked_add(self.temp_bytes, charge,self.policy["ZYZ_NO_OUTPUT_MAX_TEMP_BYTES"], "temp")
        self.chunks.append(name); self.chunk = []; self.chunk_bytes = 0
        self.chunk_memory_bytes = sys.getsizeof(self.chunk); self.check()

    def excluded(self, rel: bytes) -> bool:
        runtime_prefix = b".zyz-worker/tasks/" + os.fsencode(self.policy["task_id"]) + b"/runtime"
        return rel == b".git" or rel.startswith(b".git/") or rel == runtime_prefix or rel.startswith(runtime_prefix + b"/")

    def walk(self, directory_fd: int, prefix: bytes = b"", ancestors: list[dict] | None = None):
        ancestors=[] if ancestors is None else ancestors
        before = os.fstat(directory_fd)
        self.barrier("before-directory-enumeration")
        if before.st_dev != self.root_stat.st_dev:
            raise NativeSnapshotError("cross-device directory rejected")
        if _mount_id_at(directory_fd, b".", directory_fd) != self.root.mount_id:
            raise NativeSnapshotError("cross-mount directory rejected")
        # Record ordering is provided by the bounded spill/merge stage.  Walk
        # the directory iterator once instead of rescanning it for each raw
        # successor (quadratic on a wide directory).  Only the active ancestry
        # chain is retained while recursion proceeds.
        with os.scandir(directory_fd) as entries:
         for entry in entries:
            name = os.fsencode(entry.name)
            self.check()
            if os.fsencode(os.fsdecode(name)) != name:
                raise NativeSnapshotError("raw path round-trip capability failed")
            rel = name if not prefix else prefix + b"/" + name
            if self.excluded(rel):
                runtime_prefix = b".zyz-worker/tasks/" + os.fsencode(self.policy["task_id"]) + b"/runtime"
                if rel == runtime_prefix:
                    runtime_name_fd = _open_dir_at(directory_fd, name)
                    try:
                        if (not _same_identity(os.fstat(runtime_name_fd), os.fstat(self.runtime_fd)) or
                                _mount_id_at(directory_fd, name, runtime_name_fd) !=
                                _mount_id_at(self.runtime_fd, b".", self.runtime_fd)):
                            raise NativeSnapshotError("lexically excluded runtime is not pinned runtime")
                    finally: os.close(runtime_name_fd)
                continue
            pre = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            if pre.st_nlink == 0 or pre.st_dev != self.root_stat.st_dev:
                raise NativeSnapshotError("unlinked or cross-device entry rejected")
            typ = stat.S_IFMT(pre.st_mode); perms = stat.S_IMODE(pre.st_mode)
            mount = _mount_id_at(directory_fd, name)
            if mount != self.root.mount_id:
                raise NativeSnapshotError("cross-mount entry rejected")
            payload = ""; size = 0; child = None; device = None
            if stat.S_ISREG(typ):
                if pre.st_size > self.policy["ZYZ_NO_OUTPUT_MAX_FILE_BYTES"]:
                    raise NativeSnapshotError("single-file ceiling exceeded")
                child = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) |
                                getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_CLOEXEC", 0), dir_fd=directory_fd)
                try:
                    opened = os.fstat(child)
                    if not _same_identity(pre, opened) or _mount_id_at(directory_fd, name, child) != mount:
                        raise NativeSnapshotError("regular binding changed")
                    digest = hashlib.sha256(); count = 0
                    while True:
                        remaining_file = self.policy["ZYZ_NO_OUTPUT_MAX_FILE_BYTES"] - count
                        remaining_total = self.policy["ZYZ_NO_OUTPUT_MAX_TOTAL_BYTES"] - self.read_bytes
                        if remaining_file <= 0 or remaining_total <= 0:
                            probe = os.read(child, 1)
                            if probe: raise NativeSnapshotError("content byte ceiling exceeded before read")
                            break
                        data = os.read(child, min(131072, remaining_file, remaining_total))
                        if not data: break
                        count += len(data); self.read_bytes += len(data); digest.update(data); self.check()
                    self.barrier("after-file-eof")
                    post = os.fstat(child)
                    stable = (pre.st_dev,pre.st_ino,pre.st_nlink,pre.st_size,pre.st_mtime_ns,pre.st_ctime_ns)
                    if stable != (post.st_dev,post.st_ino,post.st_nlink,post.st_size,post.st_mtime_ns,post.st_ctime_ns):
                        raise NativeSnapshotError("regular changed during read")
                    payload, size = digest.hexdigest(), count; self.files += 1; label = "regular"
                finally:
                    os.close(child); child = None
            elif stat.S_ISDIR(typ):
                child = _open_dir_at(directory_fd, name); label = "directory"
                if not _same_identity(pre, os.fstat(child)):
                    os.close(child); raise NativeSnapshotError("directory binding changed")
            elif stat.S_ISLNK(typ):
                self.barrier("before-symlink-read")
                target1 = os.fsencode(os.readlink(name, dir_fd=directory_fd))
                target2 = os.fsencode(os.readlink(name, dir_fd=directory_fd))
                rebound_link=os.stat(name,dir_fd=directory_fd,follow_symlinks=False)
                if target1 != target2 or not _same_identity(pre,rebound_link):
                    raise NativeSnapshotError("symlink changed during read")
                payload, perms, label = hashlib.sha256(target1).hexdigest(), 0, "symlink"
            elif stat.S_ISFIFO(typ): label = "fifo"
            elif stat.S_ISSOCK(typ): label = "socket"
            elif stat.S_ISBLK(typ): label = "block"; device = (os.major(pre.st_rdev), os.minor(pre.st_rdev))
            elif stat.S_ISCHR(typ): label = "char"; device = (os.major(pre.st_rdev), os.minor(pre.st_rdev))
            else: raise NativeSnapshotError("unsupported filesystem entry type")
            rebound = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            if not _same_identity(pre, rebound):
                if child is not None: os.close(child)
                raise NativeSnapshotError("entry name binding changed")
            canonical = {"type": label, "permissions": perms, "size": size, "payload": payload}
            if device is not None: canonical.update(major=device[0], minor=device[1])
            integrity = {"leaf":_integrity_record(pre,mount),"ancestors":ancestors}
            self.add(rel, canonical, integrity)
            if child is not None:
                child_chain=ancestors+[{"name_b64":base64.b64encode(name).decode(),
                                        "identity":_integrity_record(pre,mount)}]
                try: self.walk(child, rel, child_chain)
                finally: os.close(child)
                if not _same_identity(pre, os.stat(name, dir_fd=directory_fd, follow_symlinks=False)):
                    raise NativeSnapshotError("directory changed after recursion")
        after = os.fstat(directory_fd)
        if (before.st_dev,before.st_ino,before.st_nlink,before.st_mtime_ns,before.st_ctime_ns) != (
                after.st_dev,after.st_ino,after.st_nlink,after.st_mtime_ns,after.st_ctime_ns):
            raise NativeSnapshotError("directory changed during enumeration")

    def merge(self, output_name: bytes) -> dict:
        self.flush()
        streams = [os.fdopen(os.open(name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=self.temp_fd),"rb")
                   for name in self.chunks]
        heap = []
        try:
            for index, stream in enumerate(streams):
                frame = _read_frame(stream)
                if frame is not None: heapq.heappush(heap, (frame[0], index, frame))
            h = hashlib.sha256(); ih = hashlib.sha256(); prior = None; count = manifest_bytes = 0
            output_fd = os.open(output_name,os.O_RDWR|os.O_CREAT|os.O_EXCL|getattr(os,"O_CLOEXEC",0),
                                0o600,dir_fd=self.temp_fd)
            with os.fdopen(output_fd,"w+b") as out:
                if self.temp_bytes + SNAPSHOT_HEADER_SIZE > self.policy["ZYZ_NO_OUTPUT_MAX_TEMP_BYTES"]:
                    raise NativeSnapshotError("snapshot temp ceiling exceeded before merge")
                output_charge = _reserve_file_allocation(out.fileno(), SNAPSHOT_HEADER_SIZE,
                    self.temp_bytes,self.policy["ZYZ_NO_OUTPUT_MAX_TEMP_BYTES"])
                reserved_size = SNAPSHOT_HEADER_SIZE
                out.write(SNAPSHOT_MAGIC + b"\0" * (SNAPSHOT_HEADER_SIZE - len(SNAPSHOT_MAGIC)))
                while heap:
                    path, index, frame = heapq.heappop(heap)
                    if prior is not None and path <= prior: raise NativeSnapshotError("duplicate/unsorted raw path")
                    prior = path; canonical = _canonical_frame(path, frame[1])
                    self.barrier("before-spill-path-revalidate")
                    self.revalidate_spill_path(path,frame[2])
                    integrity = struct.pack(">II", len(path), len(frame[2])) + path + frame[2]
                    if (manifest_bytes + len(canonical) > self.policy["ZYZ_NO_OUTPUT_MAX_MANIFEST_BYTES"] or
                            self.temp_bytes + SNAPSHOT_HEADER_SIZE + manifest_bytes + len(canonical) >
                            self.policy["ZYZ_NO_OUTPUT_MAX_TEMP_BYTES"]):
                        raise NativeSnapshotError("snapshot manifest/temp ceiling exceeded before merge write")
                    required_size = SNAPSHOT_HEADER_SIZE + manifest_bytes + len(canonical)
                    if required_size > reserved_size:
                        available = self.policy["ZYZ_NO_OUTPUT_MAX_TEMP_BYTES"] - self.temp_bytes
                        rounded = ((required_size + 1048575) // 1048576) * 1048576
                        reserved_size = min(max(required_size, rounded), available)
                        output_charge = _reserve_file_allocation(out.fileno(), reserved_size,
                            self.temp_bytes,self.policy["ZYZ_NO_OUTPUT_MAX_TEMP_BYTES"])
                    out.write(canonical); h.update(canonical); ih.update(integrity)
                    manifest_bytes += len(canonical); count += 1; self.check()
                    nxt = _read_frame(streams[index])
                    if nxt is not None: heapq.heappush(heap, (nxt[0], index, nxt))
                # posix_fallocate changes logical size.  Remove the reserved
                # zero tail before hashing/declaring the final artifact.
                out.truncate(SNAPSHOT_HEADER_SIZE + manifest_bytes)
                out.flush(); os.fsync(out.fileno())
                prefix = (SNAPSHOT_MAGIC + struct.pack(">QQ", count, manifest_bytes) +
                          bytes.fromhex(h.hexdigest()) + b"\0" * 7)
                header = prefix + hashlib.sha256(prefix).digest()
                if len(header) != SNAPSHOT_HEADER_SIZE: raise NativeSnapshotError("snapshot header length invariant failed")
                out.seek(0); out.write(header); out.flush(); os.fsync(out.fileno())
            if manifest_bytes > self.policy["ZYZ_NO_OUTPUT_MAX_MANIFEST_BYTES"]:
                raise NativeSnapshotError("manifest byte ceiling exceeded")
            charge = _allocated_bytes(os.stat(output_name,dir_fd=self.temp_fd,follow_symlinks=False))
            if charge > output_charge: raise NativeSnapshotError("manifest allocation grew beyond reservation")
            self.temp_bytes = _checked_add(self.temp_bytes, output_charge,
                                           self.policy["ZYZ_NO_OUTPUT_MAX_TEMP_BYTES"], "temp")
            self.check()
            return {"path_count": count, "file_count": self.files, "read_bytes": self.read_bytes,
                    "inventory_bytes": self.inventory_bytes,
                    "manifest_bytes": manifest_bytes, "manifest_digest": h.hexdigest(),
                    "integrity_digest": ih.hexdigest(), "temp_peak_bytes": self.temp_bytes,
                    "rss_peak_bytes": _rss_bytes()}
        finally:
            for stream in streams: stream.close()
            for name in self.chunks:
                try: os.unlink(name,dir_fd=self.temp_fd)
                except FileNotFoundError: pass


def snapshot(task_id: str, temp_fd: int, policy: dict, output_name: bytes,
             expected_binding_digest: str) -> dict:
    root = discover_root()
    runtime_fd = -1
    previous_as = None
    try:
        runtime_fd, runtime_binding = bind_task_runtime(root.fd, task_id)
        initial_binding_digest = binding_digest(root, runtime_binding)
        if initial_binding_digest != expected_binding_digest:
            raise NativeSnapshotError("scanner binding differs from committed owner")
        policy = dict(policy); policy["task_id"] = task_id
        if not hasattr(resource, "RLIMIT_AS"):
            raise NativeSnapshotError("RLIMIT_AS hard guarantee is unavailable")
        soft, hard = resource.getrlimit(resource.RLIMIT_AS); previous_as = (soft, hard)
        requested = policy["ZYZ_NO_OUTPUT_MAX_RSS_BYTES"]
        new_soft = requested if hard == resource.RLIM_INFINITY else min(requested, hard)
        if new_soft < requested:
            raise NativeSnapshotError("RLIMIT_AS hard ceiling is below configured scanner limit")
        resource.setrlimit(resource.RLIMIT_AS, (new_soft, hard))
        if _rss_bytes() >= requested:
            raise NativeSnapshotError("scanner RSS is already at configured hard ceiling")
        scanner = Scanner(root, runtime_fd, runtime_binding, temp_fd, policy)
        scanner.walk(root.fd)
        observation = scanner.merge(output_name)
        scanner.barrier("before-ancestry-revalidate")
        revalidate_ancestry(root)
        rebound_runtime_fd, rebound_runtime = bind_task_runtime(root.fd, task_id)
        try:
            if not _same_identity(os.fstat(runtime_fd), os.fstat(rebound_runtime_fd)) or rebound_runtime != runtime_binding:
                raise NativeSnapshotError("task runtime binding changed after scan")
        finally: os.close(rebound_runtime_fd)
        if _git_binding(root.fd) != root.git or binding_digest(root, runtime_binding) != expected_binding_digest:
            raise NativeSnapshotError("git/root/runtime binding changed after scan")
        scanner.barrier("before-root-final-revalidate")
        final = os.fstat(root.fd)
        if (_integrity_tuple(final) != root.root_identity or
                _mount_id_at(root.fd, b".", root.fd) != root.mount_id):
            raise NativeSnapshotError("root binding changed before publication")
        observation.update(root_dev=root.identity[0], root_ino=root.identity[1], root_mount_id=root.mount_id,
                           git_binding=root.git, runtime_binding=runtime_binding,
                           cwd_chain_digest=root.cwd_chain_digest,
                           native_binding_digest=expected_binding_digest,
                           raw_path_capability="bytes-roundtrip", mount_capability="native",
                           rlimit_as_capability="enforced" if previous_as is not None else "unavailable")
        return observation
    finally:
        if previous_as is not None:
            try: resource.setrlimit(resource.RLIMIT_AS, previous_as)
            except Exception: pass
        if runtime_fd >= 0: os.close(runtime_fd)
        close_root(root)


def _main(argv: list[str]) -> int:
    if len(argv) != 6 or argv[0] != "scan":
        return 2
    task_id, temp_raw, policy_raw, output_raw, expected_binding_digest = argv[1:]
    temp_dir, output = Path(temp_raw), Path(output_raw)
    output_name = os.fsencode(output.name); observation_name = b"observation.json"
    try:
        if os.uname().sysname == "Linux":
            libc = ctypes.CDLL(None, use_errno=True)
            PR_SET_PDEATHSIG = 1
            if libc.prctl(PR_SET_PDEATHSIG, 9, 0, 0, 0) != 0:
                raise OSError(ctypes.get_errno(), "prctl(PR_SET_PDEATHSIG)")
            if os.getppid() == 1:
                os.kill(os.getpid(), 9)
        gate_raw = os.environ.pop("ZYZ_SNAPSHOT_START_GATE_FD", None)
        if gate_raw is not None:
            gate_fd = int(gate_raw)
            try:
                if os.read(gate_fd, 1) != b"G":
                    raise NativeSnapshotError("scanner start gate was not committed")
            finally: os.close(gate_fd)
        agents_raw = os.environ.pop("ZYZ_SNAPSHOT_AGENTS_FD", None)
        temp_basename = os.environ.pop("ZYZ_SNAPSHOT_TEMP_BASENAME", None)
        if agents_raw is None or not temp_basename or Path(temp_basename).name != temp_basename:
            raise NativeSnapshotError("descriptor-bound scanner temp configuration is missing")
        agents_fd = int(agents_raw)
        temp_fd = _open_dir_at(agents_fd, os.fsencode(temp_basename))
        try:
            if not _same_identity(os.fstat(temp_fd), os.stat(os.fsencode(temp_basename), dir_fd=agents_fd,
                                                             follow_symlinks=False)):
                raise NativeSnapshotError("scanner temp name/fd binding changed")
        finally: os.close(agents_fd)
        forced = os.environ.get("ZYZ_TEST_SNAPSHOT_CHILD_FAILURE")
        if forced == "oom": raise MemoryError("injected native snapshot OOM")
        if forced == "sigkill": os.kill(os.getpid(), 9)
        if forced == "term": os.kill(os.getpid(), 15)
        policy = json.loads(policy_raw)
        if not isinstance(policy, dict): raise ValueError("policy object required")
        if output.parent != temp_dir or output.name in ("", ".", ".."):
            raise NativeSnapshotError("scanner output path is outside its descriptor-bound temp")
        observation = snapshot(task_id, temp_fd, policy, output_name, expected_binding_digest)
        payload = (json.dumps(observation, sort_keys=True, separators=(",", ":")) + "\n").encode()
        if len(payload) > 16384:
            raise NativeSnapshotError("snapshot observation is oversized before write")
        fd = os.open(observation_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=temp_fd)
        try: _write_all(fd,payload,"snapshot observation"); os.fsync(fd)
        finally: os.close(fd)
        return 0
    except Exception as exc:
        try:
            payload = (json.dumps({"error": str(exc)[:512]}, sort_keys=True, separators=(",", ":")) + "\n").encode()
            fd = os.open(observation_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=temp_fd)
            try: _write_all(fd,payload,"snapshot error observation"); os.fsync(fd)
            finally: os.close(fd)
        except Exception:
            pass
        return 1
    finally:
        try: os.close(temp_fd)
        except (NameError,OSError): pass


if __name__ == "__main__":
    import sys
    raise SystemExit(_main(sys.argv[1:]))
