#!/usr/bin/env python3
"""Bounded, auditable runtime state for execute-task role instances.

This module is intentionally dependency-free. Shell hooks use hidden hook
operations; users use the documented ``agent-runtime-state.sh`` commands.
New-format control authority lives only in preallocated fixed packs. Physical
data artifacts remain exact catalog-owned files.
"""
from __future__ import annotations

import base64
import ctypes
import errno
import fcntl
import hashlib
import hmac
import json
import os
import re
import secrets
import socket
import stat
import struct
import subprocess
import sys
import time
from contextlib import ExitStack
from dataclasses import dataclass
from pathlib import Path

try:
    import runtime_native
except ModuleNotFoundError:
    # Keep direct importlib loading usable for implementation diagnostics while
    # binding the native backend only to this file's sibling, never cwd/PATH.
    import importlib.util
    _native_path = Path(__file__).resolve().with_name("runtime_native.py")
    _native_spec = importlib.util.spec_from_file_location("runtime_native", _native_path)
    if _native_spec is None or _native_spec.loader is None:
        raise
    runtime_native = importlib.util.module_from_spec(_native_spec)
    sys.modules["runtime_native"] = runtime_native
    _native_spec.loader.exec_module(runtime_native)

ROLES = {
    "implementation-agent": "implementation-agent",
    "test-agent": "test-agent",
    "review-agent": "review-agent",
    "zyz-worker:implementation-agent": "implementation-agent",
    "zyz-worker:test-agent": "test-agent",
    "zyz-worker:review-agent": "review-agent",
}
KEY_RE = re.compile(r"^[A-Za-z0-9._-]{1,32}\.[0-9a-f]{64}$")
PROBE_RE = re.compile(r"^probe1-[0-9a-f]{32}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
EVENT_RE = re.compile(r"^evt1-[0-9a-f]{64}$")
MAX_ARG = 4096

EVENT_INVENTORY_LIMITS = {
    "start-unarmed": 16,
    "stop-uncommitted": 16,
    "journal": 2,
    "committed": 2,
    "resolved": 16,
    "late-event": 16,
}

# Fixed catalog schema v1.  These offsets are a compatibility boundary shared
# by every runtime reader; do not derive them from Python object sizes.
CATALOG_GLOBAL_SIZE = 4 * 1024 * 1024
CATALOG_RECOVERY_SIZE = 8 * 1024 * 1024
CATALOG_TERMINAL_SIZE = 16 * 1024 * 1024
TERMINAL_CELL_COUNT = 256
TERMINAL_CELL_SIZE = 64 * 1024
TERMINAL_IMAGE_SIZE = 32 * 1024
CATALOG_SEGMENT_SIZE = 1024 * 1024
CATALOG_SEGMENT_CONTROL = 65536
CATALOG_CELL_COUNT = 8192
CATALOG_RECOVERY_CELL_SIZE = 1024
CATALOG_RECOVERY_IMAGE_SIZE = 512
CATALOG_DIRECTORY_IMAGE_SIZE = 192
CATALOG_ROOT_IMAGE_SIZE = 65536
CATALOG_GROUP_IMAGE_SIZE = 65536
CATALOG_LAYOUT = {
    "pack_header": (0, 8192),
    "genesis": (8192, 24576),
    "schedule": (24576, 32768),
    "root_meta": (32768, 163840),
    "cell_directory_a": (163840, 1736704),
    "cell_directory_b": (1736704, 3309568),
    "group_control": (3309568, 3440640),
    "migration_quiesce": (3440640, 3571712),
    "rotation_control": (3571712, 3637248),
    "compaction_control": (3637248, 3702784),
    "reserved_headroom": (3702784, 4194304),
}
CATALOG_FIXED_NAMES = {
    ".catalog-lock.v1",
    ".catalog-shared-source-lock.v1",
    ".terminal-index-lock.v1",
    ".catalog-global-pack.prepare.v1",
    ".catalog-global-pack.v1",
    ".catalog-recovery-pack.v1",
    ".terminal-audit-pack.v1",
    ".catalog-segment.0000000000000001.v1",
    ".catalog-segment.0000000000000002.v1",
    ".catalog-compaction-scratch.v1",
}
CATALOG_TRIGGERS = ("watchdog", "lifecycle", "manual", "system-timer")
CATALOG_ROOT_PARTITIONS = (4096, 1024, 16384, 8192, 8192, 4096, 4096, 19456)
CATALOG_CHAIN_PARTITIONS = (4096, 16 * 512, 4096)
CATALOG_CHAIN_OFFSET = 5120
CATALOG_CHAIN_SIZE = sum(CATALOG_CHAIN_PARTITIONS)
CATALOG_CHAIN_ENTRY_COUNT = 16
CATALOG_CHAIN_ENTRY_SIZE = 512
# Public structural floor. It rounds the 31 MiB data-object sum up to 32 MiB
# so the three carrier blocks and filesystem allocation rounding are included.
CATALOG_GENESIS_FLOOR = 33554432

GC_OUTPUT_KEYS = (
    "ok", "state", "error", "trigger", "due", "lock_acquired",
    "claims_scanned", "claims_skipped", "blocked_claims_known",
    "transactions_advanced", "entries_verified", "verification_bytes",
    "entries_deleted", "bytes_reclaimed", "owned_bytes_before",
    "owned_bytes_after", "high_water", "hard_water", "receipts_anchored",
    "next_gc_epoch",
)

INSTANCE_AUDIT_SIZE = 512 * 1024
INSTANCE_WORK_SIZE = 512 * 1024
INSTANCE_AUDIT_SLOTS = {
    "IDENTITY": (8192, 8192), "START": (16384, 8192),
    "HEARTBEAT": (24576, 8192), "DONE": (32768, 16384),
    "FINALIZED": (49152, 16384), "AMBIGUOUS": (65536, 8192),
    "PROBE_STATE": (73728, 32768),
    "RESOLVED_START": (106496, 65536), "RESOLVED_STOP": (172032, 65536),
    "SUCCESSOR_RECEIPTS": (237568, 65536), "LATE_EVENT": (303104, 16384),
    "TERMINAL_SUMMARY": (319488, 16384), "GC_ANCHOR": (335872, 16384),
    "DIAGNOSTICS": (352256, 40960),
}
INSTANCE_WORK_SLOTS = {
    "TRANSITION_JOURNAL": (8192, 16384), "PUBLICATION_JOURNAL": (24576, 32768),
    "LIVE_INVENTORY": (57344, 32768), "TERMINAL_STAGING": (90112, 32768),
    "TERMINAL_HANDOFF": (122880, 16384), "INFLIGHT": (139264, 65536),
    "EPHEMERAL_DIAGNOSTICS": (204800, 32768),
}
INSTANCE_PACK_HEADER_SIZE = 4096
CLAIM_PACK_SIZE = 256 * 1024
CLAIM_PACK_SLOTS = {
    "IMMUTABLE_KEY": (8192, 8192), "OWNER": (16384, 16384),
    "OBSERVATION": (32768, 16384), "GC_JOURNAL": (49152, 32768),
    "KEY": (81920, 8192), "CHECKPOINT": (90112, 16384),
    "POINTER": (106496, 8192), "RECEIPT": (114688, 8192),
    "ANCHOR_ACK": (122880, 8192),
}


class StateError(Exception):
    def __init__(self, code: str, message: str, exit_code: int = 4, retryable: bool = False):
        super().__init__(message)
        self.code, self.message, self.exit_code, self.retryable = code, message, exit_code, retryable


def _catalog_digest(domain: bytes, payload: bytes) -> bytes:
    return hashlib.sha256(domain + payload).digest()


def _catalog_json(value: dict) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def _catalog_pread_exact(fd: int, size: int, offset: int) -> bytes:
    value = bytearray()
    while len(value) < size:
        chunk = os.pread(fd, size - len(value), offset + len(value))
        if not chunk:
            break
        value.extend(chunk)
    if len(value) != size:
        raise StateError("catalog-root-invalid", "catalog pack is truncated", 4)
    return bytes(value)


def _catalog_pwrite_all(fd: int, payload: bytes, offset: int, what: str) -> None:
    view = memoryview(payload)
    written = 0
    while view:
        amount = os.pwrite(fd, view, offset + written)
        if amount <= 0:
            raise StateError("io", f"{what} write made no progress", 6, True)
        written += amount
        view = view[amount:]


def _data_sync(fd: int) -> None:
    # Darwin's Python 3.9 omits os.fdatasync; fsync is a stronger compatible
    # durability primitive there.
    getattr(os, "fdatasync", os.fsync)(fd)


def _catalog_image(magic: bytes, size: int, generation: int, predecessor: bytes,
                   metadata: dict, regions: tuple[tuple[int, bytes], ...] = (),
                   metadata_limit: int = 3968) -> bytes:
    """Build a complete self-validating fixed image.

    The first 128 bytes are common across pack slots.  The checksum covers the
    entire image with its checksum field zero, so an inactive short/torn write
    can never outrank the prior complete generation.
    """
    if len(magic) > 8 or size < 128 or generation < 1 or len(predecessor) != 32:
        raise StateError("gc-internal", "global-layout-overflow", 5, True)
    encoded = _catalog_json(metadata)
    if (metadata_limit < 0 or metadata_limit > size - 128 or
            len(encoded) > metadata_limit):
        raise StateError("gc-internal", "global-layout-overflow", 5, True)
    image = bytearray(size)
    image[0:8] = magic.ljust(8, b"\0")
    struct.pack_into(">HHQI", image, 8, 1, 0, generation, len(encoded))
    image[24:56] = predecessor
    image[96:128] = _catalog_digest(b"zyz-pack-payload-v1", encoded)
    image[128:128 + len(encoded)] = encoded
    metadata_end = 128 + len(encoded)
    for region_offset, payload in regions:
        if region_offset < metadata_end or region_offset + len(payload) > size:
            raise StateError("gc-internal", "global-layout-overflow", 5, True)
        image[region_offset:region_offset + len(payload)] = payload
    checksum = _catalog_digest(b"zyz-pack-image-v1", bytes(image))
    image[56:88] = checksum
    return bytes(image)


def _catalog_parse_image(raw: bytes, magic: bytes, semantic=None,
                         metadata_limit: int = 3968) -> tuple[int, bytes, dict, bytes]:
    if len(raw) < 128 or raw == bytes(len(raw)) or raw[0:8] != magic.ljust(8, b"\0"):
        raise StateError("catalog-root-invalid", "catalog image magic is invalid", 4)
    try:
        schema, flags, generation, payload_len = struct.unpack_from(">HHQI", raw, 8)
    except struct.error:
        raise StateError("catalog-root-invalid", "catalog image header is truncated", 4)
    if (metadata_limit < 0 or metadata_limit > len(raw) - 128 or
            schema != 1 or flags != 0 or generation < 1 or
            payload_len > metadata_limit):
        raise StateError("catalog-root-invalid", "catalog image header is invalid", 4)
    expected = raw[56:88]
    mutable = bytearray(raw); mutable[56:88] = bytes(32)
    if not hmac.compare_digest(expected, _catalog_digest(b"zyz-pack-image-v1", bytes(mutable))):
        raise StateError("catalog-root-invalid", "catalog image checksum is invalid", 4)
    payload = raw[128:128 + payload_len]
    if not hmac.compare_digest(raw[96:128], _catalog_digest(b"zyz-pack-payload-v1", payload)):
        raise StateError("catalog-root-invalid", "catalog image payload checksum is invalid", 4)
    try:
        value = json.loads(payload)
    except Exception:
        raise StateError("catalog-root-invalid", "catalog image payload is invalid", 4)
    if not isinstance(value, dict):
        raise StateError("catalog-root-invalid", "catalog image payload is not an object", 4)
    if semantic is not None:
        semantic(value)
    return generation, raw[24:56], value, _catalog_digest(b"zyz-pack-image-id-v1", raw)


def _catalog_select_ab(fd: int, offset: int, image_size: int, magic: bytes,
                       semantic=None, metadata_limit: int = 3968):
    valid = []
    invalid_nonzero = 0
    for bank in (0, 1):
        raw = _catalog_pread_exact(fd, image_size, offset + bank * image_size)
        if raw == bytes(image_size):
            continue
        try:
            parsed = _catalog_parse_image(raw, magic, semantic, metadata_limit)
            valid.append((parsed[0], bank, raw, parsed))
        except StateError:
            invalid_nonzero += 1
    if not valid:
        raise StateError("catalog-root-invalid", "catalog A/B slot has no valid generation", 4)
    valid.sort(key=lambda item: item[0])
    if len(valid) == 2:
        older, newer = valid
        if older[0] == newer[0]:
            raise StateError("catalog-root-invalid", "catalog A/B slot has conflicting generations", 4)
        expected_predecessor = older[3][3]
        if not hmac.compare_digest(newer[3][1], expected_predecessor):
            raise StateError("catalog-root-invalid", "catalog A/B predecessor chain is invalid", 4)
    return valid[-1]


def _instance_record_image(slot: str, image_size: int, generation: int,
                           predecessor: bytes, payload: dict) -> bytes:
    encoded = _catalog_json(payload)
    if (image_size < 512 or len(encoded) > image_size - 128 or
            generation < 1 or len(predecessor) != 32):
        raise StateError("state-too-large", f"{slot} payload exceeds its fixed slot", 4)
    image = bytearray(image_size)
    image[0:8] = b"ZYZREC1\0"
    struct.pack_into(">HHQI", image, 8, 1, 0, generation, len(encoded))
    image[24:56] = predecessor
    image[96:128] = _catalog_digest(b"zyz-instance-record-payload-v1", encoded)
    image[128:128 + len(encoded)] = encoded
    source = bytearray(image); source[56:88] = bytes(32)
    image[56:88] = _catalog_digest(b"zyz-instance-record-image-v1", bytes(source))
    return bytes(image)


def _instance_parse_record(raw: bytes, slot: str) -> tuple[int, bytes, dict, bytes]:
    if len(raw) < 512 or raw[0:8] != b"ZYZREC1\0":
        raise StateError("invalid-schema", f"{slot} record magic is invalid", 4)
    schema, flags, generation, payload_len = struct.unpack_from(">HHQI", raw, 8)
    if schema != 1 or flags != 0 or generation < 1 or payload_len > len(raw) - 128:
        raise StateError("invalid-schema", f"{slot} record header is invalid", 4)
    source = bytearray(raw); source[56:88] = bytes(32)
    if not hmac.compare_digest(raw[56:88], _catalog_digest(
            b"zyz-instance-record-image-v1", bytes(source))):
        raise StateError("invalid-schema", f"{slot} record checksum is invalid", 4)
    encoded = raw[128:128 + payload_len]
    if (raw[128 + payload_len:] != bytes(len(raw) - 128 - payload_len) or
            not hmac.compare_digest(raw[96:128], _catalog_digest(
                b"zyz-instance-record-payload-v1", encoded))):
        raise StateError("invalid-schema", f"{slot} record payload projection is invalid", 4)
    try: payload = json.loads(encoded)
    except Exception: raise StateError("invalid-schema", f"{slot} record payload is invalid", 4)
    if not isinstance(payload, dict):
        raise StateError("invalid-schema", f"{slot} record payload is not an object", 4)
    digest = _catalog_digest(b"zyz-instance-record-id-v1", raw)
    return generation, raw[24:56], payload, digest


def _instance_header_magic(kind: str) -> bytes:
    if kind == "audit": return b"ZYZAUDH1"
    if kind == "work": return b"ZYZWORH1"
    if kind == "claim": return b"ZYZCLMH1"
    raise StateError("gc-internal", "unknown instance pack kind", 1)


def _instance_pack_layout(kind: str):
    if kind == "audit": return INSTANCE_AUDIT_SIZE, INSTANCE_AUDIT_SLOTS
    if kind == "work": return INSTANCE_WORK_SIZE, INSTANCE_WORK_SLOTS
    if kind == "claim": return CLAIM_PACK_SIZE, CLAIM_PACK_SLOTS
    raise StateError("gc-internal", "unknown instance pack kind", 1)


def _instance_validate_header(value: dict, kind: str, key: str) -> None:
    required = {"schema_version", "pack_kind", "instance_key", "generation", "selected"}
    if (set(value) != required or value.get("schema_version") != 1 or
            value.get("pack_kind") != kind or value.get("instance_key") != key or
            not isinstance(value.get("generation"), int) or value["generation"] < 1 or
            not isinstance(value.get("selected"), dict)):
        raise StateError("invalid-schema", f"{kind} pack header is invalid", 4)
    _, layout = _instance_pack_layout(kind)
    if set(value["selected"]) - set(layout):
        raise StateError("invalid-schema", f"{kind} pack selects an unknown slot", 4)
    for slot, selected in value["selected"].items():
        if (not isinstance(selected, dict) or set(selected) != {"bank", "generation", "digest"} or
                selected["bank"] not in (0, 1) or
                not isinstance(selected["generation"], int) or selected["generation"] < 1 or
                not isinstance(selected["digest"], str) or not HEX64.fullmatch(selected["digest"])):
            raise StateError("invalid-schema", f"{kind} pack slot selector is invalid", 4)


def _instance_pack_header(fd: int, kind: str, key: str):
    return _catalog_select_ab(fd, 0, INSTANCE_PACK_HEADER_SIZE,
                              _instance_header_magic(kind),
                              lambda value: _instance_validate_header(value, kind, key))


def _instance_pack_initialize(fd: int, kind: str, key: str) -> None:
    size, layout = _instance_pack_layout(kind)
    if os.fstat(fd).st_size != size:
        raise StateError("invalid-schema", f"{kind} pack size is invalid", 4)
    header = _catalog_image(_instance_header_magic(kind), INSTANCE_PACK_HEADER_SIZE,
                            1, bytes(32), {"schema_version": 1, "pack_kind": kind,
                                           "instance_key": key, "generation": 1,
                                           "selected": {}})
    _catalog_pwrite_all(fd, header, 0, f"{kind} pack header")
    _data_sync(fd)
    used_end = max(offset + length for offset, length in layout.values())
    if _catalog_pread_exact(fd, size - used_end, used_end) != bytes(size - used_end):
        raise StateError("invalid-schema", f"{kind} pack headroom is not zero", 4)


def _instance_pack_read_fd(fd: int, kind: str, key: str, slot: str) -> dict | None:
    _, layout = _instance_pack_layout(kind)
    if slot not in layout:
        raise StateError("gc-internal", "unknown instance pack slot", 1)
    header = _instance_pack_header(fd, kind, key)
    selected = header[3][2]["selected"].get(slot)
    if selected is None:
        return None
    offset, length = layout[slot]
    half = length // 2
    raw = _catalog_pread_exact(fd, half, offset + selected["bank"] * half)
    record = _instance_parse_record(raw, slot)
    if (record[0] != selected["generation"] or
            not hmac.compare_digest(record[3].hex(), selected["digest"])):
        raise StateError("invalid-schema", f"{slot} selector/digest mismatch", 4)
    return record[2]


def _instance_pack_write_fd(fd: int, kind: str, key: str, slot: str,
                            payload: dict,
                            barrier_domain: str | None = None) -> tuple[int, str]:
    _, layout = _instance_pack_layout(kind)
    if slot not in layout:
        raise StateError("gc-internal", "unknown instance pack slot", 1)
    header = _instance_pack_header(fd, kind, key)
    header_meta = header[3][2]
    prior = header_meta["selected"].get(slot)
    offset, length = layout[slot]
    half = length // 2
    bank = 0 if prior is None else 1 - prior["bank"]
    generation = 1 if prior is None else prior["generation"] + 1
    predecessor = bytes(32) if prior is None else bytes.fromhex(prior["digest"])
    record = _instance_record_image(slot, half, generation, predecessor, payload)
    record_digest = _catalog_digest(b"zyz-instance-record-id-v1", record)
    _catalog_pwrite_all(fd, record, offset + bank * half, f"{slot} inactive record")
    _data_sync(fd)
    if barrier_domain is not None:
        _catalog_barrier(barrier_domain, f"{slot}-inactive-written")

    selected = dict(header_meta["selected"])
    selected[slot] = {"bank": bank, "generation": generation, "digest": record_digest.hex()}
    next_meta = {"schema_version": 1, "pack_kind": kind, "instance_key": key,
                 "generation": header[0] + 1, "selected": selected}
    next_header = _catalog_image(_instance_header_magic(kind), INSTANCE_PACK_HEADER_SIZE,
                                 header[0] + 1, header[3][3], next_meta)
    header_bank = 1 - header[1]
    _catalog_pwrite_all(fd, next_header, header_bank * INSTANCE_PACK_HEADER_SIZE,
                        f"{kind} pack header successor")
    _data_sync(fd)
    if barrier_domain is not None:
        _catalog_barrier(barrier_domain, f"{slot}-header-committed")
    return generation, record_digest.hex()


def _instance_pack_retire_slots_fd(fd: int, kind: str, key: str,
                                   slots: tuple[str, ...]) -> None:
    header = _instance_pack_header(fd, kind, key)
    metadata = header[3][2]
    selected = dict(metadata["selected"])
    changed = False
    for slot in slots:
        if slot in selected:
            selected.pop(slot); changed = True
    if not changed:
        return
    successor_meta = {"schema_version": 1, "pack_kind": kind,
                      "instance_key": key, "generation": header[0] + 1,
                      "selected": selected}
    successor = _catalog_image(_instance_header_magic(kind), INSTANCE_PACK_HEADER_SIZE,
                               header[0] + 1, header[3][3], successor_meta)
    bank = 1 - header[1]
    _catalog_pwrite_all(fd, successor, bank * INSTANCE_PACK_HEADER_SIZE,
                        f"{kind} pack terminal selector successor")
    _data_sync(fd)


def _instance_local_read_fd(fd: int, kind: str, slot: str) -> dict | None:
    _, layout = _instance_pack_layout(kind)
    offset, length = layout[slot]; half = length // 2
    valid = []
    for bank in (0, 1):
        raw = _catalog_pread_exact(fd, half, offset + bank * half)
        if raw == bytes(half): continue
        try: valid.append((*_instance_parse_record(raw, slot), bank))
        except StateError: continue
    if not valid: return None
    valid.sort(key=lambda item: item[0])
    if len(valid) == 2:
        if valid[0][0] == valid[1][0] or not hmac.compare_digest(valid[1][1], valid[0][3]):
            raise StateError("invalid-schema", f"{slot} local A/B chain is invalid", 4)
    return valid[-1][2]


def _instance_local_write_fd(fd: int, kind: str, slot: str, payload: dict) -> tuple[int, str]:
    _, layout = _instance_pack_layout(kind)
    offset, length = layout[slot]; half = length // 2
    states = []
    for bank in (0, 1):
        raw = _catalog_pread_exact(fd, half, offset + bank * half)
        if raw == bytes(half): continue
        try: states.append((*_instance_parse_record(raw, slot), bank))
        except StateError: continue
    states.sort(key=lambda item: item[0])
    current = states[-1] if states else None
    bank = 0 if current is None else 1 - current[4]
    generation = 1 if current is None else current[0] + 1
    predecessor = bytes(32) if current is None else current[3]
    record = _instance_record_image(slot, half, generation, predecessor, payload)
    digest = _catalog_digest(b"zyz-instance-record-id-v1", record)
    _catalog_pwrite_all(fd, record, offset + bank * half, f"{slot} local inactive record")
    _data_sync(fd)
    return generation, digest.hex()


def _catalog_free_material(index: int, free_generation: int = 0,
                           predecessor_record_digest: bytes | None = None,
                           kind: int = 0, prior_fact: bytes | None = None,
                           group_fact: bytes | None = None,
                           cell_generation: int | None = None) -> dict[str, bytes]:
    cell_generation = free_generation if cell_generation is None else cell_generation
    if (not 0 <= index < CATALOG_CELL_COUNT or free_generation < 0 or
            cell_generation < 0 or kind not in (0, 1, 2)):
        raise StateError("gc-internal", "global-layout-overflow", 5)
    predecessor = bytes(32) if predecessor_record_digest is None else predecessor_record_digest
    prior = bytes(32) if prior_fact is None else prior_fact
    group = bytes(32) if group_fact is None else group_fact
    if any(len(item) != 32 for item in (predecessor, prior, group)):
        raise StateError("gc-internal", "global-layout-overflow", 5)
    core = struct.pack(">8sHHIQQ32s", b"ZYZCFV1\0", 1, 0, index,
                       cell_generation, free_generation, prior)
    core_digest = _catalog_digest(b"zyz-cell-free-core-v1", core)
    body = (struct.pack(">8sB7xIQ", b"ZYZFRB1\0", kind, index, free_generation) +
            predecessor + prior + group + core_digest)
    body_digest = _catalog_digest(b"zyz-free-receipt-body-v1", body)
    final_cell = core + body_digest
    final_digest = _catalog_digest(b"zyz-final-cell-image-v1", final_cell)
    persisted = body + body_digest + final_digest
    record_digest = _catalog_digest(b"zyz-free-receipt-record-v1", persisted)
    return {"core": core, "core_digest": core_digest, "body": body,
            "body_digest": body_digest, "final_cell": final_cell,
            "final_cell_digest": final_digest, "persisted": persisted,
            "record_digest": record_digest, "predecessor": predecessor,
            "prior": prior, "group": group}


def _catalog_recovery_free_image(index: int, material: dict[str, bytes]) -> bytes:
    core_magic, core_schema, core_flags, core_index, cell_generation, free_generation, _ = struct.unpack(
        ">8sHHIQQ32s", material["core"])
    if (core_magic, core_schema, core_flags, core_index) != (b"ZYZCFV1\0", 1, 0, index):
        raise StateError("gc-internal", "global-layout-overflow", 5)
    image = bytearray(CATALOG_RECOVERY_IMAGE_SIZE)
    image[0:8] = b"ZYZRCV1\0"
    struct.pack_into(">HHIQQ", image, 8, 1, 0, index,
                     cell_generation, free_generation)
    image[64:64 + len(material["core"])] = material["core"]
    image[128:160] = material["core_digest"]
    image[160:192] = material["body_digest"]
    image[192:224] = material["final_cell_digest"]
    checksum_source = bytearray(image); checksum_source[32:64] = bytes(32)
    image[32:64] = _catalog_digest(b"zyz-recovery-cell-image-v1", bytes(checksum_source))
    return bytes(image)


def _catalog_validate_recovery_free(raw: bytes, index: int,
                                    material: dict[str, bytes] | None = None) -> bytes:
    if len(raw) != CATALOG_RECOVERY_IMAGE_SIZE or raw[0:8] != b"ZYZRCV1\0":
        raise StateError("catalog-root-invalid", "recovery CELL magic is invalid", 4)
    schema, state, observed_index, cell_gen, free_gen = struct.unpack_from(">HHIQQ", raw, 8)
    if (schema, state, observed_index) != (1, 0, index):
        raise StateError("catalog-root-invalid", "recovery CELL header is invalid", 4)
    source = bytearray(raw); source[32:64] = bytes(32)
    if not hmac.compare_digest(raw[32:64], _catalog_digest(b"zyz-recovery-cell-image-v1", bytes(source))):
        raise StateError("catalog-root-invalid", "recovery CELL checksum is invalid", 4)
    core = raw[64:128]
    try:
        core_magic, core_schema, core_flags, core_index, core_cell_gen, core_free_gen, _ = struct.unpack(
            ">8sHHIQQ32s", core)
    except struct.error:
        raise StateError("catalog-root-invalid", "recovery CELL FREE core is invalid", 4)
    if ((core_magic, core_schema, core_flags, core_index, core_cell_gen, core_free_gen) !=
            (b"ZYZCFV1\0", 1, 0, index, cell_gen, free_gen) or
            raw[128:160] != _catalog_digest(b"zyz-cell-free-core-v1", core) or
            raw[192:224] != _catalog_digest(
                b"zyz-final-cell-image-v1", core + raw[160:192]) or
            raw[224:] != bytes(CATALOG_RECOVERY_IMAGE_SIZE - 224)):
        raise StateError("catalog-root-invalid", "recovery CELL FREE projection is invalid", 4)
    if material is not None and (raw[64:128] != material["core"] or
            raw[128:160] != material["core_digest"] or
            raw[160:192] != material["body_digest"] or
            raw[192:224] != material["final_cell_digest"]):
        raise StateError("catalog-root-invalid", "recovery CELL FREE material is invalid", 4)
    return _catalog_digest(b"zyz-recovery-cell-selected-v1", raw)


def _catalog_directory_free_image(index: int, material: dict[str, bytes]) -> bytes:
    _, _, _, _, cell_generation, free_generation, _ = struct.unpack(
        ">8sHHIQQ32s", material["core"])
    recovery_image_digest = _catalog_digest(
        b"zyz-recovery-cell-selected-v1",
        _catalog_recovery_free_image(index, material))
    return _catalog_directory_image(index, 0, cell_generation, free_generation,
                                    (material["prior"], recovery_image_digest,
                                     material["record_digest"], material["predecessor"],
                                     material["body_digest"]))


def _catalog_directory_image(index: int, state: int, cell_generation: int,
                             free_generation: int, fields: tuple[bytes, ...]) -> bytes:
    if (not 0 <= index < CATALOG_CELL_COUNT or state not in range(0, 6) or
            not 0 <= cell_generation <= 65535 or not 0 <= free_generation <= 65535 or
            len(fields) != 5 or any(len(value) != 32 for value in fields)):
        raise StateError("gc-internal", "global-layout-overflow", 5)
    image = bytearray(CATALOG_DIRECTORY_IMAGE_SIZE)
    image[0:4] = b"ZCD1"
    struct.pack_into(">BBHIHH", image, 4, 1, state, 0, index, cell_generation, free_generation)
    for field_index, value in enumerate(fields):
        start = 32 + field_index * 32
        image[start:start + 32] = value
    checksum_source = bytearray(image); checksum_source[16:32] = bytes(16)
    image[16:32] = _catalog_digest(b"zyz-cell-directory-image-v1", bytes(checksum_source))[:16]
    return bytes(image)


def _catalog_parse_directory_image(raw: bytes, index: int) -> dict:
    if len(raw) != CATALOG_DIRECTORY_IMAGE_SIZE or raw[0:4] != b"ZCD1":
        raise StateError("catalog-root-invalid", "CELL_DIRECTORY magic is invalid", 4)
    schema, state, flags, observed_index, cell_gen, free_gen = struct.unpack_from(">BBHIHH", raw, 4)
    if schema != 1 or state not in range(0, 6) or flags != 0 or observed_index != index:
        raise StateError("catalog-root-invalid", "CELL_DIRECTORY header is invalid", 4)
    source = bytearray(raw); source[16:32] = bytes(16)
    if not hmac.compare_digest(raw[16:32], _catalog_digest(
            b"zyz-cell-directory-image-v1", bytes(source))[:16]):
        raise StateError("catalog-root-invalid", "CELL_DIRECTORY checksum is invalid", 4)
    return {"state": state, "cell_generation": cell_gen, "free_generation": free_gen,
            "fields": tuple(raw[32 + i * 32:64 + i * 32] for i in range(5)),
            "digest": _catalog_digest(b"zyz-cell-directory-selected-image-v1", raw)}


def _catalog_validate_directory_free(raw: bytes, index: int,
                                     material: dict[str, bytes] | None = None,
                                     recovery_raw: bytes | None = None) -> None:
    parsed = _catalog_parse_directory_image(raw, index)
    if parsed["state"] != 0:
        raise StateError("catalog-root-invalid", "CELL_DIRECTORY FREE header is invalid", 4)
    if material is None and recovery_raw is None:
        material = _catalog_free_material(index)
    if material is None:
        _catalog_validate_recovery_free(recovery_raw, index)
        _, _, _, _, cell_generation, free_generation, prior = struct.unpack(
            ">8sHHIQQ32s", recovery_raw[64:128])
        recovery_image_digest = _catalog_digest(
            b"zyz-recovery-cell-selected-v1", recovery_raw)
        if (parsed["cell_generation"] != cell_generation or
                parsed["free_generation"] != free_generation or
                parsed["fields"][0] != prior or
                parsed["fields"][1] != recovery_image_digest or
                parsed["fields"][4] != recovery_raw[160:192]):
            raise StateError("catalog-root-invalid", "FREE_RECEIPT projection is inconsistent", 4)
        if ((free_generation == 0 and parsed["fields"][3] != bytes(32)) or
                (free_generation > 0 and parsed["fields"][3] == bytes(32)) or
                parsed["fields"][2] == bytes(32)):
            raise StateError("catalog-root-invalid", "FREE_RECEIPT history is invalid", 4)

        # A selected GENESIS or ordinary FREE projection contains every input
        # needed to rebuild the canonical receipt material.  Do that rebuild
        # before accepting the ROOT aggregate: an entry checksum and a rebound
        # whole-directory digest authenticate bytes, but cannot establish that
        # the current-receipt field uses the record-digest domain rather than a
        # body/final/CELL digest domain.
        expected = None
        if free_generation == 0:
            expected = _catalog_free_material(index)
        else:
            ordinary = _catalog_free_material(
                index, free_generation, parsed["fields"][3], 1,
                parsed["fields"][0], cell_generation=cell_generation)
            if hmac.compare_digest(
                    recovery_raw[160:192], ordinary["body_digest"]):
                expected = ordinary
        if expected is not None:
            expected_recovery = _catalog_recovery_free_image(index, expected)
            if (not hmac.compare_digest(recovery_raw, expected_recovery) or
                    parsed["fields"] != (
                        expected["prior"], recovery_image_digest,
                        expected["record_digest"], expected["predecessor"],
                        expected["body_digest"])):
                raise StateError(
                    "catalog-root-invalid",
                    "FREE_RECEIPT hash domains are inconsistent", 4)
            return

        # PREVIS material also binds a group-visible fact that is not projected
        # into the FREE recovery image, so this local projection cannot rebuild
        # that complete preimage.  Still reject every alternate digest domain
        # available here before any caller can treat a coherently rebound ROOT
        # as authority.
        alternate_domains = {
            recovery_raw[128:160], recovery_raw[160:192],
            recovery_raw[192:224], recovery_image_digest,
        }
        if parsed["fields"][2] in alternate_domains:
            raise StateError(
                "catalog-root-invalid",
                "FREE_RECEIPT record digest uses an alternate hash domain", 4)
        return
    expected = material
    recovery_image_digest = _catalog_digest(
        b"zyz-recovery-cell-selected-v1",
        _catalog_recovery_free_image(index, expected))
    _, _, _, _, cell_generation, free_generation, _ = struct.unpack(
        ">8sHHIQQ32s", expected["core"])
    if ((parsed["cell_generation"], parsed["free_generation"]) !=
            (cell_generation, free_generation) or
            parsed["fields"] != (expected["prior"], recovery_image_digest,
                             expected["record_digest"], expected["predecessor"],
                             expected["body_digest"])):
        raise StateError("catalog-root-invalid", "FREE_RECEIPT hash domains are inconsistent", 4)


def _catalog_recovery_dynamic_image(index: int, state: int, generation: int,
                                    payload: dict) -> bytes:
    state_names = {1: "RESERVED", 2: "OWNER_ACTIVE", 3: "ACTIVE_ACK",
                   4: "DELTA_WILL", 5: "DELTA_APPLIED",
                   6: "FLUSH_ACKED", 7: "CELL_FREE_WILL",
                   8: "PREVIS_CANCELLED", 9: "PREVIS_FREE_WILL"}
    def field(name: str, zero: bool = False) -> bytes:
        value = payload.get(name)
        if zero and value is None:
            return bytes(32)
        if not isinstance(value, str) or not HEX64.fullmatch(value):
            raise StateError("gc-internal", "recovery-cell-overflow", 5)
        return bytes.fromhex(value)
    operation_region = payload.get("_operation_region", bytes(272))
    if (state not in state_names or generation < 1 or generation > 65535 or
            payload.get("schema") != 1 or payload.get("state") != state_names[state] or
            not isinstance(operation_region, bytes) or len(operation_region) != 272):
        raise StateError("gc-internal", "recovery-cell-overflow", 5)
    image = bytearray(CATALOG_RECOVERY_IMAGE_SIZE)
    image[0:8] = b"ZYZRCV1\0"
    struct.pack_into(">HHIQQ", image, 8, 1, state, index, generation, 0)
    image[64:72] = b"ZYZOWN1\0"
    struct.pack_into(">HBBI", image, 72, 1, state, 1, 0)
    image[80:112] = field("subject_digest")
    image[112:144] = field("reservation_digest")
    image[144:176] = field("object_identities_digest", True)
    image[176:208] = field("consumed_free_receipt_record_digest")
    image[208:480] = operation_region
    source = bytearray(image); source[32:64] = bytes(32)
    image[32:64] = _catalog_digest(b"zyz-recovery-cell-image-v1", bytes(source))
    return bytes(image)


def _catalog_recovery_creator_region(key: str, request_bytes: int) -> bytes:
    encoded = key.encode("ascii")
    if (not (KEY_RE.fullmatch(key) or
             key.startswith("claim.") and HEX64.fullmatch(key[6:])) or
            not 1 <= len(encoded) <= 128 or
            not isinstance(request_bytes, int) or request_bytes < 1):
        raise StateError("gc-internal", "creator locator input is invalid", 5)
    region = bytearray(272)
    region[0:8] = b"ZYZLOC1\0"
    struct.pack_into(">HHIQ", region, 8, 1, len(encoded), 0, request_bytes)
    region[24:24 + len(encoded)] = encoded
    region[160:192] = _catalog_digest(
        b"zyz-creator-locator-v1", bytes(region[:160]))
    return bytes(region)


def _catalog_parse_recovery_image(raw: bytes, index: int) -> dict:
    if len(raw) != CATALOG_RECOVERY_IMAGE_SIZE or raw[0:8] != b"ZYZRCV1\0":
        raise StateError("catalog-root-invalid", "recovery CELL magic is invalid", 4)
    schema, state, observed_index, generation, free_generation = struct.unpack_from(">HHIQQ", raw, 8)
    if schema != 1 or state not in range(0, 10) or observed_index != index:
        raise StateError("catalog-root-invalid", "recovery CELL header is invalid", 4)
    source = bytearray(raw); source[32:64] = bytes(32)
    if not hmac.compare_digest(raw[32:64], _catalog_digest(b"zyz-recovery-cell-image-v1", bytes(source))):
        raise StateError("catalog-root-invalid", "recovery CELL checksum is invalid", 4)
    if state == 0:
        _catalog_validate_recovery_free(raw, index)
        payload = {"state": "FREE"}
    else:
        state_names = {1: "RESERVED", 2: "OWNER_ACTIVE", 3: "ACTIVE_ACK",
                       4: "DELTA_WILL", 5: "DELTA_APPLIED",
                       6: "FLUSH_ACKED", 7: "CELL_FREE_WILL",
                       8: "PREVIS_CANCELLED", 9: "PREVIS_FREE_WILL"}
        owner_schema, owner_state, owner_kind, owner_flags = struct.unpack_from(">HBBI", raw, 72)
        if (raw[64:72] != b"ZYZOWN1\0" or owner_schema != 1 or owner_state != state or
                owner_kind != 1 or owner_flags != 0 or state not in state_names or
                raw[480:] != bytes(32)):
            raise StateError("catalog-root-invalid", "recovery CELL owner frame is invalid", 4)
        object_digest = raw[144:176]
        if ((state in (1, 8, 9) and object_digest != bytes(32)) or
                (state not in (1, 8, 9) and object_digest == bytes(32)) or
                any(raw[start:start + 32] == bytes(32) for start in (80, 112, 176))):
            raise StateError("catalog-root-invalid", "recovery CELL owner facts are invalid", 4)
        payload = {"schema": 1, "state": state_names[state],
                   "subject_digest": raw[80:112].hex(),
                   "reservation_digest": raw[112:144].hex(),
                   "object_identities_digest": None if object_digest == bytes(32) else object_digest.hex(),
                   "consumed_free_receipt_record_digest": raw[176:208].hex(),
                   "_operation_region": raw[208:480]}
        operations = {}
        previs = None
        if state in (8, 9):
            region = raw[208:480]
            if region[0:8] != b"ZYZPCV1\0" or region[164:] != bytes(108):
                raise StateError("catalog-root-invalid", "PREVIS recovery region is invalid", 4)
            previs_schema, previs_phase, previs_flags = struct.unpack_from(">HBB", region, 8)
            group_generation, source_segment, frame_offset = struct.unpack_from(">QQQ", region, 12)
            if (previs_schema != 1 or previs_phase not in (1, 2) or previs_flags != 0 or
                    group_generation < 1 or source_segment < 1 or
                    region[36:68] == bytes(32) or region[68:100] == bytes(32) or
                    (previs_phase == 1 and region[100:132] != bytes(32)) or
                    (previs_phase == 2 and region[100:132] == bytes(32)) or
                    region[132:164] == bytes(32)):
                raise StateError("catalog-root-invalid", "PREVIS recovery facts are invalid", 4)
            previs = {"phase": "cancelled" if previs_phase == 1 else "free-will",
                      "group_generation": group_generation,
                      "source_segment_generation": source_segment,
                      "frame_offset": frame_offset,
                      "frame_digest": region[36:68].hex(),
                      "cancel_digest": region[68:100].hex(),
                      "group_visible_digest": (None if previs_phase == 1 else
                                                 region[100:132].hex()),
                      "free_receipt_record_digest": region[132:164].hex()}
        elif raw[208:216] == b"ZYZLOC1\0":
            region = raw[208:480]
            locator_schema, key_length, locator_flags, request_bytes = \
                struct.unpack_from(">HHIQ", region, 8)
            key_raw = region[24:24 + key_length]
            try:
                creator_key = key_raw.decode("ascii")
            except UnicodeDecodeError:
                creator_key = ""
            if (locator_schema != 1 or locator_flags != 0 or
                    not 1 <= key_length <= 128 or request_bytes < 1 or
                    region[24 + key_length:160] != bytes(136 - key_length) or
                    region[160:192] != _catalog_digest(
                        b"zyz-creator-locator-v1", region[:160]) or
                    region[192:] != bytes(80) or
                    not (KEY_RE.fullmatch(creator_key) or
                         creator_key.startswith("claim.") and
                         HEX64.fullmatch(creator_key[6:]))):
                raise StateError("catalog-root-invalid",
                                 "recovery creator locator is invalid", 4)
            payload["_creator_key"] = creator_key
            payload["_request_bytes"] = request_bytes
            payload["_operations"] = {}
            payload["_flush"] = None
        else:
            for name, offset, expected_kind in (("SETTLE", 208, 1), ("RELEASE", 304, 2)):
                slot = raw[offset:offset + 96]
                if slot == bytes(96):
                    continue
                if slot[0:8] != b"ZYZOPV1\0" or slot[92:96] != bytes(4):
                    raise StateError("catalog-root-invalid", "recovery operation slot is invalid", 4)
                op_schema, op_kind, phase = struct.unpack_from(">HBB", slot, 8)
                delta, root_generation = struct.unpack_from(">qQ", slot, 12)
                if (op_schema != 1 or op_kind != expected_kind or phase not in (1, 2) or
                        delta == 0 or root_generation < 1 or slot[28:60] == bytes(32) or
                        slot[60:92] == bytes(32)):
                    raise StateError("catalog-root-invalid", "recovery operation facts are invalid", 4)
                operations[name] = {"phase": "will" if phase == 1 else "applied",
                                    "delta": delta, "root_generation": root_generation,
                                    "op_digest": slot[28:60].hex(),
                                    "root_digest": slot[60:92].hex()}
        union = raw[400:480]
        flush = None
        if union != bytes(80):
            if union[0:8] != b"ZYZFLV1\0" or union[68:80] != bytes(12):
                raise StateError("catalog-root-invalid", "recovery flush/free union is invalid", 4)
            union_schema, union_phase, union_flags = struct.unpack_from(">HBB", union, 8)
            segment_generation, frame_offset = struct.unpack_from(">QQ", union, 12)
            frame_length, operation_count = struct.unpack_from(">II", union, 28)
            if (union_schema != 1 or union_phase not in (1, 2, 3) or union_flags != 0 or
                    segment_generation < 1 or frame_length < 64 or operation_count not in (1, 2) or
                    union[36:68] == bytes(32)):
                raise StateError("catalog-root-invalid", "recovery flush/free facts are invalid", 4)
            flush = {"phase": {1: "will", 2: "acked", 3: "free-will"}[union_phase],
                     "segment_generation": segment_generation,
                     "frame_offset": frame_offset, "frame_length": frame_length,
                     "operation_count": operation_count,
                     "frame_digest": union[36:68].hex()}
        if ((state == 4 and not any(value["phase"] == "will" for value in operations.values())) or
                (state == 5 and (not operations or
                                 any(value["phase"] != "applied" for value in operations.values()))) or
                (state == 6 and (flush is None or flush["phase"] != "will")) or
                (state == 7 and (flush is None or flush["phase"] not in ("acked", "free-will"))) or
                (state == 8 and (previs is None or previs["phase"] != "cancelled")) or
                (state == 9 and (previs is None or previs["phase"] != "free-will"))):
            raise StateError("catalog-root-invalid", "recovery operation phase is invalid", 4)
        payload["_operations"] = operations
        payload["_flush"] = flush
        payload["_previs"] = previs
    return {"state": state, "generation": generation, "free_generation": free_generation,
            "payload": payload, "digest": _catalog_digest(b"zyz-recovery-cell-selected-v1", raw)}


def _catalog_recovery_operation_region(payload: dict, kind: str, phase: str,
                                       delta: int, root_generation: int,
                                       op_digest: bytes, root_digest: bytes) -> bytes:
    if (kind not in ("SETTLE", "RELEASE") or phase not in ("will", "applied") or
            delta == 0 or root_generation < 1 or len(op_digest) != 32 or
            len(root_digest) != 32):
        raise StateError("gc-internal", "recovery-cell-overflow", 5)
    region = bytearray(bytes(272) if payload.get("_creator_key") is not None
                       else payload.get("_operation_region", bytes(272)))
    if len(region) != 272:
        raise StateError("gc-internal", "recovery-cell-overflow", 5)
    offset = 0 if kind == "SETTLE" else 96
    prior = bytes(region[offset:offset + 96])
    if prior != bytes(96):
        parsed = payload.get("_operations", {}).get(kind)
        if (not isinstance(parsed, dict) or parsed.get("op_digest") != op_digest.hex() or
                parsed.get("delta") != delta):
            raise StateError("catalog-root-invalid", f"{kind} operation conflicts", 4)
    slot = bytearray(96); slot[0:8] = b"ZYZOPV1\0"
    struct.pack_into(">HBBqQ", slot, 8, 1, 1 if kind == "SETTLE" else 2,
                     1 if phase == "will" else 2, delta, root_generation)
    slot[28:60] = op_digest; slot[60:92] = root_digest
    region[offset:offset + 96] = slot
    return bytes(region)


def _catalog_recovery_flush_region(payload: dict, phase: str,
                                   segment_generation: int, frame_offset: int,
                                   frame: bytes, operation_count: int) -> bytes:
    if (phase not in ("will", "acked", "free-will") or segment_generation < 1 or
            frame_offset < 0 or len(frame) < 64 or operation_count not in (1, 2)):
        raise StateError("gc-internal", "recovery-cell-overflow", 5)
    region = bytearray(payload.get("_operation_region", bytes(272)))
    if len(region) != 272:
        raise StateError("gc-internal", "recovery-cell-overflow", 5)
    union = bytearray(80); union[0:8] = b"ZYZFLV1\0"
    struct.pack_into(">HBBQQII", union, 8, 1,
                     {"will": 1, "acked": 2, "free-will": 3}[phase], 0,
                     segment_generation, frame_offset, len(frame), operation_count)
    union[36:68] = _catalog_digest(b"zyz-catalog-frame-v1", frame)
    region[192:272] = union
    return bytes(region)


def _catalog_recovery_previs_region(group_generation: int,
                                    source_segment_generation: int,
                                    frame_offset: int, frame_digest: bytes,
                                    cancel_digest: bytes,
                                    free_receipt_record_digest: bytes,
                                    group_visible_digest: bytes | None = None) -> bytes:
    phase = 1 if group_visible_digest is None else 2
    if (group_generation < 1 or source_segment_generation < 1 or frame_offset < 0 or
            any(len(value) != 32 for value in
                (frame_digest, cancel_digest, free_receipt_record_digest)) or
            (group_visible_digest is not None and len(group_visible_digest) != 32)):
        raise StateError("gc-internal", "recovery-cell-overflow", 5)
    region = bytearray(272)
    region[0:8] = b"ZYZPCV1\0"
    struct.pack_into(">HBBQQQ", region, 8, 1, phase, 0, group_generation,
                     source_segment_generation, frame_offset)
    region[36:68] = frame_digest
    region[68:100] = cancel_digest
    if group_visible_digest is not None:
        region[100:132] = group_visible_digest
    region[132:164] = free_receipt_record_digest
    return bytes(region)


def _catalog_selector_bank(selector: bytes, index: int) -> int:
    return (selector[index // 8] >> (index % 8)) & 1


def _catalog_selector_set(selector: bytes, index: int, bank: int) -> bytes:
    value = bytearray(selector)
    mask = 1 << (index % 8)
    if bank: value[index // 8] |= mask
    else: value[index // 8] &= ~mask
    return bytes(value)


def _catalog_directory_aggregates(global_fd: int, recovery_fd: int,
                                  validate: bool = True,
                                  selector: bytes | None = None) -> dict:
    selector = bytes(1024) if selector is None else selector
    if len(selector) != 1024:
        raise StateError("catalog-root-invalid", "ROOT selector length is invalid", 4)
    generations = hashlib.sha256(b"zyz-cell-generation-vector-v1")
    directory = hashlib.sha256(b"zyz-cell-directory-selected-v1")
    recovery = hashlib.sha256(b"zyz-recovery-selected-v1")
    pending_append_wills = []
    for index in range(CATALOG_CELL_COUNT):
        bank = _catalog_selector_bank(selector, index)
        directory_base = CATALOG_LAYOUT["cell_directory_a"][0] if bank == 0 else CATALOG_LAYOUT["cell_directory_b"][0]
        entry = _catalog_pread_exact(global_fd, CATALOG_DIRECTORY_IMAGE_SIZE,
                                     directory_base + index * CATALOG_DIRECTORY_IMAGE_SIZE)
        parsed_entry = _catalog_parse_directory_image(entry, index)
        cell_a = _catalog_pread_exact(recovery_fd, CATALOG_RECOVERY_IMAGE_SIZE,
                                      index * CATALOG_RECOVERY_CELL_SIZE)
        cell_b = _catalog_pread_exact(recovery_fd, CATALOG_RECOVERY_IMAGE_SIZE,
                                      index * CATALOG_RECOVERY_CELL_SIZE + CATALOG_RECOVERY_IMAGE_SIZE)
        recovery_valid = []
        for recovery_bank, cell in enumerate((cell_a, cell_b)):
            if cell == bytes(CATALOG_RECOVERY_IMAGE_SIZE): continue
            try: recovery_valid.append((recovery_bank, _catalog_parse_recovery_image(cell, index), cell))
            except StateError: continue
        matching = [item for item in recovery_valid
                    if item[1]["generation"] == parsed_entry["cell_generation"] and
                    hmac.compare_digest(item[1]["digest"], parsed_entry["fields"][1])]
        if len(matching) != 1:
            raise StateError("catalog-root-invalid", "CELL_DIRECTORY/recovery CELL mismatch", 4)
        selected_payload = matching[0][1]["payload"]
        if validate and parsed_entry["state"] == 0:
            _catalog_validate_directory_free(entry, index, recovery_raw=matching[0][2])
        elif parsed_entry["state"] == 1:
            if (matching[0][1]["state"] != 1 or selected_payload.get("state") != "RESERVED" or
                    selected_payload.get("subject_digest") != parsed_entry["fields"][0].hex() or
                    selected_payload.get("reservation_digest") != parsed_entry["fields"][2].hex() or
                    selected_payload.get("consumed_free_receipt_record_digest") !=
                        parsed_entry["fields"][3].hex()):
                raise StateError("catalog-root-invalid", "reserved recovery owner frame is invalid", 4)
        elif parsed_entry["state"] in (2, 3):
            if (matching[0][1]["state"] not in (2, 3, 4, 5, 6, 7) or selected_payload.get("state") not in
                    ("OWNER_ACTIVE", "ACTIVE_ACK", "DELTA_WILL", "DELTA_APPLIED",
                     "FLUSH_ACKED", "CELL_FREE_WILL") or
                    selected_payload.get("subject_digest") != parsed_entry["fields"][0].hex() or
                    selected_payload.get("reservation_digest") != parsed_entry["fields"][2].hex() or
                    selected_payload.get("object_identities_digest") != parsed_entry["fields"][4].hex() or
                    selected_payload.get("consumed_free_receipt_record_digest") !=
                        parsed_entry["fields"][3].hex()):
                raise StateError("catalog-root-invalid", "active recovery owner frame is invalid", 4)
        elif parsed_entry["state"] in (4, 5):
            expected_recovery_state = 8 if parsed_entry["state"] == 4 else 9
            expected_phase = "cancelled" if parsed_entry["state"] == 4 else "free-will"
            previs = selected_payload.get("_previs")
            if (matching[0][1]["state"] != expected_recovery_state or
                    selected_payload.get("state") not in
                        ("PREVIS_CANCELLED", "PREVIS_FREE_WILL") or
                    selected_payload.get("subject_digest") != parsed_entry["fields"][0].hex() or
                    selected_payload.get("reservation_digest") != parsed_entry["fields"][2].hex() or
                    selected_payload.get("consumed_free_receipt_record_digest") !=
                        parsed_entry["fields"][3].hex() or
                    not isinstance(previs, dict) or previs.get("phase") != expected_phase or
                    previs.get("cancel_digest") != parsed_entry["fields"][4].hex()):
                raise StateError("catalog-root-invalid", "PREVIS recovery owner frame is invalid", 4)
        flush = selected_payload.get("_flush")
        if isinstance(flush, dict) and flush.get("phase") in ("will", "free-will"):
            pending_append_wills.append({name: flush.get(name) for name in
                                         ("segment_generation", "frame_offset",
                                          "frame_length", "frame_digest")})
        generations.update(struct.pack(">IQB", index, parsed_entry["cell_generation"], bank))
        directory.update(struct.pack(">IB", index, bank)); directory.update(entry)
        recovery.update(struct.pack(">IB", index, matching[0][0])); recovery.update(matching[0][2])
    return {"selector": selector,
            "selector_digest": _catalog_digest(b"zyz-root-selector-v1", selector),
            "generation_digest": generations.digest(),
            "directory_digest": directory.digest(),
            "recovery_digest": recovery.digest(),
            "pending_append_wills": pending_append_wills}


def raw_bytes(value: str) -> bytes:
    return os.fsencode(value)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha_file(path: Path, ceiling: int = 2147483647) -> str:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(os.fsencode(path), flags); digest = hashlib.sha256(); count = 0
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink < 1 or before.st_size > ceiling:
            raise StateError("snapshot-unavailable", "streamed artifact identity/size is invalid")
        while True:
            chunk = os.read(fd, 131072)
            if not chunk: break
            count += len(chunk)
            if count > ceiling: raise StateError("snapshot-unavailable", "streamed artifact ceiling exceeded")
            digest.update(chunk)
        after = os.fstat(fd)
    finally: os.close(fd)
    if ((before.st_dev,before.st_ino,before.st_nlink,before.st_size,before.st_mtime_ns) !=
            (after.st_dev,after.st_ino,after.st_nlink,after.st_size,after.st_mtime_ns) or count != before.st_size):
        raise StateError("snapshot-unavailable", "streamed artifact changed during hashing")
    return digest.hexdigest()


def sha_open_fd(fd: int, ceiling: int = 2147483647) -> str:
    digest = hashlib.sha256(); count = 0
    before = os.fstat(fd)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink < 1 or before.st_size > ceiling:
        raise StateError("snapshot-unavailable", "descriptor artifact identity/size is invalid")
    os.lseek(fd,0,os.SEEK_SET)
    while True:
        chunk=os.read(fd,131072)
        if not chunk: break
        count += len(chunk)
        if count > ceiling:
            raise StateError("snapshot-unavailable", "descriptor artifact ceiling exceeded")
        digest.update(chunk)
    after=os.fstat(fd)
    stable=lambda value:(value.st_dev,value.st_ino,value.st_nlink,value.st_size,
                         value.st_mtime_ns,value.st_ctime_ns)
    if stable(before) != stable(after) or count != before.st_size:
        raise StateError("snapshot-unavailable", "descriptor artifact changed during hashing")
    return digest.hexdigest()


def read_regular_bytes(path: Path, ceiling: int, missing_ok: bool = False) -> tuple[bytes,os.stat_result] | None:
    parent=os.open(os.fsencode(path.parent),os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|
                   getattr(os,"O_NOFOLLOW",0)|getattr(os,"O_CLOEXEC",0))
    fd=-1
    try:
        try: fd=os.open(os.fsencode(path.name),os.O_RDONLY|getattr(os,"O_NOFOLLOW",0)|
                        getattr(os,"O_CLOEXEC",0),dir_fd=parent)
        except FileNotFoundError:
            if missing_ok: return None
            raise
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink < 1 or before.st_size > ceiling:
            raise StateError("invalid-schema",f"descriptor-bound {path.name} identity/size is invalid")
        value=bytearray()
        while len(value) <= ceiling:
            chunk=os.read(fd,min(131072,ceiling+1-len(value)))
            if not chunk: break
            value.extend(chunk)
        after=os.fstat(fd)
        stable=lambda item:(item.st_mode,item.st_dev,item.st_ino,item.st_nlink,item.st_size,
                            item.st_mtime_ns,item.st_ctime_ns)
        if len(value)>ceiling or len(value)!=before.st_size or stable(before)!=stable(after):
            raise StateError("invalid-schema",f"descriptor-bound {path.name} changed or is oversized")
        return bytes(value),before
    finally:
        if fd >= 0: os.close(fd)
        os.close(parent)


def files_equal(left: Path, right: Path, ceiling: int = 2147483647) -> bool:
    left_fd = (left.open_snapshot_fd()[0] if hasattr(left,"open_snapshot_fd") else
               os.open(os.fsencode(left), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)))
    right_fd = (right.open_snapshot_fd()[0] if hasattr(right,"open_snapshot_fd") else
                os.open(os.fsencode(right), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)))
    count = 0
    try:
        ls, rs = os.fstat(left_fd), os.fstat(right_fd)
        if ls.st_size != rs.st_size or ls.st_size > ceiling: return False
        while True:
            a = os.read(left_fd, 131072); b = os.read(right_fd, 131072)
            if a != b: return False
            if not a: break
            count += len(a)
        la, ra = os.fstat(left_fd), os.fstat(right_fd)
    finally:
        os.close(left_fd); os.close(right_fd)
    stable = lambda st: (st.st_dev,st.st_ino,st.st_nlink,st.st_size,st.st_mtime_ns)
    return count == ls.st_size and stable(ls) == stable(la) and stable(rs) == stable(ra)


class ResumableSHA256:
    """Small SHA-256 implementation whose chaining state is checkpointable.

    ``hashlib`` deliberately does not expose its internal state.  Snapshot GC
    must, however, resume a file at an authenticated byte offset without
    rereading an arbitrarily large prefix, so the standard eight words, full
    block count, and partial block are represented explicitly here.
    """
    _INITIAL = (0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
                0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19)
    _K = (
        0x428A2F98,0x71374491,0xB5C0FBCF,0xE9B5DBA5,0x3956C25B,0x59F111F1,0x923F82A4,0xAB1C5ED5,
        0xD807AA98,0x12835B01,0x243185BE,0x550C7DC3,0x72BE5D74,0x80DEB1FE,0x9BDC06A7,0xC19BF174,
        0xE49B69C1,0xEFBE4786,0x0FC19DC6,0x240CA1CC,0x2DE92C6F,0x4A7484AA,0x5CB0A9DC,0x76F988DA,
        0x983E5152,0xA831C66D,0xB00327C8,0xBF597FC7,0xC6E00BF3,0xD5A79147,0x06CA6351,0x14292967,
        0x27B70A85,0x2E1B2138,0x4D2C6DFC,0x53380D13,0x650A7354,0x766A0ABB,0x81C2C92E,0x92722C85,
        0xA2BFE8A1,0xA81A664B,0xC24B8B70,0xC76C51A3,0xD192E819,0xD6990624,0xF40E3585,0x106AA070,
        0x19A4C116,0x1E376C08,0x2748774C,0x34B0BCB5,0x391C0CB3,0x4ED8AA4A,0x5B9CCA4F,0x682E6FF3,
        0x748F82EE,0x78A5636F,0x84C87814,0x8CC70208,0x90BEFFFA,0xA4506CEB,0xBEF9A3F7,0xC67178F2)

    def __init__(self, words=None, full_blocks: int = 0, partial: bytes = b""):
        self.words = list(self._INITIAL if words is None else words)
        self.full_blocks = full_blocks
        self.partial = bytes(partial)
        if (len(self.words) != 8 or any(not isinstance(v, int) or not 0 <= v <= 0xffffffff
                                        for v in self.words) or
                not isinstance(full_blocks, int) or full_blocks < 0 or len(self.partial) >= 64):
            raise StateError("gc-checkpoint-invalid", "resumable SHA-256 state is invalid")

    @staticmethod
    def _ror(value: int, count: int) -> int:
        return ((value >> count) | (value << (32 - count))) & 0xffffffff

    def _compress(self, block: bytes) -> None:
        words = [int.from_bytes(block[i:i + 4], "big") for i in range(0, 64, 4)]
        for i in range(16, 64):
            s0 = self._ror(words[i - 15], 7) ^ self._ror(words[i - 15], 18) ^ (words[i - 15] >> 3)
            s1 = self._ror(words[i - 2], 17) ^ self._ror(words[i - 2], 19) ^ (words[i - 2] >> 10)
            words.append((words[i - 16] + s0 + words[i - 7] + s1) & 0xffffffff)
        a,b,c,d,e,f,g,h = self.words
        for i in range(64):
            s1 = self._ror(e, 6) ^ self._ror(e, 11) ^ self._ror(e, 25)
            choose = (e & f) ^ ((~e) & g)
            t1 = (h + s1 + choose + self._K[i] + words[i]) & 0xffffffff
            s0 = self._ror(a, 2) ^ self._ror(a, 13) ^ self._ror(a, 22)
            majority = (a & b) ^ (a & c) ^ (b & c)
            t2 = (s0 + majority) & 0xffffffff
            h,g,f,e,d,c,b,a = g,f,e,(d + t1) & 0xffffffff,c,b,a,(t1 + t2) & 0xffffffff
        self.words = [(left + right) & 0xffffffff for left,right in
                      zip(self.words, (a,b,c,d,e,f,g,h))]
        self.full_blocks += 1

    def update(self, data: bytes) -> None:
        pending = self.partial + data
        whole = len(pending) // 64 * 64
        for offset in range(0, whole, 64):
            self._compress(pending[offset:offset + 64])
        self.partial = pending[whole:]

    @property
    def byte_count(self) -> int:
        return self.full_blocks * 64 + len(self.partial)

    def export(self) -> dict:
        return {"words": self.words, "full_blocks": self.full_blocks,
                "partial_b64": base64.b64encode(self.partial).decode()}

    @classmethod
    def restore(cls, record: dict, expected_offset: int):
        if not isinstance(record, dict) or set(record) != {"words","full_blocks","partial_b64"}:
            raise StateError("gc-checkpoint-invalid", "resumable SHA-256 checkpoint schema is invalid")
        try: partial = base64.b64decode(record["partial_b64"], validate=True)
        except Exception: raise StateError("gc-checkpoint-invalid", "resumable SHA-256 partial block is invalid")
        result = cls(record["words"], record["full_blocks"], partial)
        if result.byte_count != expected_offset:
            raise StateError("gc-checkpoint-invalid", "SHA-256 state does not match file offset")
        return result

    def hexdigest(self) -> str:
        clone = ResumableSHA256(self.words, self.full_blocks, self.partial)
        length_bits = clone.byte_count * 8
        clone.update(b"\x80" + b"\0" * ((55 - clone.byte_count) % 64) + length_bits.to_bytes(8, "big"))
        if clone.partial:
            raise AssertionError("SHA-256 final padding was not block aligned")
        return "".join(f"{word:08x}" for word in clone.words)


def instance(raw_id: str) -> tuple[str, str, str]:
    data = raw_bytes(raw_id)
    if not data or len(data) > MAX_ARG:
        raise StateError("invalid-agent-id", "agent id must contain 1..4096 bytes", 2)
    digest = sha(data)
    display = re.sub(r"[^A-Za-z0-9._-]", "_", raw_id)[:32] or "agent"
    return f"{display}.{digest}", display, digest


def canonical_role(role: str) -> str:
    try:
        return ROLES[role]
    except KeyError:
        raise StateError("invalid-role", "role is outside the canonical zyz-worker role set", 2)


def normalize_reason(reason: str) -> tuple[str, str]:
    value = reason.replace("\r", " ").replace("\n", " ").replace("\t", " ")
    try:
        data = value.encode("utf-8")
    except UnicodeEncodeError:
        raise StateError("invalid-reason", "reason must be valid UTF-8", 2)
    if len(data) > 1024:
        raise StateError("invalid-reason", "reason exceeds 1024 UTF-8 bytes", 2)
    return base64.b64encode(data).decode(), sha(data)


def nonce_hex(attempt: int = 0) -> str:
    sequence = os.environ.get("ZYZ_TEST_RANDOM_HEX_SEQUENCE", "").split(",")
    if attempt < len(sequence) and re.fullmatch(r"[0-9a-f]{32}", sequence[attempt]):
        return sequence[attempt]
    if os.environ.get("ZYZ_TEST_DISABLE_SECRETS") != "1":
        try:
            value = secrets.token_bytes(16)
            if len(value) == 16:
                return value.hex()
        except Exception:
            pass
    fd = None
    try:
        if os.environ.get("ZYZ_TEST_DISABLE_URANDOM") == "1":
            raise OSError(errno.ENOSYS, "injected /dev/urandom unavailability")
        fd = os.open(b"/dev/urandom", os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
        value = b""
        while len(value) < 16:
            part = os.read(fd, 16 - len(value))
            if not part:
                raise OSError(errno.EIO, "short /dev/urandom read")
            value += part
        return value.hex()
    except Exception:
        raise StateError("event-randomness-unavailable", "128-bit CSPRNG nonce is unavailable")
    finally:
        if fd is not None:
            os.close(fd)


def event_identity(kind: str, role: str, digest: str, nonce: str | None = None) -> dict:
    nonce = nonce_hex() if nonce is None else nonce
    if not re.fullmatch(r"[0-9a-f]{32}", nonce):
        raise StateError("event-randomness-unavailable", "event nonce must be 128-bit lowercase hex")
    role_b = role.encode(); digest_b = digest.encode(); nonce_b = nonce.encode()
    record = (bytes([1, 1 if kind == "start" else 2]) + len(role_b).to_bytes(2,"big") + role_b +
              len(digest_b).to_bytes(2,"big") + digest_b + len(nonce_b).to_bytes(2,"big") + nonce_b)
    return {"event_token": "evt1-" + sha(record), "nonce_sha256": sha(bytes.fromhex(nonce)),
            "event_record_digest": sha(record)}


def validate_event_identity_fields(location: str, record: dict) -> dict:
    """Validate the versioned identity fields shared by every retained location."""
    if location not in EVENT_INVENTORY_LIMITS:
        raise StateError("usage", "unknown retained event location", 2)
    if not isinstance(record, dict) or record.get("schema_version") != 1:
        raise StateError("event-inventory-invalid", "retained event schema version is invalid")
    required = ("event_token", "nonce_sha256", "event_record_digest")
    if not EVENT_RE.fullmatch(str(record.get("event_token", ""))):
        raise StateError("event-inventory-invalid", "retained event token is invalid")
    for field in required[1:]:
        if not HEX64.fullmatch(str(record.get(field, ""))):
            raise StateError("event-inventory-invalid", f"retained event {field} is invalid")
    encoded = json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
    if len(encoded) > 16384:
        raise StateError("event-inventory-invalid", "retained event record is oversized")
    return {field: record[field] for field in required}


def json_payload(data: dict) -> bytes:
    return (json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()


def json_digest(data: dict) -> str:
    return sha(json_payload(data))


# The retained event inventory has six bounded locations, all validated with
# the three identity fields above: start-unarmed, stop-uncommitted, journal,
# committed, resolved, and the bounded late-event audit ring.


def env_uint(name: str, default: int, minimum: int, maximum: int, zero: bool = False) -> int:
    value = os.environ.get(name)
    if value is not None and re.fullmatch(r"0|[1-9][0-9]*", value):
        number = int(value)
        if zero and number == 0:
            return 0
        if minimum <= number <= maximum:
            return number
    if value is not None:
        print(f"zyz-worker: invalid {name}={value!r}; using {default}", file=sys.stderr)
    return default


def atomic_json(path: Path, data: dict, limit: int = 16384, no_replace: bool = False) -> str:
    payload = (json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()
    if len(payload) > limit:
        raise StateError("state-too-large", f"{path.name} exceeds {limit} bytes", 1)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.parent / (".%s.tmp.%d.%s" % (path.name, os.getpid(), secrets.token_hex(8)))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    fd = os.open(os.fsencode(tmp), flags, 0o600)
    try:
        _write_all(fd,payload,"atomic JSON")
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        if no_replace:
            try:
                # link(2) is an atomic no-replace publication for the regular
                # temp files produced here.  Unlike exists()+replace(), a
                # concurrent winner can never be overwritten.
                os.link(os.fsencode(tmp), os.fsencode(path), follow_symlinks=False)
            except FileExistsError:
                raise StateError("state-conflict", f"{path.name} already exists")
            tmp.unlink()
        else:
            os.replace(os.fsencode(tmp), os.fsencode(path))
        dfd = os.open(os.fsencode(path.parent), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try: os.fsync(dfd)
        finally: os.close(dfd)
    finally:
        try: tmp.unlink()
        except FileNotFoundError: pass
    return sha(payload)


def _write_all(fd: int, payload: bytes, what: str) -> None:
    view=memoryview(payload)
    injected=os.environ.get("ZYZ_TEST_SHORT_WRITE") == what
    while view:
        amount=min(len(view),max(1,len(view)//2)) if injected else len(view)
        written=os.write(fd,view[:amount])
        if written <= 0:
            raise StateError("io",f"{what} write made no progress",6)
        view=view[written:]
        if injected:
            raise StateError("io",f"injected {what} short write",6)


def atomic_rename_noreplace(source: Path, target: Path) -> None:
    """Atomically rename without replacing, or fail closed if unsupported."""
    src_b, dst_b = os.fsencode(source), os.fsencode(target)
    barrier_root = os.environ.get("ZYZ_TEST_NOREPLACE_BARRIER_DIR")
    if barrier_root:
        barrier = Path(barrier_root)
        barrier.mkdir(mode=0o700, parents=True, exist_ok=True)
        ready = barrier / "ready"
        atomic_json(ready, {"schema_version": 1, "source": source.name,
                            "target": target.name, "pid": os.getpid()}, 4096)
        deadline = time.monotonic() + 5
        while not (barrier / "go").is_file():
            if time.monotonic() >= deadline:
                raise StateError("atomic-noreplace-barrier-timeout", "atomic no-replace barrier timed out")
            time.sleep(.005)
    libc = ctypes.CDLL(None, use_errno=True)
    result = -1
    if sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        func = libc.renameat2
        func.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        func.restype = ctypes.c_int
        result = func(-100, src_b, -100, dst_b, 1)  # RENAME_NOREPLACE
    elif sys.platform == "darwin" and hasattr(libc, "renameatx_np"):
        func = libc.renameatx_np
        func.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        func.restype = ctypes.c_int
        result = func(-2, src_b, -2, dst_b, 0x00000004)  # AT_FDCWD, RENAME_EXCL
    else:
        raise StateError("atomic-noreplace-unavailable", "kernel atomic no-replace rename is unavailable")
    if result != 0:
        observed = ctypes.get_errno()
        if observed == errno.EEXIST:
            raise StateError("state-conflict", f"{target.name} already exists")
        if observed in (errno.ENOSYS, errno.ENOTSUP, errno.EOPNOTSUPP, errno.EINVAL):
            raise StateError("atomic-noreplace-unavailable", "kernel atomic no-replace rename is unavailable")
        raise StateError("io", f"atomic no-replace rename failed: errno {observed}", 6)
    fsync_dir(target.parent)


def fsync_dir(path: Path) -> None:
    fd = os.open(os.fsencode(path), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _catalog_runtime(task: str) -> Path:
    task_b = raw_bytes(task)
    if not task_b or len(task_b) > MAX_ARG:
        raise StateError("invalid-request", "task-dir must contain 1..4096 bytes", 2)
    task_path = Path(task).absolute()
    try:
        task_stat = os.lstat(os.fsencode(task_path))
        runtime_stat = os.lstat(os.fsencode(task_path / "runtime"))
    except OSError:
        raise StateError("invalid-request", "task runtime does not exist", 2)
    if (not stat.S_ISDIR(task_stat.st_mode) or stat.S_ISLNK(task_stat.st_mode) or
            not stat.S_ISDIR(runtime_stat.st_mode) or stat.S_ISLNK(runtime_stat.st_mode) or
            runtime_stat.st_nlink < 1):
        raise StateError("invalid-request", "task/runtime binding is not a normal directory", 2)
    return task_path / "runtime"


def _catalog_mount_identity(path: Path) -> str:
    try:
        return runtime_native.mount_id_path(path)
    except Exception as exc:
        raise StateError("catalog-lock-capability-unavailable",
                         f"native mount identity is unavailable: {exc}", 4, True)


def _catalog_rename_capability() -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        return
    if sys.platform == "darwin" and hasattr(libc, "renameatx_np"):
        return
    raise StateError("genesis-capability-unavailable",
                     "kernel atomic no-replace rename is unavailable", 4, True)


def _catalog_container(runtime: Path, create: bool) -> Path:
    container = runtime / ".snapshot-gc-owned.v1"
    try:
        observed = os.lstat(os.fsencode(container))
    except FileNotFoundError:
        if not create:
            raise
        os.mkdir(os.fsencode(container), 0o700)
        fsync_dir(runtime)
        observed = os.lstat(os.fsencode(container))
    if (not stat.S_ISDIR(observed.st_mode) or stat.S_ISLNK(observed.st_mode) or
            observed.st_nlink < 1 or stat.S_IMODE(observed.st_mode) != 0o700):
        raise StateError("catalog-root-invalid", "catalog container identity/mode is invalid", 4)
    runtime_mount = _catalog_mount_identity(runtime)
    container_mount = _catalog_mount_identity(container)
    if runtime_mount != container_mount:
        raise StateError("catalog-root-invalid", "catalog container crosses a mount boundary", 4)
    return container


def _catalog_preallocate(fd: int, size: int, what: str) -> os.stat_result:
    if size < 1:
        raise StateError("gc-internal", "global-layout-overflow", 5)
    os.ftruncate(fd, size)
    try:
        if hasattr(os, "posix_fallocate"):
            os.posix_fallocate(fd, 0, size)
        elif sys.platform == "darwin":
            # fstore_t: flags, posmode, offset, length, bytesalloc.
            request = struct.pack("@IIqqq", 0x00000004, 0, 0, size, 0)
            try:
                fcntl.fcntl(fd, 42, request)  # F_PREALLOCATE/F_ALLOCATEALL
            except OSError as exc:
                raise StateError("genesis-capacity-unavailable",
                                 f"native preallocation failed for {what}: {exc}", 4, True)
        else:
            raise StateError("genesis-capacity-unavailable",
                             f"native preallocation is unavailable for {what}", 4, True)
    except StateError:
        raise
    except OSError as exc:
        raise StateError("genesis-capacity-unavailable",
                         f"native preallocation failed for {what}: {exc}", 4, True)
    observed = os.fstat(fd)
    if (not stat.S_ISREG(observed.st_mode) or observed.st_nlink < 1 or
            observed.st_size != size or observed.st_blocks * 512 < size):
        raise StateError("genesis-capacity-unavailable",
                         f"physical allocation is incomplete for {what}", 4, True)
    return observed


def _catalog_open_fixed(container_fd: int, name: str, mode: int = 0o600) -> int:
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(os.fsencode(name), flags, mode, dir_fd=container_fd)
    observed = os.fstat(fd)
    if not stat.S_ISREG(observed.st_mode) or observed.st_nlink != 1:
        os.close(fd)
        raise StateError("catalog-root-invalid", f"fixed object {name} is not a normal file", 4)
    return fd


def _catalog_object_identity(container: Path, name: str, expected_size: int) -> dict:
    path = container / name
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(os.fsencode(path), flags)
    try:
        observed = os.fstat(fd)
        mount = _catalog_mount_identity(path)
    finally:
        os.close(fd)
    if (not stat.S_ISREG(observed.st_mode) or observed.st_nlink != 1 or
            observed.st_size != expected_size or observed.st_blocks * 512 < expected_size):
        raise StateError("catalog-root-invalid", f"fixed object {name} allocation is invalid", 4)
    value = {"dev": observed.st_dev, "ino": observed.st_ino, "size": observed.st_size,
             "mount_id": mount}
    value["digest"] = hashlib.sha256(_catalog_json(value)).hexdigest()
    return value


class CatalogFlock:
    def __init__(self, container: Path, name: str = ".catalog-lock.v1",
                 missing_is_absent: bool = False):
        self.container, self.name, self.fd = container, name, -1
        self.missing_is_absent = missing_is_absent

    def __enter__(self):
        flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
        opening = True
        try:
            self.fd = os.open(os.fsencode(self.container / self.name), flags)
            opening = False
            before = os.fstat(self.fd)
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size < 1:
                raise StateError("catalog-lock-capability-unavailable",
                                 "catalog lock carrier is invalid", 4, True)
            deadline = time.monotonic() + env_uint("ZYZ_AGENT_LOCK_ACQUIRE_SEC", 2, 1, 30)
            while True:
                try:
                    fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise StateError("catalog-lock-timeout", "catalog lock is busy", 3, True)
                    time.sleep(.025)
                except (AttributeError, OSError) as exc:
                    raise StateError("catalog-lock-capability-unavailable",
                                     f"persistent advisory lock is unavailable: {exc}", 4, True)
            after = os.fstat(self.fd)
            by_name = os.stat(os.fsencode(self.container / self.name), follow_symlinks=False)
            if ((before.st_dev, before.st_ino, before.st_nlink, before.st_size) !=
                    (after.st_dev, after.st_ino, after.st_nlink, after.st_size) or
                    (after.st_dev, after.st_ino) != (by_name.st_dev, by_name.st_ino)):
                raise StateError("catalog-lock-capability-unavailable",
                                 "catalog lock carrier binding changed", 4, True)
            return self
        except FileNotFoundError as exc:
            if opening and self.missing_is_absent:
                raise
            if self.fd >= 0:
                os.close(self.fd); self.fd = -1
            raise StateError("catalog-lock-capability-unavailable",
                             f"catalog lock carrier is unavailable: {exc}", 4, True)
        except (AttributeError, OSError) as exc:
            if self.fd >= 0:
                os.close(self.fd); self.fd = -1
            raise StateError("catalog-lock-capability-unavailable",
                             f"catalog lock carrier is unavailable: {exc}", 4, True)
        except Exception:
            if self.fd >= 0:
                os.close(self.fd); self.fd = -1
            raise

    def __exit__(self, exc_type, exc, tb):
        if self.fd >= 0:
            try: fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally: os.close(self.fd); self.fd = -1


class InstanceFlock(CatalogFlock):
    def __init__(self, container: Path, instance_key: str,
                 missing_is_absent: bool = False):
        if not KEY_RE.fullmatch(instance_key):
            raise StateError("identity-conflict", "instance key is invalid", 3)
        super().__init__(container, f"{instance_key}.lock.v1", missing_is_absent)


class TerminalFlock(CatalogFlock):
    def __init__(self, container: Path):
        super().__init__(container, ".terminal-index-lock.v1")


def _terminal_cell_semantic(value: dict) -> None:
    if (value.get("schema_version") != 1 or
            not isinstance(value.get("cell_index"), int) or
            not 0 <= value["cell_index"] < TERMINAL_CELL_COUNT or
            value.get("state") not in ("empty", "reserved", "handoff-accepted", "tombstone")):
        raise StateError("catalog-root-invalid", "terminal cell schema is invalid", 4)
    if value["state"] == "empty" and set(value) != {
            "schema_version", "cell_index", "state"}:
        raise StateError("catalog-root-invalid", "terminal empty cell is invalid", 4)
    if value["state"] == "tombstone":
        required = {"schema_version", "cell_index", "state",
                    "evicted_cell_generation", "evicted_epoch"}
        if (set(value) != required or
                not isinstance(value.get("evicted_cell_generation"), int) or
                value["evicted_cell_generation"] < 1 or
                not isinstance(value.get("evicted_epoch"), int) or
                value["evicted_epoch"] < 0):
            raise StateError("catalog-root-invalid",
                             "terminal tombstone cell is invalid", 4)
    if value["state"] == "reserved":
        required = {"schema_version", "cell_index", "state", "instance_key",
                    "agent_id_sha256", "canonical_role", "reservation_nonce",
                    "prior_cell_generation", "lease_epoch",
                    "catalog_reservation_digest", "request_bytes"}
        if (set(value) != required or not KEY_RE.fullmatch(str(value.get("instance_key"))) or
                not HEX64.fullmatch(str(value.get("agent_id_sha256"))) or
                value.get("canonical_role") not in set(ROLES.values()) or
                not re.fullmatch(r"[0-9a-f]{32}", str(value.get("reservation_nonce"))) or
                not isinstance(value.get("prior_cell_generation"), int) or
                value["prior_cell_generation"] < 1 or
                not isinstance(value.get("lease_epoch"), int) or value["lease_epoch"] < 0 or
                not HEX64.fullmatch(str(value.get("catalog_reservation_digest"))) or
                not isinstance(value.get("request_bytes"), int) or value["request_bytes"] < 1):
            raise StateError("catalog-root-invalid", "terminal reservation is invalid", 4)
    if value["state"] == "handoff-accepted":
        required = {"schema_version", "cell_index", "state", "instance_key",
                    "agent_id_sha256", "canonical_role", "reservation_nonce",
                    "prior_cell_generation", "lease_epoch",
                    "catalog_reservation_digest", "request_bytes",
                    "handoff_latch", "handoff_latch_digest", "terminal_record",
                    "terminal_record_digest", "frozen_headers", "instance_objects",
                    "instance_release", "gc_anchor", "late_clean",
                    "publication_staging", "event_receipts",
                    "created_epoch", "last_event_epoch", "retention_epoch"}
        release = value.get("instance_release")
        late = value.get("late_clean")
        event_receipts = value.get("event_receipts")
        if (set(value) != required or not KEY_RE.fullmatch(str(value.get("instance_key"))) or
                not HEX64.fullmatch(str(value.get("agent_id_sha256"))) or
                value.get("canonical_role") not in set(ROLES.values()) or
                not re.fullmatch(r"[0-9a-f]{32}", str(value.get("reservation_nonce"))) or
                not HEX64.fullmatch(str(value.get("catalog_reservation_digest"))) or
                not isinstance(value.get("handoff_latch"), dict) or
                value.get("handoff_latch_digest") != json_digest(value["handoff_latch"]) or
                not isinstance(value.get("terminal_record"), dict) or
                value.get("terminal_record_digest") != json_digest(value["terminal_record"]) or
                not isinstance(value.get("frozen_headers"), dict) or
                not isinstance(value.get("instance_objects"), dict) or
                (value.get("publication_staging") is not None and
                 not isinstance(value.get("publication_staging"),dict)) or
                not isinstance(event_receipts, dict) or
                set(event_receipts) != {
                    "schema_version", "resolved_start_ring_digest",
                    "resolved_stop_ring_digest", "latest_start_event_token",
                    "latest_stop_event_token"} or
                event_receipts.get("schema_version") != 1 or
                any(event_receipts.get(name) is not None and
                    not HEX64.fullmatch(str(event_receipts[name]))
                    for name in ("resolved_start_ring_digest",
                                 "resolved_stop_ring_digest")) or
                any(event_receipts.get(name) is not None and
                    not EVENT_RE.fullmatch(str(event_receipts[name]))
                    for name in ("latest_start_event_token",
                                 "latest_stop_event_token")) or
                not isinstance(value.get("created_epoch"), int) or
                not isinstance(value.get("last_event_epoch"), int) or
                not isinstance(value.get("retention_epoch"), int) or
                value["created_epoch"] < 0 or
                value["last_event_epoch"] < value["created_epoch"] or
                value["retention_epoch"] < value["last_event_epoch"] or
                not isinstance(release, dict) or release.get("phase") not in
                    ("prepared", "will-register-release", "did-register-release",
                     "waiting-catalog-delete", "did-catalog-delete", "committed") or
                value.get("gc_anchor") is not None and
                    not isinstance(value.get("gc_anchor"), dict) or
                late is not None and not isinstance(late, dict)):
            raise StateError("catalog-root-invalid", "terminal accepted cell is invalid", 4)
        if late is not None:
            done = late.get("done_record")
            late_required = {"schema_version", "phase", "done_record",
                             "done_record_digest"}
            done_required = {
                "schema_version", "instance_key", "agent_id_sha256",
                "display_prefix", "canonical_role", "terminal_kind",
                "terminal_epoch", "event_token", "nonce_sha256",
                "event_record_digest",
            }
            if (set(late) != late_required or late.get("schema_version") != 1 or
                    late.get("phase") not in
                        ("prepared", "will-done", "did-done", "committed") or
                    not isinstance(done, dict) or set(done) != done_required or
                    done.get("schema_version") != 1 or
                    done.get("instance_key") != value["instance_key"] or
                    done.get("agent_id_sha256") != value["agent_id_sha256"] or
                    done.get("canonical_role") != value["canonical_role"] or
                    done.get("terminal_kind") != "done" or
                    not isinstance(done.get("terminal_epoch"), int) or
                    done["terminal_epoch"] < value["created_epoch"] or
                    not EVENT_RE.fullmatch(str(done.get("event_token"))) or
                    not HEX64.fullmatch(str(done.get("nonce_sha256"))) or
                    not HEX64.fullmatch(str(done.get("event_record_digest"))) or
                    late.get("done_record_digest") != json_digest(done)):
                raise StateError("catalog-root-invalid",
                                 "terminal late-clean journal is invalid", 4)
        anchor = value.get("gc_anchor")
        if anchor is not None:
            anchor_required = {
                "schema_version", "phase", "count", "accumulator_sha256",
                "latest_claim_digest", "latest_receipt_digest",
            }
            if (set(anchor) != anchor_required or
                    anchor.get("schema_version") != 1 or
                    anchor.get("phase") not in
                        ("waiting-claim-retire", "retired") or
                    not isinstance(anchor.get("count"), int) or
                    anchor["count"] < 1 or
                    not HEX64.fullmatch(str(anchor.get("accumulator_sha256"))) or
                    not HEX64.fullmatch(str(anchor.get("latest_claim_digest"))) or
                    not HEX64.fullmatch(str(anchor.get("latest_receipt_digest")))):
                raise StateError("catalog-root-invalid",
                                 "terminal GC anchor is invalid", 4)


def _terminal_cell_image(index: int, generation: int, predecessor: bytes,
                         metadata: dict) -> bytes:
    if metadata.get("cell_index") != index:
        raise StateError("catalog-root-invalid", "terminal cell index conflicts", 4)
    return _catalog_image(b"ZYZTCEL1", TERMINAL_IMAGE_SIZE, generation,
                          predecessor, metadata, (), TERMINAL_IMAGE_SIZE - 128)


def _terminal_selected_cell(fd: int, index: int) -> tuple:
    if not 0 <= index < TERMINAL_CELL_COUNT:
        raise StateError("catalog-root-invalid", "terminal cell index is invalid", 4)
    selected = _catalog_select_ab(
        fd, index * TERMINAL_CELL_SIZE, TERMINAL_IMAGE_SIZE,
        b"ZYZTCEL1", _terminal_cell_semantic, TERMINAL_IMAGE_SIZE - 128)
    if selected[3][2].get("cell_index") != index:
        raise StateError("catalog-root-invalid", "terminal cell selection conflicts", 4)
    return selected


def _terminal_write_cell(fd: int, selected: tuple, index: int,
                         metadata: dict, barrier: str) -> tuple:
    generation = selected[0] + 1
    if generation > 2147483647:
        raise StateError("catalog-root-invalid", "terminal cell generation overflows", 4)
    image = _terminal_cell_image(index, generation, selected[3][3], metadata)
    bank = 1 - selected[1]
    _catalog_pwrite_all(fd, image,
                        index * TERMINAL_CELL_SIZE + bank * TERMINAL_IMAGE_SIZE,
                        "terminal cell successor")
    _data_sync(fd)
    _catalog_barrier("terminal-index", barrier)
    return generation, bank, image, _catalog_parse_image(
        image, b"ZYZTCEL1", _terminal_cell_semantic, TERMINAL_IMAGE_SIZE - 128)


def _terminal_probe_start(instance_key: str) -> int:
    return int.from_bytes(hashlib.sha256(instance_key.encode("ascii")).digest()[:8],
                          "big") % TERMINAL_CELL_COUNT


def _terminal_find_cell(fd: int, instance_key: str) -> tuple[int | None, tuple | None, int | None]:
    start = _terminal_probe_start(instance_key)
    reusable = None
    for step in range(TERMINAL_CELL_COUNT):
        index = (start + step) % TERMINAL_CELL_COUNT
        selected = _terminal_selected_cell(fd, index)
        metadata = selected[3][2]
        if metadata.get("instance_key") == instance_key:
            return index, selected, reusable
        if metadata["state"] == "tombstone" and reusable is None:
            reusable = index
        if metadata["state"] == "empty":
            return None, None, reusable if reusable is not None else index
    return None, None, reusable


def _terminal_cell_ownership_complete(metadata: dict) -> bool:
    if metadata.get("state") != "handoff-accepted":
        return False
    release = metadata.get("instance_release")
    late = metadata.get("late_clean")
    anchor = metadata.get("gc_anchor")
    return bool(
        isinstance(release, dict) and release.get("phase") == "committed" and
        (late is None or
         isinstance(late, dict) and late.get("phase") == "committed") and
        (anchor is None or
         isinstance(anchor, dict) and anchor.get("phase") == "retired"))


def _terminal_evict_oldest_eligible_fd(fd: int, now: int) -> int | None:
    """Evict exactly one deterministic, unpinned terminal cell to tombstone."""
    accepted = []
    for index in range(TERMINAL_CELL_COUNT):
        selected = _terminal_selected_cell(fd, index)
        metadata = selected[3][2]
        if metadata["state"] == "handoff-accepted":
            terminal_epoch = metadata["terminal_record"].get("terminal_epoch")
            if not isinstance(terminal_epoch, int) or terminal_epoch < 0:
                raise StateError("catalog-root-invalid",
                                 "terminal record epoch is invalid", 4)
            accepted.append((terminal_epoch, index, selected, metadata))
    recent = {
        index for _, index, _, _ in
        sorted(accepted, key=lambda item: (-item[0], item[1]))[:64]
    }
    eligible = []
    for terminal_epoch, index, selected, metadata in accepted:
        if index in recent or not _terminal_cell_ownership_complete(metadata):
            continue
        retention_epoch = metadata.get("retention_epoch")
        last_event_epoch = metadata.get("last_event_epoch")
        if (not isinstance(retention_epoch, int) or
                not isinstance(last_event_epoch, int) or
                retention_epoch < last_event_epoch):
            raise StateError("catalog-root-invalid",
                             "terminal retention coordinates are invalid", 4)
        if now < retention_epoch:
            continue
        eligible.append((terminal_epoch, last_event_epoch, index, selected))
    if not eligible:
        return None
    _, _, index, selected = min(eligible, key=lambda item: item[:3])
    tombstone = {
        "schema_version": 1, "cell_index": index, "state": "tombstone",
        "evicted_cell_generation": selected[0], "evicted_epoch": now,
    }
    _terminal_write_cell(fd, selected, index, tombstone,
                         "cell-evicted-to-tombstone")
    return index


def _terminal_prepare_admission(container: Path, now: int) -> None:
    """Ensure one terminal slot exists before a fresh instance admission."""
    with TerminalFlock(container):
        fd = _terminal_open_pack(container, True)
        try:
            for index in range(TERMINAL_CELL_COUNT):
                if _terminal_selected_cell(fd, index)[3][2]["state"] in (
                        "empty", "tombstone"):
                    return
            if _terminal_evict_oldest_eligible_fd(fd, now) is None:
                raise StateError(
                    "terminal-audit-capacity-blocked",
                    "terminal audit index has no reusable cell", 4, True)
        finally:
            os.close(fd)


def _terminal_open_pack(container: Path, write: bool = False) -> int:
    flags = (os.O_RDWR if write else os.O_RDONLY) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(os.fsencode(container / ".terminal-audit-pack.v1"), flags)
    if os.fstat(fd).st_size != CATALOG_TERMINAL_SIZE:
        os.close(fd)
        raise StateError("catalog-root-invalid", "terminal pack size is invalid", 4)
    return fd


def _terminal_lookup(container: Path, instance_key: str) -> dict | None:
    with TerminalFlock(container):
        fd = _terminal_open_pack(container, False)
        try:
            _, selected, _ = _terminal_find_cell(fd, instance_key)
            return None if selected is None else selected[3][2]
        finally:
            os.close(fd)


def _terminal_lookup_read_snapshot(container: Path,
                                   instance_key: str) -> dict | None:
    """Read one exact terminal cell without acquiring TerminalFlock.

    Used only while the catalog/GC lock is held.  Every A/B cell is
    self-validating; scanning the complete fixed table avoids relying on an
    unlocked open-addressing stop point during a concurrent terminal write.
    """
    fd=_terminal_open_pack(container,False)
    try:
        matches=[]
        for index in range(TERMINAL_CELL_COUNT):
            selected=_terminal_selected_cell(fd,index)
            value=selected[3][2]
            if value.get("instance_key") == instance_key:
                matches.append(value)
        if len(matches) > 1:
            raise StateError("catalog-root-invalid",
                             "terminal instance is duplicated",4)
        return matches[0] if matches else None
    finally:
        os.close(fd)


def _catalog_instance_reservation_snapshot(container: Path, instance_key: str,
                                           request_bytes: int) -> dict:
    """Read the active catalog owner before terminal R/F/P without nesting locks."""
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_fd = proof.pop("global_fd")
        recovery_fd = -1
        try:
            duplicate, _ = _catalog_find_instance_cell(global_fd, proof, instance_key)
            if duplicate is None:
                raise StateError("catalog-root-invalid",
                                 "terminal instance catalog owner is absent", 4)
            selector = proof["root"][2][4096:5120]
            _, _, entry = _catalog_selected_entry(global_fd, selector, duplicate)
            recovery_fd = os.open(
                os.fsencode(container / ".catalog-recovery-pack.v1"),
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            _, _, recovery = _catalog_selected_recovery(
                recovery_fd, entry, duplicate)
            payload = recovery["payload"]
            if (entry["state"] not in (2, 3) or
                    recovery["state"] not in (3, 4, 5, 6) or
                    payload.get("subject_digest") !=
                        _catalog_instance_subject(instance_key).hex() or
                    not HEX64.fullmatch(str(payload.get("reservation_digest"))) or
                    not HEX64.fullmatch(str(payload.get("object_identities_digest")))):
                raise StateError("catalog-root-invalid",
                                 "terminal instance catalog owner is not active", 4)
            return {"recovery_cell_index": duplicate,
                    "catalog_reservation_digest": payload["reservation_digest"],
                    "catalog_object_identities_digest":
                        payload["object_identities_digest"],
                    "request_bytes": request_bytes}
        finally:
            if recovery_fd >= 0:
                os.close(recovery_fd)
            os.close(global_fd)


def _terminal_reserve(container: Path, instance_key: str, identity: dict,
                      catalog_owner: dict, now: int) -> dict:
    """R: reserve one bounded terminal cell; reservation is not terminal truth."""
    with TerminalFlock(container):
        fd = _terminal_open_pack(container, True)
        try:
            index, selected, reusable = _terminal_find_cell(fd, instance_key)
            if index is not None:
                metadata = selected[3][2]
                if metadata["state"] not in ("reserved", "handoff-accepted"):
                    raise StateError("catalog-root-invalid",
                                     "terminal instance cell state conflicts", 4)
                expected = (identity.get("agent_id_sha256"),
                            identity.get("canonical_role"),
                            catalog_owner["catalog_reservation_digest"],
                            catalog_owner["request_bytes"])
                observed = (metadata.get("agent_id_sha256"),
                            metadata.get("canonical_role"),
                            metadata.get("catalog_reservation_digest"),
                            metadata.get("request_bytes"))
                if observed != expected:
                    raise StateError("catalog-root-invalid",
                                     "terminal reservation identity conflicts", 4)
                return metadata
            if reusable is None:
                reusable = _terminal_evict_oldest_eligible_fd(
                    fd, int(time.time()))
            if reusable is None:
                raise StateError("terminal-audit-capacity-blocked",
                                 "terminal audit index has no reusable cell", 4, True)
            selected = _terminal_selected_cell(fd, reusable)
            if selected[3][2]["state"] not in ("empty", "tombstone"):
                raise StateError("catalog-root-invalid",
                                 "terminal reusable cell changed", 4)
            reservation = {
                "schema_version": 1, "cell_index": reusable, "state": "reserved",
                "instance_key": instance_key,
                "agent_id_sha256": identity["agent_id_sha256"],
                "canonical_role": identity["canonical_role"],
                "reservation_nonce": nonce_hex(),
                "prior_cell_generation": selected[0], "lease_epoch": now,
                "catalog_reservation_digest":
                    catalog_owner["catalog_reservation_digest"],
                "request_bytes": catalog_owner["request_bytes"],
            }
            _terminal_write_cell(fd, selected, reusable, reservation,
                                 "reservation-committed")
            return reservation
        finally:
            os.close(fd)


def _terminal_instance_objects(container: Path, instance_key: str) -> dict:
    result = {}
    for logical, name, size in (
            ("audit", f"{instance_key}.audit-pack.v1", INSTANCE_AUDIT_SIZE),
            ("work", f"{instance_key}.work-pack.v1", INSTANCE_WORK_SIZE),
            ("lock", f"{instance_key}.lock.v1",
             os.lstat(os.fsencode(container / f"{instance_key}.lock.v1")).st_size)):
        value = _catalog_object_identity(container, name, size)
        result[logical] = {"basename": name, **value}
    return result


def _terminal_freeze(container: Path, instance_key: str,
                     reservation: dict) -> dict:
    """F: freeze terminal truth and the exact instance-object set in work pack."""
    with InstanceFlock(container, instance_key):
        audit_fd = _instance_open_pack(container, instance_key, "audit", True)
        work_fd = _instance_open_pack(container, instance_key, "work", True)
        try:
            identity = _instance_pack_read_fd(
                audit_fd, "audit", instance_key, "IDENTITY")
            done = _instance_pack_read_fd(
                audit_fd, "audit", instance_key, "DONE")
            finalized = _instance_pack_read_fd(
                audit_fd, "audit", instance_key, "FINALIZED")
            marker = done if done is not None else finalized
            frozen_late_clean = None
            if done is not None and finalized is not None:
                if (done.get("terminal_kind") != "done" or
                        done.get("preserved_terminal_kind") != "finalized" or
                        done.get("late_clean") is not True):
                    raise StateError("catalog-root-invalid",
                                     "late clean DONE does not preserve FINALIZED", 4)
                marker = finalized
                late_done = {name: done.get(name) for name in (
                    "schema_version", "instance_key", "agent_id_sha256",
                    "display_prefix", "canonical_role", "terminal_kind",
                    "terminal_epoch", "event_token", "nonce_sha256",
                    "event_record_digest")}
                frozen_late_clean = {
                    "schema_version": 1, "phase": "committed",
                    "done_record": late_done,
                    "done_record_digest": json_digest(late_done),
                }
            publication_staging = _instance_pack_read_fd(
                work_fd,"work",instance_key,"TERMINAL_STAGING")
            diagnostics = _fixed_diagnostics_fd(audit_fd, instance_key)
            if any(item["needs_reconcile"] for item in diagnostics):
                raise StateError("transition-incomplete",
                                 "unresolved event diagnostic pins instance packs", 4,
                                 True)
            resolved_start_payload = _instance_pack_read_fd(
                audit_fd, "audit", instance_key, "RESOLVED_START")
            resolved_stop_payload = _instance_pack_read_fd(
                audit_fd, "audit", instance_key, "RESOLVED_STOP")
            resolved_start = _fixed_resolved_fd(
                audit_fd, instance_key, "start")
            resolved_stop = _fixed_resolved_fd(
                audit_fd, instance_key, "stop")
            event_receipts = {
                "schema_version": 1,
                "resolved_start_ring_digest": (
                    json_digest(resolved_start_payload)
                    if resolved_start_payload is not None else None),
                "resolved_stop_ring_digest": (
                    json_digest(resolved_stop_payload)
                    if resolved_stop_payload is not None else None),
                "latest_start_event_token": (
                    resolved_start[-1]["event_token"] if resolved_start else None),
                "latest_stop_event_token": (
                    resolved_stop[-1]["event_token"] if resolved_stop else None),
            }
            if (not isinstance(identity, dict) or not isinstance(marker, dict) or
                    identity.get("agent_id_sha256") !=
                        reservation["agent_id_sha256"] or
                    identity.get("canonical_role") !=
                        reservation["canonical_role"] or
                    marker.get("instance_key") != instance_key):
                raise StateError("catalog-root-invalid",
                                 "terminal freeze source is invalid", 4)
            existing = _instance_pack_read_fd(
                work_fd, "work", instance_key, "TERMINAL_HANDOFF")
            if existing is not None:
                if (existing.get("state") != "freeze-latch-committed" or
                        existing.get("reservation_nonce") !=
                            reservation["reservation_nonce"] or
                        existing.get("terminal_record_digest") !=
                            json_digest(marker)):
                    raise StateError("catalog-root-invalid",
                                     "terminal freeze latch conflicts", 4)
                work_header = _instance_pack_header(
                    work_fd, "work", instance_key)
                return {"identity": identity, "terminal_record": marker,
                        "latch": existing,
                        "latch_digest": json_digest(existing),
                        "publication_staging":
                            existing.get("publication_staging"),
                        "event_receipts": existing.get("event_receipts"),
                        "late_clean": existing.get("late_clean"),
                        "frozen_headers": existing["frozen_headers"],
                        "instance_objects": existing["instance_objects"],
                        "work_header_generation": work_header[0],
                        "work_header_digest": work_header[3][3].hex()}
            audit_header = _instance_pack_header(audit_fd, "audit", instance_key)
            work_prior = _instance_pack_header(work_fd, "work", instance_key)
            objects = _terminal_instance_objects(container, instance_key)
            frozen = {
                "audit": {"generation": audit_header[0],
                          "digest": audit_header[3][3].hex()},
                "work_prior": {"generation": work_prior[0],
                               "digest": work_prior[3][3].hex()},
                "work_expected_generation": work_prior[0] + 1,
            }
            latch = {
                "schema_version": 1, "state": "freeze-latch-committed",
                "instance_key": instance_key,
                "reservation_nonce": reservation["reservation_nonce"],
                "terminal_record_digest": json_digest(marker),
                "catalog_reservation_digest":
                    reservation["catalog_reservation_digest"],
                "frozen_headers": frozen, "instance_objects": objects,
                "publication_staging":publication_staging,
                "event_receipts": event_receipts,
                "late_clean": frozen_late_clean,
            }
            _instance_pack_write_fd(
                work_fd, "work", instance_key, "TERMINAL_HANDOFF", latch)
            work_after = _instance_pack_header(work_fd, "work", instance_key)
            if (work_after[0] != frozen["work_expected_generation"] or
                    work_after[3][1].hex() != frozen["work_prior"]["digest"]):
                raise StateError("catalog-root-invalid",
                                 "terminal freeze header successor conflicts", 4)
            _catalog_barrier("terminal-handoff", "freeze-latch-committed")
            return {"identity": identity, "terminal_record": marker,
                    "latch": latch, "latch_digest": json_digest(latch),
                    "publication_staging":publication_staging,
                    "event_receipts":event_receipts,
                    "late_clean":frozen_late_clean,
                    "frozen_headers": frozen, "instance_objects": objects,
                    "work_header_generation": work_after[0],
                    "work_header_digest": work_after[3][3].hex()}
        finally:
            os.close(audit_fd)
            os.close(work_fd)


def _terminal_publish(container: Path, reservation: dict,
                      frozen: dict) -> dict:
    """P: make the frozen image terminal authority under only terminal lock."""
    instance_key = reservation["instance_key"]
    with TerminalFlock(container):
        fd = _terminal_open_pack(container, True)
        try:
            index, selected, _ = _terminal_find_cell(fd, instance_key)
            if index is None or selected is None:
                raise StateError("catalog-root-invalid",
                                 "terminal reservation disappeared", 4)
            current = selected[3][2]
            if current["state"] == "handoff-accepted":
                if (current.get("reservation_nonce") !=
                        reservation["reservation_nonce"] or
                        current.get("handoff_latch_digest") !=
                        frozen["latch_digest"]):
                    raise StateError("catalog-root-invalid",
                                     "terminal accepted image conflicts", 4)
                return current
            if (current != reservation or
                    frozen["latch"].get("reservation_nonce") !=
                        reservation["reservation_nonce"] or
                    frozen["latch"].get("terminal_record_digest") !=
                        json_digest(frozen["terminal_record"])):
                raise StateError("catalog-root-invalid",
                                 "terminal reservation/latch binding conflicts", 4)
            accepted = {
                **reservation, "state": "handoff-accepted",
                "handoff_latch": frozen["latch"],
                "handoff_latch_digest": frozen["latch_digest"],
                "terminal_record": frozen["terminal_record"],
                "terminal_record_digest": json_digest(frozen["terminal_record"]),
                "frozen_headers": {
                    **frozen["frozen_headers"],
                    "work": {"generation": frozen["work_header_generation"],
                             "digest": frozen["work_header_digest"]}},
                "instance_objects": frozen["instance_objects"],
                "instance_release": {"phase": "prepared",
                                     "free_receipt_record_digest": None},
                "gc_anchor": None, "late_clean":frozen.get("late_clean"),
                "publication_staging":frozen.get("publication_staging"),
                "event_receipts":frozen.get("event_receipts"),
                "created_epoch": frozen["terminal_record"]["terminal_epoch"],
                "last_event_epoch": max(
                    frozen["terminal_record"]["terminal_epoch"],
                    (frozen.get("late_clean") or {}).get(
                        "done_record", {}).get("terminal_epoch", 0)),
                "retention_epoch": (
                    frozen["terminal_record"]["terminal_epoch"] + 86400
                    if frozen["terminal_record"].get("terminal_kind") == "done"
                    else max(
                        frozen["terminal_record"]["terminal_epoch"] + 7 * 86400,
                        max(frozen["terminal_record"]["terminal_epoch"],
                            (frozen.get("late_clean") or {}).get(
                                "done_record", {}).get("terminal_epoch", 0)) +
                        env_uint("ZYZ_RUNNING_NO_ACK_GRACE_SEC", 1200, 60, 86400))),
            }
            _terminal_write_cell(fd, selected, index, accepted,
                                 "handoff-accepted")
            return accepted
        finally:
            os.close(fd)


def _terminal_handoff_instance(container: Path, instance_key: str,
                               request_bytes: int) -> dict:
    catalog_owner = _catalog_instance_reservation_snapshot(
        container, instance_key, request_bytes)
    with InstanceFlock(container, instance_key):
        audit_fd = _instance_open_pack(container, instance_key, "audit", False)
        try:
            identity = _instance_pack_read_fd(
                audit_fd, "audit", instance_key, "IDENTITY")
        finally:
            os.close(audit_fd)
    if not isinstance(identity, dict):
        raise StateError("catalog-root-invalid", "terminal identity is absent", 4)
    reservation = _terminal_reserve(
        container, instance_key, identity, catalog_owner, int(time.time()))
    if reservation["state"] == "handoff-accepted":
        return reservation
    frozen = _terminal_freeze(container, instance_key, reservation)
    return _terminal_publish(container, reservation, frozen)


def _terminal_update_accepted(container: Path, instance_key: str,
                              transform, barrier: str) -> dict:
    with TerminalFlock(container):
        fd = _terminal_open_pack(container, True)
        try:
            index, selected, _ = _terminal_find_cell(fd, instance_key)
            if index is None or selected is None or \
                    selected[3][2].get("state") != "handoff-accepted":
                raise StateError("catalog-root-invalid",
                                 "terminal accepted cell is absent", 4)
            current = selected[3][2]
            successor = transform(current)
            if successor == current:
                return current
            _terminal_write_cell(fd, selected, index, successor, barrier)
            return successor
        finally:
            os.close(fd)


def _terminal_release_instance_objects(container: Path, instance_key: str,
                                       config: dict,
                                       progress: dict | None = None) -> dict:
    """Receipt-gated external INSTANCE_RELEASE owned entirely by terminal cell."""
    if progress is None:
        progress = {"entries_deleted": 0, "bytes_reclaimed": 0}
    def phase(value: dict, name: str, **extra) -> dict:
        release = dict(value["instance_release"], phase=name, **extra)
        return {**value, "instance_release": release}

    current = _terminal_update_accepted(
        container, instance_key,
        lambda value: (value if value["instance_release"]["phase"] != "prepared"
                       else phase(value, "will-register-release")),
        "instance-release-will-register")
    release_state = current["instance_release"]["phase"]
    if release_state == "will-register-release":
        released = _catalog_complete_instance_release(
            container, instance_key, current["request_bytes"], config)
        if not released.get("idempotent", False):
            progress["bytes_reclaimed"] = (
                progress.get("bytes_reclaimed", 0) + current["request_bytes"])
        current = _terminal_update_accepted(
            container, instance_key,
            lambda value: phase(
                value, "did-register-release",
                free_receipt_record_digest=
                    released["free_receipt_record_digest"]),
            "instance-release-did-register")
        release_state = current["instance_release"]["phase"]
    if release_state == "did-register-release":
        current = _terminal_update_accepted(
            container, instance_key,
            lambda value: phase(value, "waiting-catalog-delete"),
            "instance-release-waiting-delete")
        release_state = current["instance_release"]["phase"]
    if release_state == "waiting-catalog-delete":
        objects = current["instance_objects"]
        for logical in ("audit", "work", "lock"):
            expected = objects.get(logical)
            if not isinstance(expected, dict):
                raise StateError("catalog-root-invalid",
                                 "terminal instance object set is invalid", 4)
            path = container / expected["basename"]
            try:
                observed = _catalog_object_identity(
                    container, expected["basename"], expected["size"])
            except FileNotFoundError:
                continue
            if observed != {key: expected[key] for key in
                            ("dev", "ino", "size", "mount_id", "digest")}:
                raise StateError("catalog-root-invalid",
                                 "terminal instance object identity changed", 4)
            os.unlink(os.fsencode(path))
            fsync_dir(container)
            progress["entries_deleted"] = progress.get("entries_deleted", 0) + 1
            _catalog_barrier("terminal-index", f"instance-{logical}-deleted")
        current = _terminal_update_accepted(
            container, instance_key,
            lambda value: phase(value, "did-catalog-delete"),
            "instance-release-did-delete")
        release_state = current["instance_release"]["phase"]
    if release_state == "did-catalog-delete":
        current = _terminal_update_accepted(
            container, instance_key,
            lambda value: phase(value, "committed"),
            "instance-release-committed")
    if current["instance_release"]["phase"] != "committed":
        raise StateError("catalog-root-invalid",
                         "terminal instance release phase is invalid", 4)
    return current


def _terminal_anchor_receipt(container: Path, instance_key: str,
                             claim_digest: str, receipt_digest: str) -> dict | None:
    """Terminal-first receipt anchor; return None only when P is not visible."""
    with TerminalFlock(container):
        fd = _terminal_open_pack(container, True)
        try:
            index, selected, _ = _terminal_find_cell(fd, instance_key)
            if index is None or selected is None:
                return None
            current = selected[3][2]
            if current.get("state") != "handoff-accepted":
                return None
            prior = current.get("gc_anchor")
            if prior is None:
                count = 1
                accumulator = _catalog_digest(
                    b"zyz-terminal-gc-anchor-v1",
                    bytes.fromhex(claim_digest) + bytes.fromhex(receipt_digest)).hex()
            elif (isinstance(prior, dict) and prior.get("schema_version") == 1 and
                  prior.get("phase") in ("waiting-claim-retire", "retired") and
                  isinstance(prior.get("count"), int) and prior["count"] >= 1 and
                  HEX64.fullmatch(str(prior.get("accumulator_sha256"))) and
                  HEX64.fullmatch(str(prior.get("latest_claim_digest"))) and
                  HEX64.fullmatch(str(prior.get("latest_receipt_digest")))):
                if (prior["latest_claim_digest"] == claim_digest and
                        prior["latest_receipt_digest"] == receipt_digest):
                    return {"cell_index": index, "cell_generation": selected[0],
                            "cell_digest": selected[3][3].hex(), "anchor": prior}
                if prior.get("phase") != "retired":
                    raise StateError("catalog-root-invalid",
                                     "prior terminal anchor is not retired", 4)
                count = prior["count"] + 1
                if count > 2147483647:
                    raise StateError("catalog-root-invalid",
                                     "terminal anchor count overflows", 4)
                accumulator = _catalog_digest(
                    b"zyz-terminal-gc-anchor-successor-v1",
                    bytes.fromhex(prior["accumulator_sha256"]) +
                    bytes.fromhex(claim_digest) +
                    bytes.fromhex(receipt_digest)).hex()
            else:
                raise StateError("catalog-root-invalid",
                                 "terminal GC anchor is invalid", 4)
            anchor = {"schema_version": 1, "phase": "waiting-claim-retire",
                      "count": count,
                      "accumulator_sha256": accumulator,
                      "latest_claim_digest": claim_digest,
                      "latest_receipt_digest": receipt_digest}
            successor = {**current, "gc_anchor": anchor}
            generation, _, _, parsed = _terminal_write_cell(
                fd, selected, index, successor, "gc-anchor-committed")
            return {"cell_index": index, "cell_generation": generation,
                    "cell_digest": parsed[3].hex(), "anchor": anchor}
        finally:
            os.close(fd)


def _terminal_retire_claim_anchor(container: Path, claim_digest: str) -> bool:
    """Retire the unique terminal anchor after its external claim is released."""
    with TerminalFlock(container):
        fd = _terminal_open_pack(container, True)
        try:
            matches = []
            for index in range(TERMINAL_CELL_COUNT):
                selected = _terminal_selected_cell(fd, index)
                metadata = selected[3][2]
                anchor = metadata.get("gc_anchor")
                if (metadata.get("state") == "handoff-accepted" and
                        isinstance(anchor, dict) and
                        anchor.get("latest_claim_digest") == claim_digest):
                    matches.append((index, selected, metadata, anchor))
            if len(matches) > 1:
                raise StateError("catalog-root-invalid",
                                 "claim has multiple terminal anchors", 4)
            if not matches:
                return False
            index, selected, metadata, anchor = matches[0]
            if anchor.get("phase") == "retired":
                return True
            if anchor.get("phase") != "waiting-claim-retire":
                raise StateError("catalog-root-invalid",
                                 "terminal anchor phase is invalid", 4)
            successor = {
                **metadata, "gc_anchor": {**anchor, "phase": "retired"},
            }
            _terminal_write_cell(fd, selected, index, successor,
                                 "gc-anchor-retired")
            return True
        finally:
            os.close(fd)


def _terminal_late_clean(container: Path, instance_key: str,
                         done_record: dict | None = None) -> dict:
    """Persist/resume bounded late DONE evidence while preserving FINALIZED."""
    phases = ("prepared", "will-done", "did-done", "committed")
    while True:
        with TerminalFlock(container):
            fd = _terminal_open_pack(container, True)
            try:
                index, selected, _ = _terminal_find_cell(fd, instance_key)
                if index is None or selected is None:
                    raise StateError("late-event-retention-expired",
                                     "terminal cell is no longer retained", 4)
                current = selected[3][2]
                if (current.get("state") != "handoff-accepted" or
                        current["terminal_record"].get("terminal_kind") !=
                            "finalized"):
                    raise StateError("already-terminal",
                                     "late clean requires a finalized terminal cell")
                late = current.get("late_clean")
                if late is None:
                    if not isinstance(done_record, dict):
                        raise StateError("catalog-root-invalid",
                                         "late clean record is absent", 4)
                    late = {"schema_version": 1, "phase": "prepared",
                            "done_record": done_record,
                            "done_record_digest": json_digest(done_record)}
                    event_epoch = done_record.get("terminal_epoch")
                    if not isinstance(event_epoch, int) or event_epoch < 0:
                        raise StateError("catalog-root-invalid",
                                         "late clean epoch is invalid", 4)
                    grace = env_uint(
                        "ZYZ_RUNNING_NO_ACK_GRACE_SEC", 1200, 60, 86400)
                    successor = {
                        **current, "late_clean": late,
                        "last_event_epoch": max(
                            current["last_event_epoch"], event_epoch),
                        "retention_epoch": max(
                            current["retention_epoch"], event_epoch + grace),
                    }
                    _terminal_write_cell(
                        fd, selected, index, successor, "late-clean-prepared")
                    continue
                elif (not isinstance(late, dict) or
                      late.get("schema_version") != 1 or
                      late.get("phase") not in phases or
                      not isinstance(late.get("done_record"), dict) or
                      late.get("done_record_digest") !=
                          json_digest(late["done_record"])):
                    raise StateError("catalog-root-invalid",
                                     "terminal late-clean journal is invalid", 4)
                elif done_record is not None and (
                        late["done_record"].get("agent_id_sha256") !=
                            done_record.get("agent_id_sha256") or
                        late["done_record"].get("canonical_role") !=
                            done_record.get("canonical_role")):
                    raise StateError("identity-conflict",
                                     "late clean identity conflicts", 4)
                if late["phase"] == "committed":
                    return current
                next_phase = phases[phases.index(late["phase"]) + 1]
                successor_late = dict(late, phase=next_phase)
                event_epoch = late["done_record"].get("terminal_epoch")
                if not isinstance(event_epoch, int) or event_epoch < 0:
                    raise StateError("catalog-root-invalid",
                                     "late clean epoch is invalid", 4)
                grace = env_uint(
                    "ZYZ_RUNNING_NO_ACK_GRACE_SEC", 1200, 60, 86400)
                successor = {
                    **current, "late_clean": successor_late,
                    "last_event_epoch": max(current["last_event_epoch"], event_epoch),
                    "retention_epoch": max(
                        current["retention_epoch"], event_epoch + grace),
                }
                _terminal_write_cell(
                    fd, selected, index, successor, f"late-clean-{next_phase}")
            finally:
                os.close(fd)


def _terminal_pending_release_known(container: Path) -> bool:
    """Read the bounded terminal pack without retaining its lock."""
    with TerminalFlock(container):
        fd = _terminal_open_pack(container, False)
        try:
            for index in range(TERMINAL_CELL_COUNT):
                metadata = _terminal_selected_cell(fd, index)[3][2]
                if (metadata["state"] == "reserved" or
                        (metadata["state"] == "handoff-accepted" and
                         (metadata["instance_release"]["phase"] != "committed" or
                          (isinstance(metadata.get("late_clean"), dict) and
                           metadata["late_clean"].get("phase") != "committed")))):
                    return True
            return False
        finally:
            os.close(fd)


def _terminal_resume_pending_release(container: Path, config: dict) -> dict | None:
    """Resume at most one terminal R/F/P or INSTANCE_RELEASE owner per pass."""
    candidate = None
    with TerminalFlock(container):
        fd = _terminal_open_pack(container, False)
        try:
            for index in range(TERMINAL_CELL_COUNT):
                metadata = _terminal_selected_cell(fd, index)[3][2]
                if (metadata["state"] == "reserved" or
                        (metadata["state"] == "handoff-accepted" and
                         (metadata["instance_release"]["phase"] != "committed" or
                          (isinstance(metadata.get("late_clean"), dict) and
                           metadata["late_clean"].get("phase") != "committed")))):
                    candidate = metadata
                    break
        finally:
            os.close(fd)
    if candidate is None:
        return None
    instance_key = candidate["instance_key"]
    compaction_advanced = (candidate["state"] == "reserved" or
                           candidate["instance_release"]["phase"] != "committed")
    if candidate["state"] == "reserved":
        frozen = _terminal_freeze(container, instance_key, candidate)
        candidate = _terminal_publish(container, candidate, frozen)
    progress = {"entries_deleted": 0, "bytes_reclaimed": 0}
    completed = _terminal_release_instance_objects(
        container, instance_key, config, progress)
    if (isinstance(completed.get("late_clean"), dict) and
            completed["late_clean"].get("phase") != "committed"):
        completed = _terminal_late_clean(container, instance_key)
    return {"state": "committed", "instance_key": instance_key,
            "cell_index": completed["cell_index"],
            "request_bytes": completed["request_bytes"],
            "entries_deleted": progress["entries_deleted"],
            "bytes_reclaimed": progress["bytes_reclaimed"],
            "compaction_advanced": compaction_advanced,
            "free_receipt_record_digest":
                completed["instance_release"]["free_receipt_record_digest"]}


def _instance_pack_path(container: Path, key: str, kind: str) -> Path:
    if kind == "claim":
        if not HEX64.fullmatch(key):
            raise StateError("identity-conflict", "claim key digest is invalid", 3)
        return container / f"{key}.claim-pack.v1"
    suffix = "audit-pack.v1" if kind == "audit" else "work-pack.v1"
    return container / f"{key}.{suffix}"


def _instance_open_pack(container: Path, key: str, kind: str, write: bool = False) -> int:
    flags = (os.O_RDWR if write else os.O_RDONLY) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    path = _instance_pack_path(container, key, kind)
    fd = os.open(os.fsencode(path), flags)
    expected_size, _ = _instance_pack_layout(kind)
    observed = os.fstat(fd)
    if (not stat.S_ISREG(observed.st_mode) or observed.st_nlink != 1 or
            observed.st_size != expected_size or
            _catalog_mount_identity(path) != _catalog_mount_identity(container)):
        os.close(fd)
        raise StateError("invalid-schema", f"{kind} pack identity is invalid", 4)
    _instance_pack_header(fd, kind, key)
    return fd


def _instance_pack_read(container: Path, key: str, kind: str, slot: str) -> dict | None:
    fd = _instance_open_pack(container, key, kind, False)
    try: return _instance_pack_read_fd(fd, kind, key, slot)
    finally: os.close(fd)


def _instance_pack_write(container: Path, key: str, kind: str, slot: str,
                         payload: dict) -> tuple[int, str]:
    fd = _instance_open_pack(container, key, kind, True)
    try: return _instance_pack_write_fd(fd, kind, key, slot, payload)
    finally: os.close(fd)


def _fixed_ring_payload(payload: dict | None, slot: str, entry_key: str,
                        limit: int, receipt_type: str | None = None) -> list[dict]:
    """Validate one bounded event ring selected by an instance pack header."""
    if payload is None:
        return []
    required = {"schema_version", entry_key}
    if receipt_type is not None:
        required.add("receipt_type")
    if (not isinstance(payload, dict) or set(payload) != required or
            payload.get("schema_version") != 1 or
            (receipt_type is not None and
             payload.get("receipt_type") != receipt_type) or
            not isinstance(payload.get(entry_key), list) or
            len(payload[entry_key]) > limit):
        raise StateError("event-inventory-invalid",
                         f"fixed {slot} inventory is invalid", 4)
    return list(payload[entry_key])


def _fixed_diagnostics_fd(audit_fd: int, key: str) -> list[dict]:
    entries = _fixed_ring_payload(
        _instance_pack_read_fd(audit_fd, "audit", key, "DIAGNOSTICS"),
        "DIAGNOSTICS", "entries", 32)
    counts = {"start": 0, "stop": 0}
    required = {
        "schema_version", "kind", "instance_key", "raw_id_sha256",
        "canonical_role", "event_token", "nonce_sha256",
        "event_record_digest", "event_epoch", "reason_sha256",
        "needs_reconcile", "resolved_receipt_digest",
    }
    for entry in entries:
        kind = entry.get("kind") if isinstance(entry, dict) else None
        if (not isinstance(entry, dict) or set(entry) != required or
                entry.get("schema_version") != 1 or kind not in counts or
                entry.get("instance_key") != key or
                not HEX64.fullmatch(str(entry.get("raw_id_sha256"))) or
                entry.get("canonical_role") not in set(ROLES.values()) or
                not isinstance(entry.get("event_epoch"), int) or
                entry["event_epoch"] < 0 or
                not HEX64.fullmatch(str(entry.get("reason_sha256"))) or
                not isinstance(entry.get("needs_reconcile"), bool) or
                (entry.get("resolved_receipt_digest") is not None and
                 not HEX64.fullmatch(str(entry["resolved_receipt_digest"])))):
            raise StateError("event-inventory-invalid",
                             "fixed diagnostic entry is invalid", 4)
        validate_event_identity_fields(
            "start-unarmed" if kind == "start" else "stop-uncommitted",
            entry)
        counts[kind] += 1
        if counts[kind] > EVENT_INVENTORY_LIMITS[
                "start-unarmed" if kind == "start" else "stop-uncommitted"]:
            raise StateError("event-inventory-invalid",
                             "fixed diagnostic inventory limit exceeded", 4)
    return entries


def _fixed_resolved_fd(audit_fd: int, key: str, kind: str) -> list[dict]:
    slot = "RESOLVED_START" if kind == "start" else "RESOLVED_STOP"
    entries = _fixed_ring_payload(
        _instance_pack_read_fd(audit_fd, "audit", key, slot),
        slot, "entries", EVENT_INVENTORY_LIMITS["resolved"], kind)
    required = {
        "schema_version", "receipt_type", "txn_id", "event_token",
        "nonce_sha256", "event_record_digest", "raw_id_sha256",
        "canonical_role", "owner_diagnostic_digest",
        "committed_journal_digest", "target_slot_generation",
        "target_slot_digest", "resolved_epoch", "outcome",
        "cleanup_state", "cleanup_txn_digest",
    }
    for entry in entries:
        if (not isinstance(entry, dict) or set(entry) != required or
                entry.get("schema_version") != 1 or
                entry.get("receipt_type") != kind or
                not HEX64.fullmatch(str(entry.get("txn_id"))) or
                not HEX64.fullmatch(str(entry.get("raw_id_sha256"))) or
                entry.get("canonical_role") not in set(ROLES.values()) or
                not HEX64.fullmatch(str(entry.get("owner_diagnostic_digest"))) or
                not HEX64.fullmatch(str(entry.get("committed_journal_digest"))) or
                not isinstance(entry.get("target_slot_generation"), dict) or
                not isinstance(entry.get("target_slot_digest"), dict) or
                not isinstance(entry.get("resolved_epoch"), int) or
                entry["resolved_epoch"] < 0 or
                not isinstance(entry.get("outcome"), str) or
                not isinstance(entry.get("cleanup_state"), str) or
                (entry.get("cleanup_txn_digest") is not None and
                 not HEX64.fullmatch(str(entry["cleanup_txn_digest"])))):
            raise StateError("event-inventory-invalid",
                             f"fixed {kind} receipt is invalid", 4)
        validate_event_identity_fields("resolved", entry)
        if (set(entry["target_slot_generation"]) !=
                set(entry["target_slot_digest"]) or
                any(not isinstance(value, int) or value < 1
                    for value in entry["target_slot_generation"].values()) or
                any(not HEX64.fullmatch(str(value))
                    for value in entry["target_slot_digest"].values())):
            raise StateError("event-inventory-invalid",
                             f"fixed {kind} receipt targets are invalid", 4)
    return entries


def _fixed_event_inventory_fd(audit_fd: int, work_fd: int,
                              key: str) -> list[dict]:
    """Scan every retained fixed location before selecting a hook identity."""
    retained = []
    for entry in _fixed_diagnostics_fd(audit_fd, key):
        retained.append(validate_event_identity_fields(
            "start-unarmed" if entry["kind"] == "start" else
            "stop-uncommitted", entry))
    journal = _instance_pack_read_fd(
        work_fd, "work", key, "TRANSITION_JOURNAL")
    if journal is not None and all(field in journal for field in
                                   ("event_token", "nonce_sha256",
                                    "event_record_digest")):
        location = "committed" if journal.get("phase") in (
            "committed", "committed-terminal") else "journal"
        retained.append(validate_event_identity_fields(location, journal))
    for kind in ("start", "stop"):
        for entry in _fixed_resolved_fd(audit_fd, key, kind):
            retained.append(validate_event_identity_fields("resolved", entry))
    late = _fixed_ring_payload(
        _instance_pack_read_fd(audit_fd, "audit", key, "LATE_EVENT"),
        "LATE_EVENT", "events", EVENT_INVENTORY_LIMITS["late-event"])
    for entry in late:
        retained.append(validate_event_identity_fields("late-event", entry))
    if len(retained) > 128:
        raise StateError("event-inventory-invalid",
                         "fixed event inventory exceeds 128 entries", 4)
    return retained


def _fixed_select_event_identity_fd(audit_fd: int, work_fd: int, key: str,
                                    kind: str, role: str,
                                    digest: str) -> dict:
    retained = _fixed_event_inventory_fd(audit_fd, work_fd, key)
    for attempt in range(8):
        candidate = event_identity(kind, role, digest, nonce_hex(attempt))
        if all(not any(hmac.compare_digest(candidate[field], row[field])
                       for field in ("event_token", "nonce_sha256",
                                     "event_record_digest"))
               for row in retained):
            return candidate
    raise StateError("event-token-collision",
                     "event identity collision retry limit exhausted", 4)


def _fixed_diagnostic_record(kind: str, key: str, digest: str, role: str,
                             event: dict, epoch: int,
                             reason: str) -> dict:
    return {
        "schema_version": 1, "kind": kind, "instance_key": key,
        "raw_id_sha256": digest, "canonical_role": role,
        "event_token": event["event_token"],
        "nonce_sha256": event["nonce_sha256"],
        "event_record_digest": event["event_record_digest"],
        "event_epoch": epoch, "reason_sha256": sha(reason.encode()),
        "needs_reconcile": True, "resolved_receipt_digest": None,
    }


def _fixed_append_diagnostic_fd(audit_fd: int, key: str,
                                diagnostic: dict) -> None:
    entries = _fixed_diagnostics_fd(audit_fd, key)
    if any(entry["event_token"] == diagnostic["event_token"]
           for entry in entries):
        raise StateError("event-token-collision",
                         "diagnostic event token is already retained", 4)
    kind_count = sum(entry["kind"] == diagnostic["kind"] for entry in entries)
    if kind_count >= 16:
        raise StateError("event-inventory-invalid",
                         "diagnostic ring is full", 4)
    payload = {"schema_version": 1, "entries": entries + [diagnostic]}
    _instance_pack_write_fd(
        audit_fd, "audit", key, "DIAGNOSTICS", payload,
        "event-diagnostic")


def _fixed_record_refs(fd: int, kind: str, key: str,
                       slots: tuple[str, ...]) -> tuple[dict, dict]:
    selected = _instance_pack_header(fd, kind, key)[3][2]["selected"]
    generations, digests = {}, {}
    for slot in slots:
        ref = selected.get(slot)
        if not isinstance(ref, dict):
            raise StateError("receipt-mismatch",
                             f"fixed {slot} target is absent", 4)
        generations[slot] = ref["generation"]
        digests[slot] = ref["digest"]
    return generations, digests


def _catalog_rename_noreplace_unconfirmed(source: Path, target: Path) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    src_b, dst_b = os.fsencode(source), os.fsencode(target)
    result = -1
    if sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        func = libc.renameat2
        func.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        func.restype = ctypes.c_int
        result = func(-100, src_b, -100, dst_b, 1)
    elif sys.platform == "darwin" and hasattr(libc, "renameatx_np"):
        func = libc.renameatx_np
        func.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        func.restype = ctypes.c_int
        result = func(-2, src_b, -2, dst_b, 0x00000004)
    if result != 0:
        observed = ctypes.get_errno()
        if observed == errno.EEXIST:
            raise StateError("catalog-root-invalid", "canonical global pack already exists", 4)
        if observed in (errno.ENOSYS, errno.ENOTSUP, errno.EOPNOTSUPP, errno.EINVAL):
            raise StateError("genesis-capability-unavailable",
                             "kernel atomic no-replace rename is unavailable", 4, True)
        raise StateError("io", f"catalog rename failed: errno {observed}", 6, True)


def _catalog_barrier(namespace: str, phase: str) -> None:
    barrier = os.environ.get("ZYZ_TEST_TRANSITION_STOP_AFTER")
    point = f"{namespace}:{phase}"
    if barrier in (phase, point):
        os._exit(86)


def _catalog_claim_owner_barrier(owner: dict, phase: str) -> None:
    """Select one OWNER boundary without colliding across producer kinds."""
    selector=os.environ.get("ZYZ_TEST_CLAIM_OWNER_STOP_AFTER")
    if selector is None:
        return
    purpose=owner.get("purpose") if isinstance(owner,dict) else None
    parent=owner.get("parent_txn_id") if isinstance(owner,dict) else None
    digest=owner.get("logical_key_sha256") if isinstance(owner,dict) else None
    if (not isinstance(purpose,str) or not isinstance(parent,str) or
            not isinstance(digest,str) or not HEX64.fullmatch(digest) or
            not isinstance(phase,str) or not phase):
        raise StateError("catalog-root-invalid",
                         "claim OWNER barrier identity is invalid",4)
    point=f"catalog-claim-owner:{purpose}:{parent}:{digest}:{phase}"
    if selector == point:
        os._exit(86)


def _catalog_segment_image(generation: int, name: str) -> bytes:
    metadata = {"schema_version": 1, "segment_generation": generation,
                "deterministic_basename": name, "size": CATALOG_SEGMENT_SIZE,
                "committed_used_length": 0, "committed_content_sha256": hashlib.sha256(b"").hexdigest(),
                "predecessor_generation": None, "predecessor_descriptor_sha256": None,
                "predecessor_chain_accumulator": hashlib.sha256(b"zyz-empty-segment-chain-v1").hexdigest()}
    return _catalog_image(b"ZYZSEG1", 4096, 1, bytes(32), metadata)


def _catalog_frame_image(kind: str, payload: dict) -> bytes:
    kinds = {"overlay": 1, "free-receipt": 2, "owner": 3, "claim": 4,
             "observation": 5}
    if kind not in kinds:
        raise StateError("gc-internal", "unknown catalog frame kind", 5)
    encoded = _catalog_json(payload)
    total = (64 + len(encoded) + 7) & ~7
    if total > 65536:
        raise StateError("gc-internal", "catalog frame exceeds fixed maximum", 5)
    frame = bytearray(total); frame[0:8] = b"ZYZFRM1\0"
    struct.pack_into(">HHII", frame, 8, 1, kinds[kind], len(encoded), total)
    frame[20:52] = _catalog_digest(b"zyz-catalog-frame-payload-v1", encoded)
    frame[64:64 + len(encoded)] = encoded
    return bytes(frame)


def _catalog_parse_frame(raw: bytes, expected_kind: str | None = None) -> dict:
    kinds = {1: "overlay", 2: "free-receipt", 3: "owner", 4: "claim",
             5: "observation"}
    if len(raw) < 64 or raw[0:8] != b"ZYZFRM1\0":
        raise StateError("catalog-root-invalid", "catalog frame magic is invalid", 4)
    schema, kind_number, payload_length, total = struct.unpack_from(">HHII", raw, 8)
    if (schema != 1 or kind_number not in kinds or total != len(raw) or total % 8 or
            payload_length > total - 64 or raw[52:64] != bytes(12) or
            raw[64 + payload_length:] != bytes(total - 64 - payload_length)):
        raise StateError("catalog-root-invalid", "catalog frame header is invalid", 4)
    kind = kinds[kind_number]
    if expected_kind is not None and kind != expected_kind:
        raise StateError("catalog-root-invalid", "catalog frame kind conflicts", 4)
    encoded = raw[64:64 + payload_length]
    if raw[20:52] != _catalog_digest(b"zyz-catalog-frame-payload-v1", encoded):
        raise StateError("catalog-root-invalid", "catalog frame payload checksum is invalid", 4)
    try:
        payload = json.loads(encoded)
    except Exception:
        raise StateError("catalog-root-invalid", "catalog frame payload is invalid", 4)
    if not isinstance(payload, dict):
        raise StateError("catalog-root-invalid", "catalog frame payload is not an object", 4)
    return {"kind": kind, "payload": payload,
            "digest": _catalog_digest(b"zyz-catalog-frame-v1", raw)}


def _catalog_segment_descriptor(fd: int) -> tuple:
    return _catalog_select_ab(fd, CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL,
                              4096, b"ZYZSEG1")


def _catalog_segment_chain_projection(container: Path, name: str,
                                      generation: int) -> dict:
    """Return the exact descriptor/object facts committed by a chain anchor."""
    if (generation < 0 or len(os.fsencode(name)) > 255 or "/" in name or
            name in (".", "..")):
        raise StateError("catalog-root-invalid", "hybrid-chain segment name is invalid", 4)
    try:
        fd = os.open(os.fsencode(container / name),
                     os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) |
                     getattr(os, "O_CLOEXEC", 0))
    except OSError:
        # A missing/moved anchor (ENOENT), an O_NOFOLLOW symlink swap (ELOOP),
        # or any other open error is corruption of a committed chain anchor,
        # not transient pressure: fail closed as catalog-root-invalid rc4
        # (retryable defaults False), mirroring the read-validation facts below.
        raise StateError("catalog-root-invalid",
                         "hybrid-chain segment is unavailable", 4)
    try:
        observed = os.fstat(fd)
        if (not stat.S_ISREG(observed.st_mode) or observed.st_nlink != 1 or
                observed.st_size != CATALOG_SEGMENT_SIZE or
                observed.st_blocks * 512 < CATALOG_SEGMENT_SIZE):
            raise StateError("catalog-root-invalid",
                             "hybrid-chain segment allocation is invalid", 4)
        descriptor = _catalog_segment_descriptor(fd)
        metadata = descriptor[3][2]
        used = metadata.get("committed_used_length")
        if (metadata.get("segment_generation") != generation or
                metadata.get("deterministic_basename") != name or
                not isinstance(used, int) or
                not 0 <= used <= CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL):
            raise StateError("catalog-root-invalid",
                             "hybrid-chain segment descriptor conflicts", 4)
        content = _catalog_pread_exact(fd, used, 0)
        if hashlib.sha256(content).hexdigest() != metadata.get(
                "committed_content_sha256"):
            raise StateError("catalog-root-invalid",
                             "hybrid-chain segment content conflicts", 4)
        identity = {
            "dev": observed.st_dev, "ino": observed.st_ino,
            "size": observed.st_size,
            "mount_id": _catalog_mount_identity(container / name),
        }
        identity_digest = hashlib.sha256(_catalog_json(identity)).hexdigest()
        return {
            "generation": generation, "basename": name,
            "identity_digest": identity_digest,
            "descriptor_digest": descriptor[3][3].hex(),
            "descriptor_generation": descriptor[0],
            "descriptor_predecessor": descriptor[3][1].hex(),
            "used_length": used,
            "predecessor_generation": metadata.get("predecessor_generation"),
            "predecessor_descriptor_sha256":
                metadata.get("predecessor_descriptor_sha256"),
            "predecessor_chain_accumulator":
                metadata.get("predecessor_chain_accumulator"),
        }
    finally:
        os.close(fd)


def _catalog_append_will_validate(will: dict) -> dict:
    required = {"segment_generation", "frame_offset", "frame_length",
                "frame_digest"}
    if (not isinstance(will, dict) or set(will) != required or
            not isinstance(will.get("segment_generation"), int) or
            will["segment_generation"] < 1 or
            not isinstance(will.get("frame_offset"), int) or
            will["frame_offset"] < 0 or
            not isinstance(will.get("frame_length"), int) or
            will["frame_length"] < 64 or
            not HEX64.fullmatch(str(will.get("frame_digest"))) or
            will["frame_offset"] + will["frame_length"] >
                CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL):
        raise StateError("catalog-root-invalid",
                         "catalog append will is invalid", 4)
    return will


def _catalog_pending_append_will(root_meta: dict, aggregates: dict) -> dict | None:
    """Select the sole durable append owner visible from ROOT/CELL state."""
    candidates = list(aggregates.get("pending_append_wills", []))
    claim = root_meta.get("claim_frame_will")
    if claim is not None:
        if not isinstance(claim, dict):
            raise StateError("catalog-root-invalid",
                             "claim append will is invalid", 4)
        candidates.append({name: claim.get(name) for name in
                           ("segment_generation", "frame_offset",
                            "frame_length", "frame_digest")})
    previs_free = root_meta.get("previs_free_will")
    if previs_free is not None:
        if not isinstance(previs_free, dict):
            raise StateError("catalog-root-invalid",
                             "PREVIS free append will is invalid", 4)
        candidates.append({name: previs_free.get(name) for name in
                           ("segment_generation", "frame_offset",
                            "frame_length", "frame_digest")})
    candidates = [_catalog_append_will_validate(value)
                  for value in candidates]
    if len(candidates) > 1:
        raise StateError("catalog-root-invalid",
                         "catalog append ownership is ambiguous", 4)
    return candidates[0] if candidates else None


def _catalog_scratch_append_after_matches(container: Path, entry: dict,
                                          projection: dict,
                                          append_will: dict | None) -> bool:
    """Authenticate the sole legal scratch mutation before its ROOT did."""
    if append_will is None:
        return False
    will = _catalog_append_will_validate(append_will)
    offset = will["frame_offset"]
    length = will["frame_length"]
    if (will["segment_generation"] != entry["last_generation"] or
            offset != entry["used_length"] or
            projection["basename"] != entry["basename"] or
            projection["identity_digest"] != entry["identity_digest"] or
            projection["descriptor_generation"] !=
                entry["descriptor_generation"] + 1 or
            projection["descriptor_predecessor"] !=
                entry["descriptor_digest"] or
            projection["used_length"] != offset + length):
        return False
    fd = os.open(os.fsencode(container / entry["basename"]),
                 os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        prior = None
        for bank in (0, 1):
            raw = _catalog_pread_exact(
                fd, 4096,
                CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL + bank * 4096)
            try:
                parsed = _catalog_parse_image(raw, b"ZYZSEG1")
            except StateError:
                continue
            if parsed[3].hex() == entry["descriptor_digest"]:
                prior = parsed
        if prior is None:
            return False
        metadata = prior[2]
        if (prior[0] != entry["descriptor_generation"] or
                metadata.get("segment_generation") != 0 or
                metadata.get("deterministic_basename") != entry["basename"] or
                metadata.get("committed_used_length") != offset or
                hashlib.sha256(_catalog_pread_exact(fd, offset, 0)).hexdigest() !=
                    metadata.get("committed_content_sha256")):
            return False
        frame = _catalog_pread_exact(fd, length, offset)
        return hmac.compare_digest(
            _catalog_digest(b"zyz-catalog-frame-v1", frame).hex(),
            will["frame_digest"])
    finally:
        os.close(fd)


def _catalog_chain_range_anchor(container: Path, first_generation: int,
                                last_generation: int) -> dict:
    """Freeze a contiguous deterministic segment run into one bounded anchor."""
    if first_generation < 1 or last_generation < first_generation:
        raise StateError("gc-internal", "hybrid-chain range is invalid", 5)
    projections = []
    prior = None
    for generation in range(first_generation, last_generation + 1):
        name = f".catalog-segment.{generation:016d}.v1"
        projection = _catalog_segment_chain_projection(container, name, generation)
        if prior is not None and (
                projection["predecessor_generation"] != prior["generation"] or
                projection["predecessor_descriptor_sha256"] !=
                    prior["descriptor_digest"]):
            raise StateError("catalog-root-invalid",
                             "hybrid-chain range predecessor conflicts", 4)
        projections.append(projection)
        prior = projection
    identity_material = _catalog_json([
        {"generation": value["generation"], "basename": value["basename"],
         "identity_digest": value["identity_digest"]}
        for value in projections
    ])
    return {
        "schema_version": 1, "kind": "segment-range",
        "first_generation": first_generation,
        "last_generation": last_generation,
        "member_count": len(projections),
        "identity_set_digest": _catalog_digest(
            b"zyz-hybrid-chain-identities-v1", identity_material).hex(),
    }


def _catalog_validate_chain_entry(container: Path, entry: dict,
                                  append_will: dict | None = None) -> list[dict]:
    if entry.get("kind") == "scratch-object":
        required = {
            "schema_version", "kind", "first_generation", "last_generation",
            "basename", "identity_digest", "descriptor_digest",
            "descriptor_generation", "used_length", "plan_digest",
            "source_group_digest", "cancel_set_digest",
        }
        if (set(entry) != required or entry.get("schema_version") != 1 or
                not isinstance(entry.get("basename"), str) or
                not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", entry["basename"]) or
                not isinstance(entry.get("first_generation"), int) or
                not isinstance(entry.get("last_generation"), int) or
                entry["first_generation"] < 1 or
                entry["last_generation"] < entry["first_generation"] or
                not isinstance(entry.get("descriptor_generation"), int) or
                entry["descriptor_generation"] < 1 or
                not isinstance(entry.get("used_length"), int) or
                not 0 <= entry["used_length"] <=
                    CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL or
                any(not HEX64.fullmatch(str(entry.get(name))) for name in
                    ("identity_digest", "descriptor_digest", "plan_digest",
                     "source_group_digest", "cancel_set_digest"))):
            raise StateError("catalog-root-invalid",
                             "hybrid scratch anchor is invalid", 4)
        projection = _catalog_segment_chain_projection(
            container, entry["basename"], 0)
        if ((projection["identity_digest"] != entry["identity_digest"] or
                projection["descriptor_digest"] != entry["descriptor_digest"] or
                projection["descriptor_generation"] !=
                    entry["descriptor_generation"] or
                projection["used_length"] != entry["used_length"]) and
                not _catalog_scratch_append_after_matches(
                    container, entry, projection, append_will)):
            raise StateError("catalog-root-invalid",
                             "hybrid scratch object changed", 4)
        return [{**projection, "generation": entry["last_generation"],
                 "logical_first_generation": entry["first_generation"],
                 "logical_last_generation": entry["last_generation"],
                 "anchor_kind": "scratch-object",
                 "plan_digest": entry["plan_digest"],
                 "source_group_digest": entry["source_group_digest"],
                 "cancel_set_digest": entry["cancel_set_digest"]}]
    required = {
        "schema_version", "kind", "first_generation", "last_generation",
        "member_count", "identity_set_digest",
    }
    if (set(entry) != required or entry.get("schema_version") != 1 or
            entry.get("kind") != "segment-range" or
            not isinstance(entry.get("first_generation"), int) or
            not isinstance(entry.get("last_generation"), int) or
            entry["first_generation"] < 1 or
            entry["last_generation"] < entry["first_generation"] or
            entry.get("member_count") !=
                entry["last_generation"] - entry["first_generation"] + 1 or
            not HEX64.fullmatch(str(entry.get("identity_set_digest")))):
        raise StateError("catalog-root-invalid", "hybrid-chain entry is invalid", 4)
    observed = _catalog_chain_range_anchor(
        container, entry["first_generation"], entry["last_generation"])
    if observed != entry:
        raise StateError("catalog-root-invalid",
                         "hybrid-chain anchored segment facts changed", 4)
    return [
        _catalog_segment_chain_projection(
            container, f".catalog-segment.{generation:016d}.v1", generation)
        for generation in range(entry["first_generation"],
                                entry["last_generation"] + 1)
    ]


def _catalog_chain_region(entries: list[dict], generation: int,
                          predecessor: bytes = bytes(32)) -> tuple[bytes, str]:
    """Build the fixed header/16-anchor/trailer ROOT hybrid-chain region."""
    if (not isinstance(entries, list) or not 1 <= len(entries) <=
            CATALOG_CHAIN_ENTRY_COUNT or generation < 1 or
            len(predecessor) != 32):
        raise StateError("gc-internal", "hybrid-chain image input is invalid", 5)
    entry_images = []
    entry_predecessor = predecessor
    for entry in entries:
        if entry.get("kind") == "scratch-object":
            basename = entry.get("basename", "").encode("ascii", "strict")
            if len(basename) > 80:
                raise StateError("gc-internal", "scratch anchor basename overflow", 5)
            metadata = {"v": 1, "k": "scratch-object",
                        "fg": entry["first_generation"],
                        "lg": entry["last_generation"]}
            binary = bytearray(272); binary[0:8] = b"ZYZSCA1\0"
            struct.pack_into(">H6x", binary, 8, len(basename))
            for index, name in enumerate(
                    ("identity_digest", "descriptor_digest", "plan_digest",
                     "source_group_digest", "cancel_set_digest")):
                binary[16 + index * 32:48 + index * 32] = \
                    bytes.fromhex(entry[name])
            struct.pack_into(">QQ", binary, 176,
                             entry["descriptor_generation"],
                             entry["used_length"])
            binary[192:192 + len(basename)] = basename
            image = _catalog_image(
                b"ZYZHCE1", CATALOG_CHAIN_ENTRY_SIZE, generation,
                entry_predecessor, metadata, ((240, bytes(binary)),),
                metadata_limit=112)
        else:
            image = _catalog_image(
                b"ZYZHCE1", CATALOG_CHAIN_ENTRY_SIZE, generation,
                entry_predecessor, entry, metadata_limit=384)
        entry_images.append(image)
        entry_predecessor = _catalog_digest(b"zyz-pack-image-id-v1", image)
    entry_region = b"".join(entry_images).ljust(
        CATALOG_CHAIN_PARTITIONS[1], b"\0")
    entries_digest = _catalog_digest(
        b"zyz-hybrid-chain-entry-set-v1", b"".join(entry_images))
    header_meta = {
        "schema_version": 1, "state": "active",
        "chain_generation": generation, "entry_count": len(entries),
        "entries_sha256": entries_digest.hex(),
    }
    header = _catalog_image(
        b"ZYZHCN1", CATALOG_CHAIN_PARTITIONS[0], generation,
        predecessor, header_meta)
    header_digest = _catalog_digest(b"zyz-pack-image-id-v1", header)
    hybrid_digest = _catalog_digest(
        b"zyz-catalog-hybrid-chain-v1", header_digest + entries_digest)
    trailer_meta = {
        "schema_version": 1, "state": "committed",
        "chain_generation": generation,
        "header_sha256": header_digest.hex(),
        "entries_sha256": entries_digest.hex(),
        "hybrid_chain_digest": hybrid_digest.hex(),
    }
    trailer = _catalog_image(
        b"ZYZHCT1", CATALOG_CHAIN_PARTITIONS[2], generation,
        header_digest, trailer_meta)
    region = header + entry_region + trailer
    if len(region) != CATALOG_CHAIN_SIZE:
        raise StateError("gc-internal", "hybrid-chain layout overflow", 5)
    return region, hybrid_digest.hex()


def _catalog_parse_chain_region(container: Path, raw: bytes,
                                append_will: dict | None = None) -> dict:
    if len(raw) != CATALOG_CHAIN_SIZE:
        raise StateError("catalog-root-invalid", "hybrid-chain region size is invalid", 4)
    header_size, entry_size, trailer_size = CATALOG_CHAIN_PARTITIONS
    header_raw = raw[:header_size]
    entry_raw = raw[header_size:header_size + entry_size]
    trailer_raw = raw[-trailer_size:]
    header = _catalog_parse_image(header_raw, b"ZYZHCN1")
    header_meta = header[2]
    if (set(header_meta) != {"schema_version", "state", "chain_generation",
                             "entry_count", "entries_sha256"} or
            header_meta.get("schema_version") != 1 or
            header_meta.get("state") != "active" or
            header_meta.get("chain_generation") != header[0] or
            not isinstance(header_meta.get("entry_count"), int) or
            not 1 <= header_meta["entry_count"] <= CATALOG_CHAIN_ENTRY_COUNT or
            not HEX64.fullmatch(str(header_meta.get("entries_sha256")))):
        raise StateError("catalog-root-invalid", "hybrid-chain header is invalid", 4)
    entries = []
    images = []
    predecessor = header[1]
    members = []
    prior_generation = 0
    for index in range(header_meta["entry_count"]):
        start = index * CATALOG_CHAIN_ENTRY_SIZE
        image = entry_raw[start:start + CATALOG_CHAIN_ENTRY_SIZE]
        parsed = _catalog_parse_image(
            image, b"ZYZHCE1", metadata_limit=384)
        if parsed[0] != header[0] or parsed[1] != predecessor:
            raise StateError("catalog-root-invalid",
                             "hybrid-chain entry predecessor conflicts", 4)
        entry = parsed[2]
        if entry.get("k") == "scratch-object":
            if (entry != {"v": 1, "k": "scratch-object",
                          "fg": entry.get("fg"), "lg": entry.get("lg")} or
                    not isinstance(entry.get("fg"), int) or
                    not isinstance(entry.get("lg"), int)):
                raise StateError("catalog-root-invalid",
                                 "hybrid scratch metadata is invalid", 4)
            binary = image[240:512]
            if binary[0:8] != b"ZYZSCA1\0":
                raise StateError("catalog-root-invalid",
                                 "hybrid scratch payload magic is invalid", 4)
            name_length = struct.unpack_from(">H", binary, 8)[0]
            if (binary[10:16] != bytes(6) or not 1 <= name_length <= 80 or
                    binary[192 + name_length:] != bytes(80 - name_length)):
                raise StateError("catalog-root-invalid",
                                 "hybrid scratch payload padding is invalid", 4)
            try:
                basename = binary[192:192 + name_length].decode("ascii")
            except UnicodeDecodeError:
                raise StateError("catalog-root-invalid",
                                 "hybrid scratch basename is invalid", 4)
            descriptor_generation, used_length = struct.unpack_from(">QQ", binary, 176)
            names = ("identity_digest", "descriptor_digest", "plan_digest",
                     "source_group_digest", "cancel_set_digest")
            digests = {name: binary[16 + position * 32:48 + position * 32].hex()
                       for position, name in enumerate(names)}
            entry = {"schema_version": 1, "kind": "scratch-object",
                     "first_generation": entry["fg"],
                     "last_generation": entry["lg"], "basename": basename,
                     "descriptor_generation": descriptor_generation,
                     "used_length": used_length, **digests}
        if entry.get("first_generation", 0) <= prior_generation:
            raise StateError("catalog-root-invalid",
                             "hybrid-chain entry order conflicts", 4)
        entry_members = _catalog_validate_chain_entry(
            container, entry, append_will)
        entries.append(entry)
        members.extend(entry_members)
        prior_generation = entry["last_generation"]
        images.append(image)
        predecessor = parsed[3]
    if entry_raw[len(images) * CATALOG_CHAIN_ENTRY_SIZE:] != bytes(
            entry_size - len(images) * CATALOG_CHAIN_ENTRY_SIZE):
        raise StateError("catalog-root-invalid", "hybrid-chain unused anchors are nonzero", 4)
    entries_digest = _catalog_digest(
        b"zyz-hybrid-chain-entry-set-v1", b"".join(images))
    if entries_digest.hex() != header_meta["entries_sha256"]:
        raise StateError("catalog-root-invalid", "hybrid-chain entry digest conflicts", 4)
    trailer = _catalog_parse_image(trailer_raw, b"ZYZHCT1")
    header_digest = header[3]
    hybrid_digest = _catalog_digest(
        b"zyz-catalog-hybrid-chain-v1", header_digest + entries_digest)
    trailer_meta = trailer[2]
    if (trailer[0] != header[0] or trailer[1] != header_digest or
            trailer_meta != {
                "schema_version": 1, "state": "committed",
                "chain_generation": header[0],
                "header_sha256": header_digest.hex(),
                "entries_sha256": entries_digest.hex(),
                "hybrid_chain_digest": hybrid_digest.hex(),
            }):
        raise StateError("catalog-root-invalid", "hybrid-chain trailer conflicts", 4)
    return {
        "generation": header[0], "predecessor": header[1],
        "entries": entries, "members": members,
        "digest": hybrid_digest.hex(), "region": raw,
    }


def _catalog_segment_commit_frame(container: Path, generation: int, offset: int,
                                  frame: bytes) -> dict:
    name = f".catalog-segment.{generation:016d}.v1"
    path = container / name
    fd = os.open(os.fsencode(path), os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
    try:
        if os.fstat(fd).st_size != CATALOG_SEGMENT_SIZE:
            raise StateError("catalog-root-invalid", "catalog segment size is invalid", 4)
        descriptor = _catalog_segment_descriptor(fd)
        metadata = descriptor[3][2]
        used = metadata.get("committed_used_length")
        if (metadata.get("segment_generation") != generation or
                metadata.get("deterministic_basename") != name or
                not isinstance(used, int) or used < 0 or
                used > CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL):
            raise StateError("catalog-root-invalid", "catalog segment descriptor is invalid", 4)
        committed = _catalog_pread_exact(fd, used, 0)
        if hashlib.sha256(committed).hexdigest() != metadata.get("committed_content_sha256"):
            raise StateError("catalog-root-invalid", "catalog segment content digest changed", 4)
        end = offset + len(frame)
        if offset < 0 or end > CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL:
            raise StateError("catalog-capacity-pressure", "catalog segment append area is full", 4, True)
        if used > offset:
            if used < end or _catalog_pread_exact(fd, len(frame), offset) != frame:
                raise StateError("catalog-root-invalid", "catalog frame offset conflicts", 4)
            return {"segment_generation": generation, "offset": offset,
                    "end": end, "descriptor_digest": descriptor[3][3].hex(),
                    "descriptor_generation": descriptor[0], "idempotent": True}
        if used != offset:
            raise StateError("catalog-root-invalid", "catalog segment append has a gap", 4)
        _catalog_pwrite_all(fd, frame, offset, "catalog immutable frame")
        _data_sync(fd)
        content = _catalog_pread_exact(fd, end, 0)
        successor_meta = dict(metadata, committed_used_length=end,
                              committed_content_sha256=hashlib.sha256(content).hexdigest())
        successor = _catalog_image(b"ZYZSEG1", 4096, descriptor[0] + 1,
                                   descriptor[3][3], successor_meta)
        bank = 1 - descriptor[1]
        _catalog_pwrite_all(fd, successor,
                            CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL + bank * 4096,
                            "segment descriptor successor")
        _data_sync(fd)
        return {"segment_generation": generation, "offset": offset, "end": end,
                "descriptor_digest": _catalog_digest(
                    b"zyz-pack-image-id-v1", successor).hex(),
                "descriptor_generation": descriptor[0] + 1, "idempotent": False}
    finally:
        os.close(fd)


def _catalog_chain_member(proof: dict, generation: int) -> dict:
    """Resolve one logical generation to its exact physical chain member."""
    members = proof.get("chain", {}).get("members", [])
    matches = []
    for member in members:
        first = member.get("logical_first_generation", member.get("generation"))
        last = member.get("logical_last_generation", member.get("generation"))
        if (isinstance(first, int) and isinstance(last, int) and
                first <= generation <= last):
            matches.append(member)
    if len(matches) != 1:
        raise StateError("catalog-root-invalid",
                         "logical segment member is ambiguous", 4)
    return matches[0]


def _catalog_active_member(proof: dict) -> dict:
    generation = proof.get("root_meta", {}).get("active_segment_generation")
    if not isinstance(generation, int) or generation < 1:
        raise StateError("catalog-root-invalid",
                         "active segment generation is invalid", 4)
    member = _catalog_chain_member(proof, generation)
    if (member.get("descriptor_digest") !=
            proof["root_meta"].get("active_segment_descriptor_digest") or
            member.get("used_length") !=
            proof["root_meta"].get("active_segment_used_length")):
        append_will = proof.get("pending_append_will")
        if (append_will is None or
                append_will.get("segment_generation") != generation or
                append_will.get("frame_offset") !=
                    proof["root_meta"].get("active_segment_used_length") or
                member.get("descriptor_predecessor") !=
                    proof["root_meta"].get("active_segment_descriptor_digest") or
                member.get("used_length") !=
                    append_will["frame_offset"] + append_will["frame_length"]):
            raise StateError("catalog-root-invalid",
                             "active segment member conflicts", 4)
    return member


def _catalog_commit_active_frame(container: Path, proof: dict, generation: int,
                                 offset: int, frame: bytes) -> dict:
    member = _catalog_chain_member(proof, generation)
    if member.get("anchor_kind") == "scratch-object":
        result = _catalog_scratch_commit_frame(
            container, member["basename"], offset, frame)
        return {**result, "segment_generation": generation,
                "basename": member["basename"], "anchor_kind": "scratch-object"}
    result = _catalog_segment_commit_frame(
        container, generation, offset, frame)
    return {**result, "basename": member["basename"],
            "anchor_kind": "segment-range"}


def _catalog_active_append_chain_region(proof: dict,
                                        result: dict) -> bytes | None:
    """Advance a visible scratch anchor in the same ROOT did successor."""
    if result.get("anchor_kind") != "scratch-object":
        return None
    chain = proof.get("chain")
    generation = result.get("segment_generation")
    if not isinstance(chain, dict) or not isinstance(generation, int):
        raise StateError("catalog-root-invalid",
                         "scratch append chain prior is invalid", 4)
    entries = []
    replaced = 0
    for entry in chain["entries"]:
        if (entry.get("kind") == "scratch-object" and
                entry["first_generation"] <= generation <=
                    entry["last_generation"]):
            if entry["basename"] != result["basename"]:
                raise StateError("catalog-root-invalid",
                                 "scratch append basename conflicts", 4)
            entries.append(dict(
                entry, descriptor_digest=result["descriptor_digest"],
                descriptor_generation=result["descriptor_generation"],
                used_length=result["end"]))
            replaced += 1
        else:
            entries.append(entry)
    if replaced != 1:
        raise StateError("catalog-root-invalid",
                         "scratch append anchor is ambiguous", 4)
    region, _ = _catalog_chain_region(
        entries, chain["generation"] + 1, bytes.fromhex(chain["digest"]))
    return region


def _catalog_scratch_commit_frame(container: Path, name: str, offset: int,
                                  frame: bytes) -> dict:
    """Append one planned frame to the fixed compaction scratch idempotently."""
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", name):
        raise StateError("catalog-root-invalid", "migration scratch name is invalid", 4)
    fd = os.open(os.fsencode(container / name),
                 os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
    try:
        if os.fstat(fd).st_size != CATALOG_SEGMENT_SIZE:
            raise StateError("catalog-root-invalid", "migration scratch size is invalid", 4)
        descriptor = _catalog_segment_descriptor(fd)
        metadata = descriptor[3][2]
        used = metadata.get("committed_used_length")
        if (metadata.get("segment_generation") != 0 or
                metadata.get("deterministic_basename") != name or
                not isinstance(used, int) or
                not 0 <= used <= CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL):
            raise StateError("catalog-root-invalid",
                             "migration scratch descriptor is invalid", 4)
        committed = _catalog_pread_exact(fd, used, 0)
        if hashlib.sha256(committed).hexdigest() != metadata.get(
                "committed_content_sha256"):
            raise StateError("catalog-root-invalid",
                             "migration scratch content digest changed", 4)
        end = offset + len(frame)
        if offset < 0 or end > CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL:
            raise StateError("catalog-root-invalid",
                             "migration scratch append exceeds plan", 4)
        if used > offset:
            if used < end or _catalog_pread_exact(fd, len(frame), offset) != frame:
                raise StateError("catalog-root-invalid",
                                 "migration scratch frame conflicts", 4)
            return {"offset": offset, "end": end,
                    "descriptor_digest": descriptor[3][3].hex(),
                    "descriptor_generation": descriptor[0], "idempotent": True}
        if used != offset:
            raise StateError("catalog-root-invalid", "migration scratch has a gap", 4)
        _catalog_pwrite_all(fd, frame, offset, "migration scratch frame")
        _data_sync(fd)
        content = _catalog_pread_exact(fd, end, 0)
        successor_meta = dict(
            metadata, committed_used_length=end,
            committed_content_sha256=hashlib.sha256(content).hexdigest())
        successor = _catalog_image(
            b"ZYZSEG1", 4096, descriptor[0] + 1,
            descriptor[3][3], successor_meta)
        bank = 1 - descriptor[1]
        _catalog_pwrite_all(
            fd, successor,
            CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL + bank * 4096,
            "migration scratch descriptor successor")
        _data_sync(fd)
        return {"offset": offset, "end": end,
                "descriptor_digest": _catalog_digest(
                    b"zyz-pack-image-id-v1", successor).hex(),
                "descriptor_generation": descriptor[0] + 1,
                "idempotent": False}
    finally:
        os.close(fd)


def _terminal_has_reachable_tombstone(container: Path, instance_key: str) -> bool:
    """Return whether this probe chain still retains an eviction tombstone.

    Tombstones deliberately do not retain the evicted identity.  They only
    prove that an exact lookup miss may be the result of a legal retention
    eviction until that slot is reused.  A late host stop must report that
    observation ceiling instead of recreating the already released instance
    carriers (or collapsing it into a generic tracking failure).
    """
    with TerminalFlock(container):
        fd = _terminal_open_pack(container, False)
        try:
            start = _terminal_probe_start(instance_key)
            for step in range(TERMINAL_CELL_COUNT):
                index = (start + step) % TERMINAL_CELL_COUNT
                metadata = _terminal_selected_cell(fd, index)[3][2]
                if metadata.get("instance_key") == instance_key:
                    return False
                if metadata["state"] == "tombstone":
                    return True
                if metadata["state"] == "empty":
                    return False
            return False
        finally:
            os.close(fd)


def _catalog_rotate_claim_segment(container: Path, global_fd: int, recovery_fd: int,
                                  proof: dict) -> dict:
    """Activate the already-preallocated next segment and bind its chain."""
    root = proof["root_meta"]
    current_generation = root.get("active_segment_generation")
    if not isinstance(current_generation, int) or current_generation < 1:
        raise StateError("catalog-root-invalid", "active segment generation is invalid", 4)
    next_generation = current_generation + 1
    next_name = f".catalog-segment.{next_generation:016d}.v1"
    current_member = _catalog_active_member(proof)
    current_name = current_member["basename"]
    try:
        current_fd = os.open(os.fsencode(container / current_name), os.O_RDONLY |
                             getattr(os, "O_NOFOLLOW", 0))
        next_fd = os.open(os.fsencode(container / next_name), os.O_RDWR |
                          getattr(os, "O_NOFOLLOW", 0))
    except FileNotFoundError:
        raise StateError("catalog-capacity-pressure",
                         "preallocated claim rotation segment is unavailable", 4, True)
    try:
        current = _catalog_segment_descriptor(current_fd)
        target = _catalog_segment_descriptor(next_fd)
        current_meta = current[3][2]
        current_physical_generation = (0 if current_member.get("anchor_kind") ==
                                       "scratch-object" else current_generation)
        if (current_meta.get("segment_generation") != current_physical_generation or
                current_meta.get("deterministic_basename") != current_name or
                current_meta.get("committed_used_length") !=
                    root.get("active_segment_used_length") or
                current[3][3].hex() != root.get("active_segment_descriptor_digest")):
            raise StateError("catalog-root-invalid",
                             "claim rotation segment prior conflicts", 4)
        target_prior = None
        for bank in (0, 1):
            raw = _catalog_pread_exact(
                next_fd, 4096,
                CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL + bank * 4096)
            try:
                parsed = _catalog_parse_image(raw, b"ZYZSEG1")
            except StateError:
                continue
            metadata = parsed[2]
            if (metadata.get("segment_generation") == next_generation and
                    metadata.get("deterministic_basename") == next_name and
                    metadata.get("committed_used_length") == 0 and
                    metadata.get("predecessor_generation") is None):
                if target_prior is not None:
                    raise StateError("catalog-root-invalid",
                                     "claim rotation prior is ambiguous", 4)
                target_prior = (bank, raw, parsed)
        if target_prior is None:
            raise StateError("catalog-root-invalid",
                             "claim rotation target prior is absent", 4)
        target_bank, _, target_parsed = target_prior
        target_meta = target_parsed[2]
        accumulator = _catalog_digest(
            b"zyz-segment-chain-successor-v1",
            bytes.fromhex(current_meta["predecessor_chain_accumulator"]) +
            current[3][3])
        successor_meta = dict(
            target_meta, predecessor_generation=current_generation,
            predecessor_descriptor_sha256=current[3][3].hex(),
            predecessor_chain_accumulator=accumulator.hex())
        successor = _catalog_image(
            b"ZYZSEG1", 4096, target_parsed[0] + 1,
            target_parsed[3], successor_meta)
        if target[2] != successor:
            if target[3][3] != target_parsed[3]:
                raise StateError("catalog-root-invalid",
                                 "claim rotation target after conflicts", 4)
            bank = 1 - target_bank
            _catalog_pwrite_all(
                next_fd, successor,
                CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL + bank * 4096,
                "claim rotation descriptor")
            _data_sync(next_fd)
        _catalog_barrier("catalog-segment", "rotation-target-committed")
        descriptor_digest = _catalog_digest(
            b"zyz-pack-image-id-v1", successor).hex()
    finally:
        os.close(current_fd); os.close(next_fd)
    chain = proof.get("chain")
    if (not isinstance(chain, dict) or
            not HEX64.fullmatch(str(chain.get("digest")))):
        raise StateError("catalog-root-invalid", "claim rotation chain prior is invalid", 4)
    entries = list(chain["entries"])
    entries.append(_catalog_chain_range_anchor(
        container, next_generation, next_generation))
    chain_region, _ = _catalog_chain_region(
        entries,
        chain["generation"] + 1, bytes.fromhex(chain["digest"]))
    _catalog_root_successor(
        global_fd, recovery_fd, proof, proof["root"][2][4096:5120],
        {"active_segment_generation": next_generation,
         "active_segment_used_length": 0,
         "active_segment_descriptor_digest": descriptor_digest,
         "active_segment_claim_count": 0}, "claim-segment-rotated",
        chain_region)
    refreshed = _catalog_validate_genesis(container)
    os.close(refreshed.pop("global_fd"))
    return refreshed


def _catalog_group_image(generation: int, predecessor: bytes, metadata: dict) -> bytes:
    return _catalog_image(b"ZYZGRP1", CATALOG_GROUP_IMAGE_SIZE, generation,
                          predecessor, metadata, metadata_limit=60000)


def _catalog_selected_group(global_fd: int, root_meta: dict) -> tuple:
    expected = root_meta.get("group_control_digest")
    if not isinstance(expected, str) or not HEX64.fullmatch(expected):
        raise StateError("catalog-root-invalid", "ROOT group-control digest is invalid", 4)
    matches = []
    for bank in (0, 1):
        raw = _catalog_pread_exact(
            global_fd, CATALOG_GROUP_IMAGE_SIZE,
            CATALOG_LAYOUT["group_control"][0] + bank * CATALOG_GROUP_IMAGE_SIZE)
        if raw == bytes(CATALOG_GROUP_IMAGE_SIZE):
            continue
        try:
            parsed = _catalog_parse_image(
                raw, b"ZYZGRP1", metadata_limit=60000)
        except StateError:
            continue
        if parsed[3].hex() == expected:
            matches.append((parsed[0], bank, raw, parsed))
    if len(matches) != 1:
        raise StateError("catalog-root-invalid", "ROOT group-control selection is ambiguous", 4)
    return matches[0]


def _catalog_group_successor(global_fd: int, proof: dict, metadata: dict) -> dict:
    selected = proof["group"]
    successor = _catalog_group_image(selected[0] + 1, selected[3][3], metadata)
    bank = 1 - selected[1]
    _catalog_pwrite_all(
        global_fd, successor,
        CATALOG_LAYOUT["group_control"][0] + bank * CATALOG_GROUP_IMAGE_SIZE,
        "GROUP_CONTROL successor")
    _data_sync(global_fd)
    return {"bank": bank, "image": successor,
            "digest": _catalog_digest(b"zyz-pack-image-id-v1", successor),
            "metadata": metadata}


def _catalog_group_commit(global_fd: int, recovery_fd: int, proof: dict,
                          metadata: dict, barrier: str,
                          root_updates: dict | None = None) -> dict:
    successor = _catalog_group_successor(global_fd, proof, metadata)
    updates = {} if root_updates is None else dict(root_updates)
    updates["group_control_digest"] = successor["digest"].hex()
    root = _catalog_root_successor(
        global_fd, recovery_fd, proof, proof["root"][2][4096:5120],
        updates, barrier)
    _catalog_barrier("catalog-migration-group", barrier)
    return {"group_digest": successor["digest"].hex(),
            "root_digest": root["digest"].hex(), "metadata": metadata}


def _catalog_quiesce_work_image(generation: int, predecessor: bytes,
                                metadata: dict) -> bytes:
    return _catalog_image(b"ZYZMQW1", CATALOG_GROUP_IMAGE_SIZE, generation,
                          predecessor, metadata, metadata_limit=60000)


def _catalog_selected_quiesce_work(global_fd: int, root_meta: dict) -> tuple:
    expected = root_meta.get("migration_quiesce_work_digest")
    if not isinstance(expected, str) or not HEX64.fullmatch(expected):
        raise StateError("catalog-root-invalid",
                         "ROOT migration-quiesce work digest is invalid", 4)
    matches = []
    for bank in (0, 1):
        raw = _catalog_pread_exact(
            global_fd, CATALOG_GROUP_IMAGE_SIZE,
            CATALOG_LAYOUT["migration_quiesce"][0] +
            bank * CATALOG_GROUP_IMAGE_SIZE)
        if raw == bytes(CATALOG_GROUP_IMAGE_SIZE):
            continue
        try:
            parsed = _catalog_parse_image(
                raw, b"ZYZMQW1", metadata_limit=60000)
        except StateError:
            continue
        if parsed[3].hex() == expected:
            matches.append((parsed[0], bank, raw, parsed))
    if len(matches) != 1:
        raise StateError("catalog-root-invalid",
                         "migration-quiesce work selection is ambiguous", 4)
    return matches[0]


def _catalog_quiesce_work_successor(global_fd: int, proof: dict,
                                     metadata: dict) -> dict:
    selected = proof["quiesce_work"]
    successor = _catalog_quiesce_work_image(
        selected[0] + 1, selected[3][3], metadata)
    bank = 1 - selected[1]
    _catalog_pwrite_all(
        global_fd, successor,
        CATALOG_LAYOUT["migration_quiesce"][0] +
        bank * CATALOG_GROUP_IMAGE_SIZE,
        "MIGRATION_QUIESCE_WORK successor")
    _data_sync(global_fd)
    return {"bank": bank, "image": successor,
            "digest": _catalog_digest(b"zyz-pack-image-id-v1", successor),
            "metadata": metadata}


def _catalog_quiesce_work_commit(global_fd: int, recovery_fd: int,
                                  proof: dict, metadata: dict,
                                  barrier: str,
                                  root_updates: dict | None = None) -> dict:
    """Publish one work generation and select it in the same ROOT successor."""
    successor = _catalog_quiesce_work_successor(global_fd, proof, metadata)
    updates = {} if root_updates is None else dict(root_updates)
    updates["migration_quiesce_work_digest"] = successor["digest"].hex()
    root = _catalog_root_successor(
        global_fd, recovery_fd, proof, proof["root"][2][4096:5120],
        updates, barrier)
    _catalog_barrier("catalog-migration-quiesce", barrier)
    return {"work_digest": successor["digest"].hex(),
            "root_digest": root["digest"].hex(), "metadata": metadata}


def _catalog_quiesce_work_validate(value: dict) -> None:
    """Validate the bounded, pathname-free creator retirement journal."""
    required = {
        "schema_version", "state", "work_generation", "migration_generation",
        "cell_index", "cell_generation", "creator_key", "subject_digest",
        "request_bytes", "reservation_digest", "object_identities_digest",
        "commit_visibility", "objects", "delete_cursor", "deleted_count",
        "release_phase", "counter_prior", "counter_after",
    }
    if (set(value) != required or value.get("schema_version") != 1 or
            value.get("state") not in
                ("idle", "planned", "deleting", "deleted", "release-will",
                 "release-applied", "committed") or
            not isinstance(value.get("work_generation"), int) or
            value["work_generation"] < 0 or
            not isinstance(value.get("migration_generation"), int) or
            value["migration_generation"] < 0):
        raise StateError("catalog-root-invalid",
                         "MIGRATION_QUIESCE_WORK schema is invalid", 4)
    if value["state"] == "idle":
        nullable = required - {"schema_version", "state", "work_generation",
                               "migration_generation", "objects",
                               "delete_cursor", "deleted_count"}
        if (any(value[field] is not None for field in nullable) or
                value["objects"] != [] or value["delete_cursor"] != 0 or
                value["deleted_count"] != 0):
            raise StateError("catalog-root-invalid",
                             "MIGRATION_QUIESCE_WORK idle payload is invalid", 4)
        return
    if (not isinstance(value.get("cell_index"), int) or
            not 0 <= value["cell_index"] < CATALOG_CELL_COUNT or
            not isinstance(value.get("cell_generation"), int) or
            value["cell_generation"] < 1 or
            not isinstance(value.get("creator_key"), str) or
            not (KEY_RE.fullmatch(value["creator_key"]) or
                 value["creator_key"].startswith("claim.") and
                 HEX64.fullmatch(value["creator_key"][6:])) or
            not isinstance(value.get("subject_digest"), str) or
            not HEX64.fullmatch(value["subject_digest"]) or
            not isinstance(value.get("request_bytes"), int) or
            value["request_bytes"] < 1 or
            not isinstance(value.get("reservation_digest"), str) or
            not HEX64.fullmatch(value["reservation_digest"]) or
            not isinstance(value.get("object_identities_digest"), str) or
            not HEX64.fullmatch(value["object_identities_digest"])):
        raise StateError("catalog-root-invalid",
                         "MIGRATION_QUIESCE_WORK creator binding is invalid", 4)
    visibility = value.get("commit_visibility")
    if (not isinstance(visibility, dict) or
            set(visibility) != {"kind", "committed", "marker_digest"} or
            visibility.get("kind") not in ("START", "did-claim") or
            not isinstance(visibility.get("committed"), bool) or
            (visibility.get("marker_digest") is not None and
             (not isinstance(visibility["marker_digest"], str) or
              not HEX64.fullmatch(visibility["marker_digest"]))) or
            visibility["committed"] !=
                (visibility["marker_digest"] is not None)):
        raise StateError("catalog-root-invalid",
                         "MIGRATION_QUIESCE_WORK visibility is invalid", 4)
    objects = value.get("objects")
    if (not isinstance(objects, list) or not 1 <= len(objects) <= 3 or
            not isinstance(value.get("delete_cursor"), int) or
            not 0 <= value["delete_cursor"] <= len(objects) or
            value.get("deleted_count") != value["delete_cursor"]):
        raise StateError("catalog-root-invalid",
                         "MIGRATION_QUIESCE_WORK delete cursor is invalid", 4)
    names = set()
    for item in objects:
        if (not isinstance(item, dict) or
                set(item) != {"basename", "expected_size", "identity",
                              "prior", "after"} or
                not isinstance(item.get("basename"), str) or
                not re.fullmatch(r"[A-Za-z0-9._-]{1,192}", item["basename"]) or
                item["basename"] in names or
                not isinstance(item.get("expected_size"), int) or
                item["expected_size"] < 1 or item.get("prior") != "present" or
                item.get("after") != "absent" or
                not isinstance(item.get("identity"), dict)):
            raise StateError("catalog-root-invalid",
                             "MIGRATION_QUIESCE_WORK object prior is invalid", 4)
        identity = item["identity"]
        if (set(identity) != {"dev", "ino", "size", "mount_id", "digest"} or
                any(not isinstance(identity.get(field), int) or identity[field] < 0
                    for field in ("dev", "ino", "size")) or
                identity["size"] != item["expected_size"] or
                not isinstance(identity.get("mount_id"), str) or
                not identity["mount_id"] or
                not isinstance(identity.get("digest"), str) or
                not HEX64.fullmatch(identity["digest"])):
            raise StateError("catalog-root-invalid",
                             "MIGRATION_QUIESCE_WORK object identity is invalid", 4)
        names.add(item["basename"])
    if value["commit_visibility"]["committed"]:
        if (value["delete_cursor"] != 0 or value["state"] not in
                ("planned", "committed") or value.get("release_phase") is not None or
                value.get("counter_prior") is not None or
                value.get("counter_after") is not None):
            raise StateError("catalog-root-invalid",
                             "committed creator retirement state is invalid", 4)
        return
    release_phase = value.get("release_phase")
    expected_release = (None if value["state"] in
                        ("planned", "deleting", "deleted") else value["state"])
    if release_phase != expected_release:
        raise StateError("catalog-root-invalid",
                         "MIGRATION_QUIESCE_WORK RELEASE phase is invalid", 4)
    if value["state"] in ("deleted", "release-will", "release-applied", "committed") \
            and value["delete_cursor"] != len(objects):
        raise StateError("catalog-root-invalid",
                         "MIGRATION_QUIESCE_WORK deletion is incomplete", 4)
    for name in ("counter_prior", "counter_after"):
        counters = value.get(name)
        if value["state"] in ("release-will", "release-applied", "committed"):
            if (not isinstance(counters, dict) or
                    set(counters) != {"owned_bytes", "active_claims",
                                     "active_data_claims", "counter_generation"} or
                    any(not isinstance(counters[field], int) or counters[field] < 0
                        for field in counters)):
                raise StateError("catalog-root-invalid",
                                 "MIGRATION_QUIESCE_WORK counters are invalid", 4)
        elif counters is not None:
            raise StateError("catalog-root-invalid",
                             "MIGRATION_QUIESCE_WORK premature counters", 4)


def _catalog_initialize_genesis(container: Path) -> None:
    canonical = container / ".catalog-global-pack.v1"
    prepare = container / ".catalog-global-pack.prepare.v1"
    if canonical.exists():
        if prepare.exists():
            raise StateError("catalog-root-invalid", "GENESIS prepare and canonical names both exist", 4)
        return
    with os.scandir(os.fsencode(container)) as entries:
        observed_names = {os.fsdecode(entry.name) for entry in entries}
    unknown = observed_names - CATALOG_FIXED_NAMES
    if unknown:
        raise StateError("catalog-root-invalid", "unowned payload exists before GENESIS", 4)
    container_fd = os.open(os.fsencode(container), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) |
                           getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
    fds: dict[str, int] = {}
    try:
        for carrier in (".catalog-lock.v1", ".catalog-shared-source-lock.v1", ".terminal-index-lock.v1"):
            fd = _catalog_open_fixed(container_fd, carrier)
            block = max(4096, os.fstatvfs(fd).f_frsize)
            _catalog_preallocate(fd, block, carrier); _data_sync(fd); fds[carrier] = fd
        sizes = {
            ".catalog-global-pack.prepare.v1": CATALOG_GLOBAL_SIZE,
            ".catalog-recovery-pack.v1": CATALOG_RECOVERY_SIZE,
            ".terminal-audit-pack.v1": CATALOG_TERMINAL_SIZE,
            ".catalog-segment.0000000000000001.v1": CATALOG_SEGMENT_SIZE,
            ".catalog-segment.0000000000000002.v1": CATALOG_SEGMENT_SIZE,
            ".catalog-compaction-scratch.v1": CATALOG_SEGMENT_SIZE,
        }
        for name, size in sizes.items():
            fd = _catalog_open_fixed(container_fd, name)
            _catalog_preallocate(fd, size, name)
            # GENESIS owns the whole pre-commit object, so deterministic zeroing
            # is legal recovery for every partial G0..G3 state.
            chunk = bytes(1024 * 1024)
            for offset in range(0, size, len(chunk)):
                _catalog_pwrite_all(fd, chunk[:min(len(chunk), size - offset)], offset, name)
            _data_sync(fd); fds[name] = fd
        actual_allocated = sum(os.fstat(fd).st_blocks * 512 for fd in fds.values())
        if actual_allocated > CATALOG_GENESIS_FLOOR:
            raise StateError("genesis-capacity-unavailable",
                             "physically allocated GENESIS exceeds the structural floor", 4, True)
        os.fsync(container_fd)
        _catalog_barrier("catalog-genesis", "g0-fixed-names-durable")

        recovery_fd = fds[".catalog-recovery-pack.v1"]
        global_fd = fds[".catalog-global-pack.prepare.v1"]
        for index in range(CATALOG_CELL_COUNT):
            material = _catalog_free_material(index)
            cell = _catalog_recovery_free_image(index, material)
            _catalog_pwrite_all(recovery_fd, cell, index * CATALOG_RECOVERY_CELL_SIZE,
                                "recovery CELL")
            entry = _catalog_directory_free_image(index, material)
            _catalog_pwrite_all(global_fd, entry,
                                CATALOG_LAYOUT["cell_directory_a"][0] + index * CATALOG_DIRECTORY_IMAGE_SIZE,
                                "CELL_DIRECTORY")
        _data_sync(recovery_fd)
        for index in range(TERMINAL_CELL_COUNT):
            terminal_cell = _terminal_cell_image(
                index, 1, bytes(32),
                {"schema_version": 1, "cell_index": index, "state": "empty"})
            _catalog_pwrite_all(
                fds[".terminal-audit-pack.v1"], terminal_cell,
                index * TERMINAL_CELL_SIZE, "terminal empty cell")
        _data_sync(fds[".terminal-audit-pack.v1"])
        segment_descriptor_digests = {}
        for generation, name in ((1, ".catalog-segment.0000000000000001.v1"),
                                 (2, ".catalog-segment.0000000000000002.v1"),
                                 (0, ".catalog-compaction-scratch.v1")):
            image = _catalog_segment_image(generation, name)
            _catalog_pwrite_all(fds[name], image, CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL,
                                "segment descriptor")
            _data_sync(fds[name])
            segment_descriptor_digests[generation] = _catalog_digest(
                b"zyz-pack-image-id-v1", image).hex()
        _catalog_barrier("catalog-genesis", "g1-fixed-content-prepared")

        aggregates = _catalog_directory_aggregates(global_fd, recovery_fd, True)
        schedule_meta = {"schema_version": 1, "state": "UNINITIALIZED", "generation": 1,
                         "next_gc_epoch": None, "reason": "genesis"}
        schedule = _catalog_image(b"ZYZSCH1", 4096, 1, bytes(32), schedule_meta)
        _catalog_pwrite_all(global_fd, schedule, CATALOG_LAYOUT["schedule"][0], "SCHEDULE A")
        schedule_digest = _catalog_digest(b"zyz-pack-image-id-v1", schedule)
        group_meta = {"schema_version": 1, "state": "idle", "group_generation": 0,
                      "source_segment_generation": None,
                      "source_segments": [], "source_group_digest": None,
                      "scratch_basename": None,
                      "plan_scan_cursor": 0, "planned_frame_count": 0,
                      "planned_frame_bytes": 0, "planned_frame_digest": None,
                      "copy_cursor": 0, "copy_bytes": 0,
                      "scratch_identity": None, "scratch_descriptor_digest": None,
                      "cancel_count": 0, "cancel_set_digest": None,
                      "free_count": 0, "consumed_digest": None,
                      "group_visible_digest": None,
                      "retirement_cursor": 0, "retired_bytes": 0}
        group = _catalog_group_image(1, bytes(32), group_meta)
        _catalog_pwrite_all(global_fd, group, CATALOG_LAYOUT["group_control"][0],
                            "GROUP_CONTROL A")
        group_digest = _catalog_digest(b"zyz-pack-image-id-v1", group)
        quiesce_meta = {
            "schema_version": 1, "state": "idle", "work_generation": 0,
            "migration_generation": 0, "cell_index": None,
            "cell_generation": None, "creator_key": None,
            "subject_digest": None, "request_bytes": None,
            "reservation_digest": None, "object_identities_digest": None,
            "commit_visibility": None, "objects": [], "delete_cursor": 0,
            "deleted_count": 0, "release_phase": None,
            "counter_prior": None, "counter_after": None,
        }
        _catalog_quiesce_work_validate(quiesce_meta)
        quiesce_work = _catalog_quiesce_work_image(
            1, bytes(32), quiesce_meta)
        _catalog_pwrite_all(
            global_fd, quiesce_work,
            CATALOG_LAYOUT["migration_quiesce"][0],
            "MIGRATION_QUIESCE_WORK A")
        quiesce_digest = _catalog_digest(
            b"zyz-pack-image-id-v1", quiesce_work)
        chain_region, chain_digest = _catalog_chain_region(
            [_catalog_chain_range_anchor(container, 1, 1)], 1)
        root_meta = {"schema_version": 1, "state": "active", "generation": 1,
                     "schedule_bank": 0, "schedule_digest": schedule_digest.hex(),
                     "group_control_digest": group_digest.hex(),
                     "migration_quiesce_work_digest": quiesce_digest.hex(),
                     "selector_sha256": aggregates["selector_digest"].hex(),
                     "generation_vector_sha256": aggregates["generation_digest"].hex(),
                     "directory_sha256": aggregates["directory_digest"].hex(),
                     "recovery_sha256": aggregates["recovery_digest"].hex(),
                     "owned_bytes": CATALOG_GENESIS_FLOOR, "blocked_claims_known": 0,
                     "active_claims": 0, "active_data_claims": 0,
                     "discovery_cursor": 0,
                     "next_sequence": 1, "sweep_generation": 0,
                     "first_active_segment_generation": 1,
                     "active_segment_generation": 1,
                     "active_segment_used_length": 0,
                     "active_segment_descriptor_digest":
                         segment_descriptor_digests[1],
                     "active_segment_claim_count": 0,
                     "sweep_cutoff_sequence": 0, "sweep_segment_generation": 1,
                     "sweep_start_segment_generation": 1, "sweep_offset": 0,
                     "sweep_next_gc_epoch": None,
                     "claim_scan_due": False,
                     "counter_generation": 0,
                     "recovery_overlay_digest": _catalog_digest(
                         b"zyz-recovery-overlay-v1", b"").hex(),
                     "overlay_flush_cursor": 0,
                     "migration_generation": 0,
                     "admission_state": "open",
                     "migration_quiesce_intent": None,
                     "migration_creator_cutoff": None,
                     "migration_scan_cursor": 0,
                     "migration_source_chain_digest": None,
                     "migration_scratch_basename":
                         ".catalog-compaction-scratch.v1",
                     "migration_group_generation": 0,
                     "migration_copy_cursor": 0,
                     "migration_retirement_cursor": 0,
                     "hybrid_chain_digest": chain_digest,
                     "dense_capacity_signature": None}
        digest_region = (aggregates["selector_digest"] + aggregates["generation_digest"] +
                         aggregates["directory_digest"] + aggregates["recovery_digest"])
        root = _catalog_image(
            b"ZYZROOT1", CATALOG_ROOT_IMAGE_SIZE, 1, bytes(32), root_meta,
            ((4096, aggregates["selector"]),
             (CATALOG_CHAIN_OFFSET, chain_region),
             (41984, digest_region)))
        _catalog_pwrite_all(global_fd, root, CATALOG_LAYOUT["root_meta"][0], "ROOT_META A")
        _data_sync(global_fd)
        root_digest = _catalog_digest(b"zyz-pack-image-id-v1", root)
        _catalog_barrier("catalog-genesis", "g2-global-roots-prepared")

        fixed = {}
        for name, size in sizes.items():
            fixed[name] = _catalog_object_identity(container, name, size)["digest"]
        for carrier in (".catalog-lock.v1", ".catalog-shared-source-lock.v1", ".terminal-index-lock.v1"):
            fixed[carrier] = _catalog_object_identity(container, carrier, os.fstat(fds[carrier]).st_size)["digest"]
        genesis_meta = {"schema_version": 1, "state": "prepared", "generation": 1,
                        "fixed_object_digests": fixed, "schedule_digest": schedule_digest.hex(),
                        "root_digest": root_digest.hex(), "recovery_sha256": aggregates["recovery_digest"].hex(),
                        "cell_count": CATALOG_CELL_COUNT}
        genesis = _catalog_image(b"ZYZGEN1", 8192, 1, bytes(32), genesis_meta)
        _catalog_pwrite_all(global_fd, genesis, CATALOG_LAYOUT["genesis"][0], "GENESIS A")
        genesis_digest = _catalog_digest(b"zyz-pack-image-id-v1", genesis)
        header_meta = {"schema_version": 1, "state": "prepared", "pack_size": CATALOG_GLOBAL_SIZE,
                       "genesis_digest": genesis_digest.hex(), "root_digest": root_digest.hex(),
                       "schedule_digest": schedule_digest.hex()}
        header = _catalog_image(b"ZYZPACK1", 4096, 1, bytes(32), header_meta)
        _catalog_pwrite_all(global_fd, header, CATALOG_LAYOUT["pack_header"][0], "PACK_HEADER A")
        _data_sync(global_fd); os.fsync(container_fd)
        _catalog_barrier("catalog-genesis", "g3-genesis-prepared")
    finally:
        for fd in fds.values():
            try: os.close(fd)
            except OSError: pass
        os.close(container_fd)

    _catalog_rename_noreplace_unconfirmed(prepare, canonical)
    _catalog_barrier("catalog-genesis", "g4-canonical-visible-unconfirmed")
    fsync_dir(container)
    _catalog_barrier("catalog-genesis", "g4-canonical-durable")


def _catalog_validate_genesis(container: Path) -> dict:
    canonical = container / ".catalog-global-pack.v1"
    prepare = container / ".catalog-global-pack.prepare.v1"
    if prepare.exists() or not canonical.exists():
        raise StateError("catalog-root-invalid", "GENESIS canonical prior/after set is invalid", 4)
    # Every opener establishes its own lock-held durability proof.
    fsync_dir(container)
    global_fd = os.open(os.fsencode(canonical), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    recovery_fd = os.open(os.fsencode(container / ".catalog-recovery-pack.v1"),
                          os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        if os.fstat(global_fd).st_size != CATALOG_GLOBAL_SIZE or os.fstat(recovery_fd).st_size != CATALOG_RECOVERY_SIZE:
            raise StateError("catalog-root-invalid", "catalog fixed pack size is invalid", 4)
        header = _catalog_select_ab(global_fd, CATALOG_LAYOUT["pack_header"][0], 4096, b"ZYZPACK1")
        genesis = _catalog_select_ab(global_fd, CATALOG_LAYOUT["genesis"][0], 8192, b"ZYZGEN1")
        root = _catalog_select_ab(global_fd, CATALOG_LAYOUT["root_meta"][0], CATALOG_ROOT_IMAGE_SIZE,
                                  b"ZYZROOT1")
        root_meta = root[3][2]
        schedule_bank = root_meta.get("schedule_bank")
        if schedule_bank not in (0, 1):
            raise StateError("catalog-root-invalid", "ROOT schedule selector is invalid", 4)
        schedule_raw = _catalog_pread_exact(global_fd, 4096,
                                            CATALOG_LAYOUT["schedule"][0] + schedule_bank * 4096)
        schedule = _catalog_parse_image(schedule_raw, b"ZYZSCH1", _catalog_schedule_semantic)
        if schedule[3].hex() != root_meta.get("schedule_digest"):
            raise StateError("catalog-root-invalid", "ROOT/SCHEDULE digest mismatch", 4)
        schedule_meta = schedule[2]
        if schedule_meta.get("state") not in ("UNINITIALIZED", "SCHEDULED"):
            raise StateError("catalog-root-invalid", "SCHEDULE state is invalid", 4)
        group = _catalog_selected_group(global_fd, root_meta)
        group_meta = group[3][2]
        if (group_meta.get("schema_version") != 1 or group_meta.get("state") not in
                ("idle", "new-source-initialized", "planning", "group-planned",
                 "copy-will", "copying", "copied", "cutover-will",
                 "folding", "group-visible",
                 "freeing", "previs-cells-consumed", "next-scratch-will",
                 "next-scratch-ready", "retired-delete-will",
                 "old-source-retired", "group-committed") or
                not isinstance(group_meta.get("group_generation"), int) or
                group_meta["group_generation"] < 0):
            raise StateError("catalog-root-invalid", "GROUP_CONTROL state is invalid", 4)
        quiesce_work = _catalog_selected_quiesce_work(global_fd, root_meta)
        quiesce_meta = quiesce_work[3][2]
        _catalog_quiesce_work_validate(quiesce_meta)
        root_raw = root[2]
        selector = root_raw[4096:5120]
        aggregates = _catalog_directory_aggregates(
            global_fd, recovery_fd, True, selector)
        append_will = _catalog_pending_append_will(root_meta, aggregates)
        chain = _catalog_parse_chain_region(
            container, root_raw[CATALOG_CHAIN_OFFSET:
                                CATALOG_CHAIN_OFFSET + CATALOG_CHAIN_SIZE],
            append_will)
        if chain["digest"] != root_meta.get("hybrid_chain_digest"):
            raise StateError("catalog-root-invalid", "ROOT hybrid-chain digest mismatch", 4)
        # A stale but structurally valid signature is a normal input change;
        # malformed signature material is catalog corruption.
        _catalog_dense_signature_matches(root_meta)
        member_generations = [value["generation"] for value in chain["members"]]
        first_active = root_meta.get("first_active_segment_generation")
        active = root_meta.get("active_segment_generation")
        if (not isinstance(first_active, int) or first_active < 1 or
                not isinstance(active, int) or active < first_active or
                not member_generations or member_generations[0] != first_active or
                member_generations[-1] != active or
                len(member_generations) != len(set(member_generations))):
            raise StateError("catalog-root-invalid", "ROOT hybrid-chain range conflicts", 4)
        active_projection = chain["members"][-1]
        if (active_projection["descriptor_digest"] ==
                root_meta.get("active_segment_descriptor_digest") and
                active_projection["used_length"] ==
                root_meta.get("active_segment_used_length")):
            active_matches = True
        else:
            active_matches = bool(
                append_will is not None and
                append_will["segment_generation"] == active and
                append_will["frame_offset"] ==
                    root_meta.get("active_segment_used_length") and
                active_projection["descriptor_predecessor"] ==
                    root_meta.get("active_segment_descriptor_digest") and
                active_projection["used_length"] ==
                    append_will["frame_offset"] + append_will["frame_length"])
        if not active_matches:
            raise StateError("catalog-root-invalid",
                             "ROOT active segment anchor conflicts", 4)
        expected = {"selector_sha256": aggregates["selector_digest"].hex(),
                    "generation_vector_sha256": aggregates["generation_digest"].hex(),
                    "directory_sha256": aggregates["directory_digest"].hex(),
                    "recovery_sha256": aggregates["recovery_digest"].hex()}
        if any(root_meta.get(key) != value for key, value in expected.items()):
            raise StateError("catalog-root-invalid", "ROOT directory/recovery aggregate mismatch", 4)
        if (root_raw[4096:5120] != aggregates["selector"] or
                root_raw[46080:] != bytes(19456)):
            raise StateError("catalog-root-invalid", "ROOT_META fixed partitions are invalid", 4)
        if _catalog_pread_exact(global_fd, CATALOG_GLOBAL_SIZE - CATALOG_LAYOUT["reserved_headroom"][0],
                                CATALOG_LAYOUT["reserved_headroom"][0]) != bytes(
                                    CATALOG_GLOBAL_SIZE - CATALOG_LAYOUT["reserved_headroom"][0]):
            raise StateError("catalog-root-invalid", "catalog reserved headroom is nonzero", 4)
        if header[3][2].get("genesis_digest") != genesis[3][3].hex():
            raise StateError("catalog-root-invalid", "PACK_HEADER references are invalid", 4)
        terminal_fd = os.open(os.fsencode(container / ".terminal-audit-pack.v1"),
                              os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            if os.fstat(terminal_fd).st_size != CATALOG_TERMINAL_SIZE:
                raise StateError("catalog-root-invalid", "terminal pack size is invalid", 4)
            for index in range(TERMINAL_CELL_COUNT):
                _terminal_selected_cell(terminal_fd, index)
        finally: os.close(terminal_fd)
        return {"global_fd": global_fd, "root": root, "root_meta": root_meta,
                "schedule": schedule, "schedule_meta": schedule_meta,
                "group": group, "group_meta": group_meta,
                "quiesce_work": quiesce_work,
                "quiesce_work_meta": quiesce_meta,
                "chain": chain, "aggregates": aggregates,
                "pending_append_will": append_will}
    except Exception:
        os.close(global_fd)
        raise
    finally:
        os.close(recovery_fd)


def _catalog_schedule_semantic(value: dict) -> None:
    common = {"schema_version", "state", "generation"}
    if (value.get("schema_version") != 1 or value.get("state") not in
            ("UNINITIALIZED", "SCHEDULED") or
            not isinstance(value.get("generation"), int) or value["generation"] < 1):
        raise StateError("catalog-root-invalid", "SCHEDULE semantic state is invalid", 4)
    if value["state"] == "UNINITIALIZED":
        if (set(value) != common | {"next_gc_epoch", "reason"} or
                value.get("next_gc_epoch") is not None or value.get("reason") != "genesis" or
                value["generation"] != 1):
            raise StateError("catalog-root-invalid", "SCHEDULE UNINITIALIZED payload is invalid", 4)
        return
    required = common | {"next_gc_epoch", "reason", "committed_epoch", "source_root_digest"}
    if (set(value) != required or value.get("reason") not in
            ("completed-pass", "ttl-recheck", "retry", "cadence") or
            not isinstance(value.get("committed_epoch"), int) or value["committed_epoch"] < 0 or
            not isinstance(value.get("next_gc_epoch"), int) or
            value["next_gc_epoch"] <= value["committed_epoch"] or
            value["next_gc_epoch"] > 2147483647 or
            not isinstance(value.get("source_root_digest"), str) or
            not HEX64.fullmatch(value["source_root_digest"])):
        raise StateError("catalog-root-invalid", "SCHEDULED payload is invalid", 4)


def ensure_catalog_genesis(task: str, validate: bool = True) -> tuple[Path, dict | None]:
    runtime = _catalog_runtime(task)
    _catalog_rename_capability()
    try:
        _catalog_mount_identity(runtime)
        container = _catalog_container(runtime, True)
    except StateError as exc:
        if exc.code == "catalog-lock-capability-unavailable":
            raise StateError("genesis-capability-unavailable", exc.message, 4, True)
        raise
    # Bootstrap carrier creation precedes the first flock, but content and all
    # dynamic admission remain behind the persistent carrier lock.
    lock_path = container / ".catalog-lock.v1"
    if not lock_path.exists():
        container_fd = os.open(os.fsencode(container), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            fd = _catalog_open_fixed(container_fd, ".catalog-lock.v1")
            block = max(4096, os.fstatvfs(fd).f_frsize)
            _catalog_preallocate(fd, block, ".catalog-lock.v1"); _data_sync(fd); os.close(fd)
            os.fsync(container_fd)
        finally: os.close(container_fd)
    with CatalogFlock(container):
        _catalog_initialize_genesis(container)
        if not validate:
            return container, None
        proof = _catalog_validate_genesis(container)
        os.close(proof.pop("global_fd"))
    return container, proof


def _catalog_main_heartbeat(task: str, agent_type: str) -> None:
    """Commit main-agent liveness in the fixed PACK_HEADER A/B record.

    Main has no dynamic instance namespace. Reusing the permanent catalog pack
    keeps its heartbeat bounded and removes the last new-format standalone
    control inode. The write is deliberately fail-closed internally; the hook
    wrapper converts every failure to host fail-open behavior.
    """
    if len(raw_bytes(agent_type)) > 128:
        return
    container, _ = ensure_catalog_genesis(task)
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        os.close(proof.pop("global_fd"))
        global_fd = os.open(
            os.fsencode(container / ".catalog-global-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            header = _catalog_select_ab(
                global_fd, CATALOG_LAYOUT["pack_header"][0], 4096,
                b"ZYZPACK1")
            metadata = dict(header[3][2])
            epoch = int(time.time())
            if not 0 <= epoch <= 2147483647:
                raise StateError("invalid-schema", "main heartbeat epoch is invalid", 4)
            metadata.update(main_heartbeat_epoch=epoch,
                            main_agent_type=(agent_type or "main")[:128])
            successor = _catalog_image(
                b"ZYZPACK1", 4096, header[0] + 1, header[3][3], metadata)
            bank = 1 - header[1]
            _catalog_pwrite_all(
                global_fd, successor,
                CATALOG_LAYOUT["pack_header"][0] + bank * 4096,
                "main HEARTBEAT successor")
            _data_sync(global_fd)
        finally:
            os.close(global_fd)


def hook_main_heartbeat(task: str, agent_type: str) -> None:
    try:
        _catalog_main_heartbeat(task, agent_type)
    except Exception:
        return


def _catalog_selected_entry(global_fd: int, selector: bytes, index: int) -> tuple[int, bytes, dict]:
    bank = _catalog_selector_bank(selector, index)
    base = CATALOG_LAYOUT["cell_directory_a"][0] if bank == 0 else CATALOG_LAYOUT["cell_directory_b"][0]
    raw = _catalog_pread_exact(global_fd, CATALOG_DIRECTORY_IMAGE_SIZE,
                               base + index * CATALOG_DIRECTORY_IMAGE_SIZE)
    return bank, raw, _catalog_parse_directory_image(raw, index)


def _catalog_selected_recovery(recovery_fd: int, entry: dict, index: int) -> tuple[int, bytes, dict]:
    matches = []
    for bank in (0, 1):
        raw = _catalog_pread_exact(recovery_fd, CATALOG_RECOVERY_IMAGE_SIZE,
                                   index * CATALOG_RECOVERY_CELL_SIZE + bank * CATALOG_RECOVERY_IMAGE_SIZE)
        if raw == bytes(CATALOG_RECOVERY_IMAGE_SIZE): continue
        try: parsed = _catalog_parse_recovery_image(raw, index)
        except StateError: continue
        if (parsed["generation"] == entry["cell_generation"] and
                hmac.compare_digest(parsed["digest"], entry["fields"][1])):
            matches.append((bank, raw, parsed))
    if len(matches) != 1:
        raise StateError("catalog-root-invalid", "selected recovery CELL is ambiguous", 4)
    return matches[0]


def _catalog_root_successor(global_fd: int, recovery_fd: int, proof: dict,
                            selector: bytes, updates: dict, barrier: str,
                            chain_region: bytes | None = None) -> dict:
    root = proof["root"]
    aggregates = _catalog_directory_aggregates(global_fd, recovery_fd, True, selector)
    meta = dict(proof["root_meta"])
    meta.update(updates)
    _catalog_pending_append_will(meta, aggregates)
    if chain_region is not None:
        # Validate the caller-provided fixed layout before it can become ROOT
        # authority.  Object validation is performed by the next catalog open.
        if len(chain_region) != CATALOG_CHAIN_SIZE:
            raise StateError("gc-internal", "hybrid-chain successor size is invalid", 5)
        header = _catalog_parse_image(
            chain_region[:CATALOG_CHAIN_PARTITIONS[0]], b"ZYZHCN1")
        trailer = _catalog_parse_image(
            chain_region[-CATALOG_CHAIN_PARTITIONS[2]:], b"ZYZHCT1")
        if (header[0] != trailer[0] or
                not HEX64.fullmatch(str(trailer[2].get("hybrid_chain_digest")))):
            raise StateError("gc-internal", "hybrid-chain successor is invalid", 5)
        meta["hybrid_chain_digest"] = trailer[2]["hybrid_chain_digest"]
    meta.update(generation=root[0] + 1,
                selector_sha256=aggregates["selector_digest"].hex(),
                generation_vector_sha256=aggregates["generation_digest"].hex(),
                directory_sha256=aggregates["directory_digest"].hex(),
                recovery_sha256=aggregates["recovery_digest"].hex())
    tail = bytearray(root[2][4096:])
    tail[0:1024] = selector
    if chain_region is not None:
        chain_start = CATALOG_CHAIN_OFFSET - 4096
        tail[chain_start:chain_start + CATALOG_CHAIN_SIZE] = chain_region
    digest_offset = 41984 - 4096
    digest_region = (aggregates["selector_digest"] + aggregates["generation_digest"] +
                     aggregates["directory_digest"] + aggregates["recovery_digest"])
    tail[digest_offset:digest_offset + len(digest_region)] = digest_region
    successor = _catalog_image(b"ZYZROOT1", CATALOG_ROOT_IMAGE_SIZE, root[0] + 1,
                               root[3][3], meta, ((4096, bytes(tail)),))
    bank = 1 - root[1]
    _catalog_pwrite_all(global_fd, successor,
                        CATALOG_LAYOUT["root_meta"][0] + bank * CATALOG_ROOT_IMAGE_SIZE,
                        "ROOT_META successor")
    _data_sync(global_fd)
    _catalog_barrier("catalog-root", barrier)
    return {"bank": bank, "image": successor,
            "digest": _catalog_digest(b"zyz-pack-image-id-v1", successor),
            "metadata": meta, "aggregates": aggregates}


def _catalog_instance_subject(key: str) -> bytes:
    return _catalog_digest(b"zyz-instance-owner-key-v1", key.encode("ascii"))


def _catalog_instance_object_set(key: str, request: int) -> dict:
    if key.startswith("claim.") and HEX64.fullmatch(key[6:]):
        return {"claim": f"{key[6:]}.claim-pack.v1", "claim_size": CLAIM_PACK_SIZE,
                "request_bytes": request}
    return {"audit": f"{key}.audit-pack.v1", "audit_size": INSTANCE_AUDIT_SIZE,
            "work": f"{key}.work-pack.v1", "work_size": INSTANCE_WORK_SIZE,
            "lock": f"{key}.lock.v1", "request_bytes": request}


def _catalog_find_instance_cell(global_fd: int, proof: dict, key: str) -> tuple[int | None, int | None]:
    selector = proof["root"][2][4096:5120]
    subject = _catalog_instance_subject(key)
    duplicate = None
    free = None
    start = proof["root_meta"].get("discovery_cursor", 0) % CATALOG_CELL_COUNT
    for step in range(CATALOG_CELL_COUNT):
        index = (start + step) % CATALOG_CELL_COUNT
        _, _, entry = _catalog_selected_entry(global_fd, selector, index)
        if entry["state"] == 0 and free is None:
            free = index
        elif entry["fields"][0] == subject:
            duplicate = index
            break
    return duplicate, free


def _catalog_capacity_gate(root: dict, request: int, config: dict,
                           terminal_applicable: bool = True) -> None:
    if root.get("state") in ("will-migration-quiesce", "migration-quiescing",
                             "migration-active", "will-migration-finish",
                             "migration-committed"):
        raise StateError("catalog-migration-pressure", "catalog migration has closed admission", 4, True)
    if _catalog_dense_signature_matches(root):
        raise StateError("catalog-capacity-pressure", "catalog is densely occupied", 4, True)
    if (root.get("admission_state") == "closed" and
            root.get("dense_capacity_signature") is None):
        raise StateError("catalog-root-invalid",
                         "catalog admission is closed without an owner", 4)
    owned = root.get("owned_bytes")
    if not isinstance(owned, int) or owned < 0 or request < 0 or owned > 2147483647 - request:
        raise StateError("storage-pressure", "owned-byte addition is invalid", 4, True)
    hard = config["ZYZ_SNAPSHOT_GC_HARD_WATER_BYTES"]
    high = config["ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES"]
    if owned >= hard or owned + request >= hard:
        raise StateError("storage-pressure", "hard-water storage pressure", 4, True)
    if owned >= high:
        raise StateError("catalog-high-water-pressure", "catalog high-water pressure", 4, True)
    # Terminal and recovery saturation are checked by their concrete allocators
    # after the byte gates, preserving the closed-set priority.


def _catalog_reserve_instance(container: Path, key: str, request: int,
                              config: dict, event: dict) -> dict:
    if not key.startswith("claim."):
        # Preserve the documented capacity priority without nesting catalog and
        # terminal locks: first prove this is a fresh owner and pass the
        # migration/dense/hard/high gates, then prepare one bounded terminal
        # slot, then reacquire catalog below and repeat every mutable check.
        fresh = False
        with CatalogFlock(container):
            preflight = _catalog_validate_genesis(container)
            preflight_fd = preflight.pop("global_fd")
            try:
                duplicate, _ = _catalog_find_instance_cell(
                    preflight_fd, preflight, key)
                if duplicate is None:
                    _catalog_capacity_gate(
                        preflight["root_meta"], request, config, True)
                    fresh = True
            finally:
                os.close(preflight_fd)
        if fresh:
            _terminal_prepare_admission(container, int(time.time()))
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_read = proof.pop("global_fd")
        os.close(global_read)
        global_fd = os.open(os.fsencode(container / ".catalog-global-pack.v1"), os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(os.fsencode(container / ".catalog-recovery-pack.v1"), os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            object_set = _catalog_instance_object_set(key, request)
            reservation_digest = _catalog_digest(
                b"zyz-instance-reservation-v1",
                _catalog_json({"object_set": object_set, "event_identity": event}))
            duplicate, index = _catalog_find_instance_cell(global_fd, proof, key)
            if duplicate is not None:
                index = duplicate
                selector = proof["root"][2][4096:5120]
                entry_bank, _, entry = _catalog_selected_entry(global_fd, selector, index)
                recovery_bank, _, recovery = _catalog_selected_recovery(recovery_fd, entry, index)
                payload = recovery["payload"]
                if (entry["fields"][0] != _catalog_instance_subject(key) or
                        payload.get("subject_digest") != entry["fields"][0].hex() or
                        payload.get("reservation_digest") != entry["fields"][2].hex()):
                    raise StateError("identity-conflict", "instance reservation identity conflicts", 4)
                if (entry["state"] == 1 and recovery["state"] == 1 and
                        payload.get("state") == "RESERVED"):
                    resume_state = "reserved"
                elif (entry["state"] in (2, 3) and recovery["state"] in (2, 3, 4, 5, 6) and
                      payload.get("state") in ("OWNER_ACTIVE", "ACTIVE_ACK", "DELTA_WILL",
                                               "DELTA_APPLIED", "FLUSH_ACKED")):
                    resume_state = ("owner-active" if payload["state"] == "OWNER_ACTIVE"
                                    else "active-ack")
                else:
                    raise StateError("catalog-root-invalid",
                                     "instance reservation is not resumable", 4)
                return {"cell_index": index, "cell_generation": entry["cell_generation"],
                        "recovery_bank": recovery_bank, "directory_bank": entry_bank,
                        "reservation_digest": entry["fields"][2].hex(),
                        "subject_digest": entry["fields"][0].hex(),
                        "object_set": object_set, "root_digest": proof["root"][3][3].hex(),
                        "resume_state": resume_state,
                        "object_identities_digest": payload.get("object_identities_digest"),
                        "event_matches": hmac.compare_digest(
                            entry["fields"][2], reservation_digest)}
            if index is None:
                raise StateError("recovery-capacity-pressure", "catalog recovery cells are full", 4, True)
            selector = proof["root"][2][4096:5120]
            entry_bank, entry_raw, entry = _catalog_selected_entry(global_fd, selector, index)
            recovery_bank, _, recovery = _catalog_selected_recovery(recovery_fd, entry, index)
            subject = _catalog_instance_subject(key)
            payload = {"schema": 1, "state": "RESERVED",
                       "subject_digest": subject.hex(),
                       "reservation_digest": reservation_digest.hex(),
                       "object_identities_digest": None,
                       "consumed_free_receipt_record_digest": entry["fields"][2].hex(),
                       "_operation_region":
                           _catalog_recovery_creator_region(key, request)}
            next_recovery = _catalog_recovery_dynamic_image(index, 1,
                                                            recovery["generation"] + 1, payload)
            next_recovery_digest = _catalog_digest(b"zyz-recovery-cell-selected-v1", next_recovery)
            target_recovery_bank = 1 - recovery_bank
            directory = _catalog_directory_image(
                index, 1, recovery["generation"] + 1, entry["free_generation"],
                (subject, next_recovery_digest, reservation_digest, entry["fields"][2],
                 _catalog_digest(b"zyz-root-will-cell-reserve-v1", subject + reservation_digest)))
            target_entry_bank = 1 - entry_bank
            target_base = (CATALOG_LAYOUT["cell_directory_a"][0] if target_entry_bank == 0
                           else CATALOG_LAYOUT["cell_directory_b"][0])

            # A crash may leave the exact reservation in the unselected CELL,
            # and possibly its unselected directory image, before ROOT makes it
            # visible.  Inspect that prior before any capacity check or write:
            # the same event must resume it, while a fresh event must not erase
            # the only durable evidence of the old reservation.
            recovery_offset = (index * CATALOG_RECOVERY_CELL_SIZE +
                               target_recovery_bank * CATALOG_RECOVERY_IMAGE_SIZE)
            inactive_recovery_raw = _catalog_pread_exact(
                recovery_fd, CATALOG_RECOVERY_IMAGE_SIZE, recovery_offset)
            prepared = inactive_recovery_raw == next_recovery
            if not prepared and inactive_recovery_raw != bytes(CATALOG_RECOVERY_IMAGE_SIZE):
                inactive_recovery = _catalog_parse_recovery_image(inactive_recovery_raw, index)
                if inactive_recovery["generation"] >= recovery["generation"] + 1:
                    inactive_payload = inactive_recovery["payload"]
                    if (inactive_recovery["state"] == 1 and
                            inactive_recovery["generation"] == recovery["generation"] + 1 and
                            inactive_payload.get("subject_digest") == subject.hex() and
                            inactive_payload.get("consumed_free_receipt_record_digest") ==
                                entry["fields"][2].hex()):
                        raise StateError("identity-conflict",
                                         "fresh event conflicts with an uncommitted reservation", 4)
                    raise StateError("catalog-root-invalid",
                                     "unselected recovery reservation conflicts", 4)

            directory_offset = target_base + index * CATALOG_DIRECTORY_IMAGE_SIZE
            inactive_directory_raw = _catalog_pread_exact(
                global_fd, CATALOG_DIRECTORY_IMAGE_SIZE, directory_offset)
            directory_prepared = inactive_directory_raw == directory
            if (prepared and not directory_prepared and
                    inactive_directory_raw != bytes(CATALOG_DIRECTORY_IMAGE_SIZE)):
                inactive_directory = _catalog_parse_directory_image(
                    inactive_directory_raw, index)
                if inactive_directory["cell_generation"] >= recovery["generation"] + 1:
                    raise StateError("catalog-root-invalid",
                                     "unselected reservation directory conflicts", 4)

            if not prepared:
                _catalog_capacity_gate(proof["root_meta"], request, config, True)
                _catalog_pwrite_all(recovery_fd, next_recovery, recovery_offset,
                                    "reserved recovery CELL")
                _data_sync(recovery_fd)
                _catalog_barrier("catalog-recovery", "cell-reserved")
            if not directory_prepared:
                _catalog_pwrite_all(global_fd, directory, directory_offset,
                                    "reserved CELL_DIRECTORY")
                _data_sync(global_fd)
                _catalog_barrier("catalog-root", "cell-inactive-durable")
            selector = _catalog_selector_set(selector, index, target_entry_bank)
            successor = _catalog_root_successor(
                global_fd, recovery_fd, proof, selector,
                {"discovery_cursor": (index + 1) % CATALOG_CELL_COUNT},
                "root-successor-durable")
            return {"cell_index": index, "cell_generation": recovery["generation"] + 1,
                    "recovery_bank": target_recovery_bank, "directory_bank": target_entry_bank,
                    "reservation_digest": reservation_digest.hex(), "subject_digest": subject.hex(),
                    "object_set": object_set, "root_digest": successor["digest"].hex(),
                    "resume_state": "reserved", "event_matches": True}
        finally:
            os.close(global_fd); os.close(recovery_fd)


def _instance_create_reserved_objects(container: Path, key: str, reservation: dict) -> dict:
    container_fd = os.open(os.fsencode(container), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) |
                           getattr(os, "O_NOFOLLOW", 0))
    fds = {}
    try:
        claim_name = reservation["object_set"].get("claim")
        if claim_name is not None:
            if (claim_name != f"{key[6:]}.claim-pack.v1" or
                    reservation["object_set"].get("claim_size") != CLAIM_PACK_SIZE):
                raise StateError("catalog-root-invalid", "claim reservation object set is invalid", 4)
            fd = _catalog_open_fixed(container_fd, claim_name)
            _catalog_preallocate(fd, CLAIM_PACK_SIZE, claim_name)
            _catalog_pwrite_all(fd, bytes(CLAIM_PACK_SIZE), 0, claim_name)
            _instance_pack_initialize(fd, "claim", key[6:])
            _data_sync(fd); fds[claim_name] = fd
            os.fsync(container_fd)
            observed = os.fstat(fd)
            value = {"dev": observed.st_dev, "ino": observed.st_ino,
                     "size": observed.st_size,
                     "mount_id": _catalog_mount_identity(container / claim_name)}
            return {claim_name: {**value, "digest": hashlib.sha256(
                _catalog_json(value)).hexdigest()}}
        for kind, size in (("audit", INSTANCE_AUDIT_SIZE), ("work", INSTANCE_WORK_SIZE)):
            name = reservation["object_set"][kind]
            fd = _catalog_open_fixed(container_fd, name)
            _catalog_preallocate(fd, size, name)
            zero = bytes(1024 * 1024)
            _catalog_pwrite_all(fd, zero[:size], 0, name)
            _instance_pack_initialize(fd, kind, key)
            _data_sync(fd); fds[name] = fd
        lock_name = reservation["object_set"]["lock"]
        lock_fd = _catalog_open_fixed(container_fd, lock_name)
        block = max(4096, os.fstatvfs(lock_fd).f_frsize)
        _catalog_preallocate(lock_fd, block, lock_name); _data_sync(lock_fd); fds[lock_name] = lock_fd
        os.fsync(container_fd)
        identities = {}
        for name, fd in fds.items():
            observed = os.fstat(fd)
            value = {"dev": observed.st_dev, "ino": observed.st_ino,
                     "size": observed.st_size,
                     "mount_id": _catalog_mount_identity(container / name)}
            identities[name] = {**value, "digest": hashlib.sha256(_catalog_json(value)).hexdigest()}
        return identities
    finally:
        for fd in fds.values():
            try: os.close(fd)
            except OSError: pass
        os.close(container_fd)


def _instance_validate_reserved_objects(container: Path, reservation: dict,
                                        expected_digest: str) -> dict:
    object_set = reservation["object_set"]
    claim_name = object_set.get("claim")
    if claim_name is not None:
        if object_set.get("claim_size") != CLAIM_PACK_SIZE:
            raise StateError("catalog-root-invalid", "claim pack reservation is invalid", 4)
        identities = {claim_name: _catalog_object_identity(
            container, claim_name, CLAIM_PACK_SIZE)}
        observed_digest = _catalog_digest(
            b"zyz-instance-object-identities-v1", _catalog_json(identities)).hex()
        if not hmac.compare_digest(observed_digest, expected_digest):
            raise StateError("catalog-root-invalid", "claim pack identity changed", 4)
        return identities
    lock_size = object_set["request_bytes"] - INSTANCE_AUDIT_SIZE - INSTANCE_WORK_SIZE
    if lock_size < 1:
        raise StateError("catalog-root-invalid", "instance lock reservation is invalid", 4)
    identities = {}
    for kind, size in (("audit", INSTANCE_AUDIT_SIZE), ("work", INSTANCE_WORK_SIZE)):
        name = object_set[kind]
        identities[name] = _catalog_object_identity(container, name, size)
    lock_name = object_set["lock"]
    identities[lock_name] = _catalog_object_identity(container, lock_name, lock_size)
    observed_digest = _catalog_digest(
        b"zyz-instance-object-identities-v1", _catalog_json(identities)).hex()
    if not hmac.compare_digest(observed_digest, expected_digest):
        raise StateError("catalog-root-invalid", "instance object identities changed", 4)
    return identities


def _catalog_instance_cell_transition(container: Path, key: str, reservation: dict,
                                      phase: str, identities: dict | None = None,
                                      account: bool = False) -> dict:
    state_number = 2 if phase == "owner-active" else 3
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        os.close(proof.pop("global_fd"))
        global_fd = os.open(os.fsencode(container / ".catalog-global-pack.v1"), os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(os.fsencode(container / ".catalog-recovery-pack.v1"), os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            index = reservation["cell_index"]
            selector = proof["root"][2][4096:5120]
            entry_bank, _, entry = _catalog_selected_entry(global_fd, selector, index)
            recovery_bank, _, recovery = _catalog_selected_recovery(recovery_fd, entry, index)
            if (entry["fields"][0].hex() != reservation["subject_digest"] or
                    recovery["payload"].get("reservation_digest") != reservation["reservation_digest"] or
                    recovery["payload"].get("subject_digest") != reservation["subject_digest"]):
                raise StateError("catalog-root-invalid", "instance reservation changed", 4)
            if phase == "owner-active":
                if entry["state"] != 1 or recovery["payload"].get("state") != "RESERVED" or not identities:
                    raise StateError("catalog-root-invalid", "instance reservation is not activatable", 4)
                identities_digest = _catalog_digest(b"zyz-instance-object-identities-v1",
                                                    _catalog_json(identities)).hex()
                payload = {"schema": 1, "state": "OWNER_ACTIVE",
                           "subject_digest": reservation["subject_digest"],
                           "reservation_digest": reservation["reservation_digest"],
                           "object_identities_digest": identities_digest,
                           "consumed_free_receipt_record_digest": entry["fields"][3].hex(),
                           "_operation_region": recovery["payload"].get(
                               "_operation_region", bytes(272))}
            elif phase == "cell-active-ack":
                if entry["state"] != 2 or recovery["payload"].get("state") != "OWNER_ACTIVE":
                    raise StateError("catalog-root-invalid", "instance owner is not ackable", 4)
                payload = dict(recovery["payload"], state="ACTIVE_ACK")
            else:
                raise StateError("gc-internal", "unknown instance cell transition", 1)
            next_generation = recovery["generation"] + 1
            next_recovery = _catalog_recovery_dynamic_image(index, state_number, next_generation, payload)
            next_recovery_digest = _catalog_digest(b"zyz-recovery-cell-selected-v1", next_recovery)
            next_recovery_bank = 1 - recovery_bank
            _catalog_pwrite_all(recovery_fd, next_recovery,
                                index * CATALOG_RECOVERY_CELL_SIZE +
                                next_recovery_bank * CATALOG_RECOVERY_IMAGE_SIZE,
                                f"instance {phase} recovery CELL")
            _data_sync(recovery_fd)
            object_digest = bytes.fromhex(payload["object_identities_digest"])
            directory = _catalog_directory_image(
                index, 2, next_generation, entry["free_generation"],
                (bytes.fromhex(reservation["subject_digest"]), next_recovery_digest,
                 bytes.fromhex(reservation["reservation_digest"]), entry["fields"][3], object_digest))
            next_entry_bank = 1 - entry_bank
            base = (CATALOG_LAYOUT["cell_directory_a"][0] if next_entry_bank == 0
                    else CATALOG_LAYOUT["cell_directory_b"][0])
            _catalog_pwrite_all(global_fd, directory,
                                base + index * CATALOG_DIRECTORY_IMAGE_SIZE,
                                f"instance {phase} CELL_DIRECTORY")
            _data_sync(global_fd)
            selector = _catalog_selector_set(selector, index, next_entry_bank)
            root_updates = {}
            if account:
                request = reservation["object_set"]["request_bytes"]
                owned = proof["root_meta"]["owned_bytes"]
                counter_generation = proof["root_meta"].get("counter_generation")
                if owned > 2147483647 - request:
                    raise StateError("catalog-root-invalid", "instance accounting overflow", 4)
                if (not isinstance(counter_generation, int) or
                        isinstance(counter_generation, bool) or
                        not 0 <= counter_generation < 2147483647):
                    raise StateError("catalog-root-invalid",
                                     "instance counter generation is invalid", 4)
                root_updates = {"owned_bytes": owned + request,
                                "active_claims": proof["root_meta"]["active_claims"] + 1,
                                "counter_generation": counter_generation + 1}
                if key.startswith("claim."):
                    active_data = proof["root_meta"].get("active_data_claims")
                    if not isinstance(active_data, int) or active_data < 0:
                        raise StateError("catalog-root-invalid",
                                         "active data-claim counter is invalid", 4)
                    root_updates["active_data_claims"] = active_data + 1
            successor = _catalog_root_successor(global_fd, recovery_fd, proof, selector,
                                                root_updates, "root-successor-durable")
            _catalog_barrier("catalog-recovery", phase)
            return {**reservation, "cell_generation": next_generation,
                    "recovery_bank": next_recovery_bank, "directory_bank": next_entry_bank,
                    "root_digest": successor["digest"].hex(),
                    "resume_state": ("owner-active" if phase == "owner-active" else "active-ack"),
                    "object_identities_digest": payload["object_identities_digest"]}
        finally:
            os.close(global_fd); os.close(recovery_fd)


def _catalog_instance_delta(container: Path, key: str, kind: str,
                            delta: int) -> dict:
    """Commit one fixed SETTLE/RELEASE overlay delta, then acknowledge it."""
    if kind not in ("SETTLE", "RELEASE") or delta >= 0:
        raise StateError("gc-internal", "invalid instance recovery delta", 5)
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        os.close(proof.pop("global_fd"))
        global_fd = os.open(os.fsencode(container / ".catalog-global-pack.v1"),
                            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(os.fsencode(container / ".catalog-recovery-pack.v1"),
                              os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            duplicate, _ = _catalog_find_instance_cell(global_fd, proof, key)
            if duplicate is None:
                raise StateError("catalog-root-invalid", "instance owner mapping is absent", 4)
            index = duplicate
            selector = proof["root"][2][4096:5120]
            entry_bank, _, entry = _catalog_selected_entry(global_fd, selector, index)
            recovery_bank, _, recovery = _catalog_selected_recovery(recovery_fd, entry, index)
            payload = recovery["payload"]
            if (entry["state"] not in (2, 3) or
                    payload.get("subject_digest") != _catalog_instance_subject(key).hex()):
                raise StateError("catalog-root-invalid", "instance owner mapping is invalid", 4)
            existing = payload.get("_operations", {}).get(kind)
            if existing is not None:
                if existing.get("delta") != delta:
                    raise StateError("catalog-root-invalid", f"{kind} delta conflicts", 4)
                if existing.get("phase") == "applied":
                    return {"state": "released" if kind == "RELEASE" else "active",
                            "idempotent": True, "root_digest": proof["root"][3][3].hex()}
                if existing.get("phase") != "will" or recovery["state"] != 4:
                    raise StateError("catalog-root-invalid", f"{kind} recovery phase is invalid", 4)
                op_digest = bytes.fromhex(existing["op_digest"])
            else:
                if kind == "SETTLE" and entry["state"] != 2:
                    raise StateError("catalog-root-invalid", "SETTLE after RELEASE is invalid", 4)
                if kind == "RELEASE" and entry["state"] != 2:
                    raise StateError("catalog-root-invalid", "duplicate RELEASE is invalid", 4)
                owned = proof["root_meta"].get("owned_bytes")
                active = proof["root_meta"].get("active_claims")
                counter_generation = proof["root_meta"].get("counter_generation")
                overlay = proof["root_meta"].get("recovery_overlay_digest")
                if (not isinstance(owned, int) or owned + delta < CATALOG_GENESIS_FLOOR or
                        not isinstance(active, int) or active < 1 or
                        not isinstance(counter_generation, int) or counter_generation < 0 or
                        not isinstance(overlay, str) or not HEX64.fullmatch(overlay)):
                    raise StateError("catalog-root-invalid", "ROOT recovery counters are invalid", 4)
                op_core = (_catalog_instance_subject(key) +
                           bytes.fromhex(payload["reservation_digest"]) +
                           kind.encode("ascii") + struct.pack(">q", delta))
                op_digest = _catalog_digest(b"zyz-recovery-delta-op-v1", op_core)
                region = _catalog_recovery_operation_region(
                    payload, kind, "will", delta, proof["root"][0], op_digest,
                    proof["root"][3][3])
                will_payload = dict(payload, state="DELTA_WILL", _operation_region=region)
                will_payload.pop("_operations", None)
                will_image = _catalog_recovery_dynamic_image(
                    index, 4, recovery["generation"] + 1, will_payload)
                will_digest = _catalog_digest(b"zyz-recovery-cell-selected-v1", will_image)
                next_recovery_bank = 1 - recovery_bank
                _catalog_pwrite_all(
                    recovery_fd, will_image,
                    index * CATALOG_RECOVERY_CELL_SIZE +
                    next_recovery_bank * CATALOG_RECOVERY_IMAGE_SIZE,
                    f"{kind} recovery will")
                _data_sync(recovery_fd)
                target_entry_bank = 1 - entry_bank
                target_base = (CATALOG_LAYOUT["cell_directory_a"][0]
                               if target_entry_bank == 0 else
                               CATALOG_LAYOUT["cell_directory_b"][0])
                directory = _catalog_directory_image(
                    index, 3 if kind == "RELEASE" else 2,
                    recovery["generation"] + 1, entry["free_generation"],
                    (entry["fields"][0], will_digest, entry["fields"][2],
                     entry["fields"][3], entry["fields"][4]))
                _catalog_pwrite_all(
                    global_fd, directory,
                    target_base + index * CATALOG_DIRECTORY_IMAGE_SIZE,
                    f"{kind} recovery directory")
                _data_sync(global_fd)
                _catalog_barrier("catalog-recovery", "delta-will")
                selector = _catalog_selector_set(selector, index, target_entry_bank)
                next_overlay = _catalog_digest(
                    b"zyz-recovery-overlay-v1",
                    bytes.fromhex(overlay) + op_digest + struct.pack(">q", delta))
                updates = {"owned_bytes": owned + delta,
                           "counter_generation": counter_generation + 1,
                           "recovery_overlay_digest": next_overlay.hex()}
                if kind == "RELEASE":
                    updates["active_claims"] = active - 1
                    if key.startswith("claim."):
                        active_data = proof["root_meta"].get("active_data_claims")
                        if not isinstance(active_data, int) or active_data < 1:
                            raise StateError("catalog-root-invalid",
                                             "active data-claim counter underflows", 4)
                        updates["active_data_claims"] = active_data - 1
                _catalog_root_successor(global_fd, recovery_fd, proof, selector,
                                        updates, "delta-commit")
                proof = _catalog_validate_genesis(container)
                os.close(proof.pop("global_fd"))
                selector = proof["root"][2][4096:5120]
                entry_bank, _, entry = _catalog_selected_entry(global_fd, selector, index)
                recovery_bank, _, recovery = _catalog_selected_recovery(
                    recovery_fd, entry, index)
                payload = recovery["payload"]
                existing = payload.get("_operations", {}).get(kind)
                if (recovery["state"] != 4 or not existing or
                        existing.get("phase") != "will" or
                        existing.get("op_digest") != op_digest.hex()):
                    raise StateError("catalog-root-invalid", f"{kind} commit is not recoverable", 4)

            region = _catalog_recovery_operation_region(
                payload, kind, "applied", delta, proof["root"][0], op_digest,
                proof["root"][3][3])
            applied_payload = dict(payload, state="DELTA_APPLIED",
                                   _operation_region=region)
            applied_payload.pop("_operations", None)
            applied_image = _catalog_recovery_dynamic_image(
                index, 5, recovery["generation"] + 1, applied_payload)
            applied_digest = _catalog_digest(
                b"zyz-recovery-cell-selected-v1", applied_image)
            next_recovery_bank = 1 - recovery_bank
            _catalog_pwrite_all(
                recovery_fd, applied_image,
                index * CATALOG_RECOVERY_CELL_SIZE +
                next_recovery_bank * CATALOG_RECOVERY_IMAGE_SIZE,
                f"{kind} recovery applied")
            _data_sync(recovery_fd)
            target_entry_bank = 1 - entry_bank
            target_base = (CATALOG_LAYOUT["cell_directory_a"][0]
                           if target_entry_bank == 0 else
                           CATALOG_LAYOUT["cell_directory_b"][0])
            directory = _catalog_directory_image(
                index, 3 if kind == "RELEASE" else 2,
                recovery["generation"] + 1, entry["free_generation"],
                (entry["fields"][0], applied_digest, entry["fields"][2],
                 entry["fields"][3], entry["fields"][4]))
            _catalog_pwrite_all(global_fd, directory,
                                target_base + index * CATALOG_DIRECTORY_IMAGE_SIZE,
                                f"{kind} applied directory")
            _data_sync(global_fd)
            selector = _catalog_selector_set(selector, index, target_entry_bank)
            successor = _catalog_root_successor(
                global_fd, recovery_fd, proof, selector, {}, "delta-applied-visible")
            _catalog_barrier("catalog-recovery", "delta-applied")
            return {"state": "released" if kind == "RELEASE" else "active",
                    "idempotent": False, "root_digest": successor["digest"].hex(),
                    "op_digest": op_digest.hex()}
        finally:
            os.close(global_fd); os.close(recovery_fd)


def _catalog_overlay_frame(index: int, entry: dict, recovery: dict) -> bytes:
    operations = recovery["payload"].get("_operations", {})
    if not operations or any(value.get("phase") != "applied"
                             for value in operations.values()):
        raise StateError("catalog-root-invalid", "overlay operations are not applied", 4)
    payload = {"schema_version": 1, "frame_type": "recovery-overlay",
               "cell_index": index,
               "subject_digest": recovery["payload"]["subject_digest"],
               "reservation_digest": recovery["payload"]["reservation_digest"],
               "object_identities_digest": recovery["payload"]["object_identities_digest"],
               "consumed_free_receipt_record_digest":
                   recovery["payload"]["consumed_free_receipt_record_digest"],
               "operations": {name: dict(value) for name, value in sorted(operations.items())}}
    return _catalog_frame_image("overlay", payload)


def _catalog_flush_cell(container: Path, key: str, config: dict | None = None) -> dict:
    """Flush applied recovery deltas into an immutable segment and ACK the cell."""
    config = _gc_config() if config is None else config
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        os.close(proof.pop("global_fd"))
        if proof["root_meta"].get("owned_bytes", 2147483647) >= config[
                "ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES"]:
            raise StateError("catalog-high-water-pressure",
                             "overlay flush waits until owned bytes fall below high water", 4, True)
        global_fd = os.open(os.fsencode(container / ".catalog-global-pack.v1"),
                            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(os.fsencode(container / ".catalog-recovery-pack.v1"),
                              os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            duplicate, _ = _catalog_find_instance_cell(global_fd, proof, key)
            if duplicate is None:
                if proof["root_meta"].get("last_freed_subject_digest") == \
                        _catalog_instance_subject(key).hex():
                    return {"state": "free", "idempotent": True}
                raise StateError("catalog-root-invalid", "flush owner mapping is absent", 4)
            index = duplicate
            selector = proof["root"][2][4096:5120]
            entry_bank, _, entry = _catalog_selected_entry(global_fd, selector, index)
            recovery_bank, _, recovery = _catalog_selected_recovery(recovery_fd, entry, index)
            if entry["state"] not in (2, 3):
                raise StateError("catalog-root-invalid", "flush cell state is invalid", 4)
            frame = _catalog_overlay_frame(index, entry, recovery)
            frame_digest = _catalog_digest(b"zyz-catalog-frame-v1", frame)
            operation_count = len(recovery["payload"]["_operations"])
            flush = recovery["payload"].get("_flush")
            if recovery["state"] == 7 and flush and flush.get("phase") == "acked":
                return {"state": "flush-acked", "idempotent": True,
                        "frame_digest": flush["frame_digest"]}
            if recovery["state"] == 5:
                segment_generation = int(proof["root_meta"].get("active_segment_generation", 1))
                _catalog_active_member(proof)
                frame_offset = proof["root_meta"].get(
                    "active_segment_used_length")
                if not isinstance(frame_offset, int):
                    raise StateError("catalog-root-invalid", "segment append offset is invalid", 4)
                region = _catalog_recovery_flush_region(
                    recovery["payload"], "will", segment_generation,
                    frame_offset, frame, operation_count)
                will_payload = dict(recovery["payload"], state="FLUSH_ACKED",
                                    _operation_region=region)
                will_payload.pop("_operations", None); will_payload.pop("_flush", None)
                will_image = _catalog_recovery_dynamic_image(
                    index, 6, recovery["generation"] + 1, will_payload)
                will_digest = _catalog_digest(b"zyz-recovery-cell-selected-v1", will_image)
                next_recovery_bank = 1 - recovery_bank
                _catalog_pwrite_all(
                    recovery_fd, will_image,
                    index * CATALOG_RECOVERY_CELL_SIZE +
                    next_recovery_bank * CATALOG_RECOVERY_IMAGE_SIZE,
                    "overlay flush will")
                _data_sync(recovery_fd)
                next_entry_bank = 1 - entry_bank
                base = (CATALOG_LAYOUT["cell_directory_a"][0] if next_entry_bank == 0
                        else CATALOG_LAYOUT["cell_directory_b"][0])
                directory = _catalog_directory_image(
                    index, entry["state"], recovery["generation"] + 1,
                    entry["free_generation"],
                    (entry["fields"][0], will_digest, entry["fields"][2],
                     entry["fields"][3], entry["fields"][4]))
                _catalog_pwrite_all(global_fd, directory,
                                    base + index * CATALOG_DIRECTORY_IMAGE_SIZE,
                                    "overlay flush will directory")
                _data_sync(global_fd)
                selector = _catalog_selector_set(selector, index, next_entry_bank)
                _catalog_root_successor(global_fd, recovery_fd, proof, selector, {},
                                        "overlay-flush-will")
                proof = _catalog_validate_genesis(container)
                os.close(proof.pop("global_fd"))
                selector = proof["root"][2][4096:5120]
                entry_bank, _, entry = _catalog_selected_entry(global_fd, selector, index)
                recovery_bank, _, recovery = _catalog_selected_recovery(
                    recovery_fd, entry, index)
                flush = recovery["payload"].get("_flush")
            if (recovery["state"] != 6 or not flush or flush.get("phase") != "will" or
                    flush.get("frame_digest") != frame_digest.hex() or
                    flush.get("frame_length") != len(frame) or
                    flush.get("operation_count") != operation_count):
                raise StateError("catalog-root-invalid", "overlay flush will conflicts", 4)
            segment_result = _catalog_commit_active_frame(
                container, proof, flush["segment_generation"],
                flush["frame_offset"], frame)
            _catalog_barrier("catalog-segment", "overlay-frame-committed")
            if proof["root_meta"].get("last_overlay_frame_digest") != frame_digest.hex():
                overlay = proof["root_meta"].get("recovery_overlay_digest")
                if not isinstance(overlay, str) or not HEX64.fullmatch(overlay):
                    raise StateError("catalog-root-invalid", "ROOT overlay digest is invalid", 4)
                next_overlay = _catalog_digest(
                    b"zyz-recovery-overlay-flush-v1", bytes.fromhex(overlay) + frame_digest)
                updates = {"recovery_overlay_digest": next_overlay.hex(),
                           "overlay_flush_cursor": (index + 1) % CATALOG_CELL_COUNT,
                           "last_overlay_frame_digest": frame_digest.hex(),
                           "active_segment_generation": flush["segment_generation"],
                           "active_segment_used_length": segment_result["end"],
                           "active_segment_descriptor_digest":
                               segment_result["descriptor_digest"]}
                chain_region = _catalog_active_append_chain_region(
                    proof, segment_result)
                _catalog_root_successor(
                    global_fd, recovery_fd, proof, selector, updates,
                    "overlay-flush-commit", chain_region)
                proof = _catalog_validate_genesis(container)
                os.close(proof.pop("global_fd"))
                selector = proof["root"][2][4096:5120]
                entry_bank, _, entry = _catalog_selected_entry(global_fd, selector, index)
                recovery_bank, _, recovery = _catalog_selected_recovery(
                    recovery_fd, entry, index)
            region = _catalog_recovery_flush_region(
                recovery["payload"], "acked", flush["segment_generation"],
                flush["frame_offset"], frame, operation_count)
            ack_payload = dict(recovery["payload"], state="CELL_FREE_WILL",
                               _operation_region=region)
            ack_payload.pop("_operations", None); ack_payload.pop("_flush", None)
            ack_image = _catalog_recovery_dynamic_image(
                index, 7, recovery["generation"] + 1, ack_payload)
            ack_digest = _catalog_digest(b"zyz-recovery-cell-selected-v1", ack_image)
            next_recovery_bank = 1 - recovery_bank
            _catalog_pwrite_all(
                recovery_fd, ack_image,
                index * CATALOG_RECOVERY_CELL_SIZE +
                next_recovery_bank * CATALOG_RECOVERY_IMAGE_SIZE,
                "overlay flush ack")
            _data_sync(recovery_fd)
            next_entry_bank = 1 - entry_bank
            base = (CATALOG_LAYOUT["cell_directory_a"][0] if next_entry_bank == 0
                    else CATALOG_LAYOUT["cell_directory_b"][0])
            directory = _catalog_directory_image(
                index, entry["state"], recovery["generation"] + 1,
                entry["free_generation"],
                (entry["fields"][0], ack_digest, entry["fields"][2],
                 entry["fields"][3], entry["fields"][4]))
            _catalog_pwrite_all(global_fd, directory,
                                base + index * CATALOG_DIRECTORY_IMAGE_SIZE,
                                "overlay flush ack directory")
            _data_sync(global_fd)
            selector = _catalog_selector_set(selector, index, next_entry_bank)
            successor = _catalog_root_successor(
                global_fd, recovery_fd, proof, selector, {}, "flush-acked-visible")
            _catalog_barrier("catalog-recovery", "flush-acked")
            return {"state": "flush-acked", "idempotent": False,
                    "frame_digest": frame_digest.hex(),
                    "root_digest": successor["digest"].hex()}
        finally:
            os.close(global_fd); os.close(recovery_fd)


def _catalog_ordinary_free(container: Path, key: str) -> dict:
    """Persist an ordinary FREE_RECEIPT frame and atomically reuse the cell."""
    subject = _catalog_instance_subject(key)
    physical_entries_deleted = 0
    physical_bytes_reclaimed = 0
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        os.close(proof.pop("global_fd"))
        global_fd = os.open(os.fsencode(container / ".catalog-global-pack.v1"),
                            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(os.fsencode(container / ".catalog-recovery-pack.v1"),
                              os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            duplicate, _ = _catalog_find_instance_cell(global_fd, proof, key)
            if duplicate is None:
                if proof["root_meta"].get("last_freed_subject_digest") == subject.hex():
                    return {"state": "free", "idempotent": True,
                            "entries_deleted": 0, "bytes_reclaimed": 0,
                            "free_receipt_record_digest":
                                proof["root_meta"].get("last_free_receipt_record_digest")}
                raise StateError("catalog-root-invalid", "ordinary free owner mapping is absent", 4)
            index = duplicate
            selector = proof["root"][2][4096:5120]
            entry_bank, _, entry = _catalog_selected_entry(global_fd, selector, index)
            recovery_bank, _, recovery = _catalog_selected_recovery(recovery_fd, entry, index)
            payload = recovery["payload"]
            operations = payload.get("_operations", {})
            if (entry["state"] != 3 or recovery["state"] != 7 or
                    "RELEASE" not in operations or
                    operations["RELEASE"].get("phase") != "applied" or
                    payload.get("subject_digest") != subject.hex()):
                raise StateError("catalog-root-invalid", "ordinary free precondition is invalid", 4)
            prior_record = bytes.fromhex(payload["consumed_free_receipt_record_digest"])
            prior_projection = {"subject_digest": payload["subject_digest"],
                                "reservation_digest": payload["reservation_digest"],
                                "object_identities_digest": payload["object_identities_digest"],
                                "operations": {name: dict(value)
                                               for name, value in sorted(operations.items())}}
            prior_fact = _catalog_digest(
                b"zyz-last-owner-frame-v1", _catalog_json(prior_projection))
            free_generation = entry["free_generation"] + 1
            flush = payload.get("_flush")
            cell_generation = recovery["generation"] + (
                2 if flush and flush.get("phase") == "acked" else 1)
            if free_generation > 65535 or cell_generation > 65535:
                raise StateError("catalog-root-invalid", "CELL generation overflow", 4)
            material = _catalog_free_material(
                index, free_generation, prior_record, 1, prior_fact,
                cell_generation=cell_generation)
            receipt_payload = {"schema_version": 1, "frame_type": "FREE_RECEIPT",
                               "kind": "ordinary", "cell_index": index,
                               "cell_generation": cell_generation,
                               "free_generation": free_generation,
                               "predecessor_record_digest": prior_record.hex(),
                               "prior_owner_fact_digest": prior_fact.hex(),
                               "body_b64": base64.b64encode(material["body"]).decode(),
                               "body_digest": material["body_digest"].hex(),
                               "final_cell_image_digest":
                                   material["final_cell_digest"].hex(),
                               "record_digest": material["record_digest"].hex()}
            receipt_frame = _catalog_frame_image("free-receipt", receipt_payload)
            receipt_frame_digest = _catalog_digest(
                b"zyz-catalog-frame-v1", receipt_frame)
            if flush and flush.get("phase") == "acked":
                segment_generation = int(proof["root_meta"].get("active_segment_generation", 1))
                _catalog_active_member(proof)
                frame_offset = proof["root_meta"].get(
                    "active_segment_used_length")
                if not isinstance(frame_offset, int):
                    raise StateError("catalog-root-invalid", "FREE_RECEIPT frame offset is invalid", 4)
                region = _catalog_recovery_flush_region(
                    payload, "free-will", segment_generation, frame_offset,
                    receipt_frame, len(operations))
                will_payload = dict(payload, state="CELL_FREE_WILL",
                                    _operation_region=region)
                will_payload.pop("_operations", None); will_payload.pop("_flush", None)
                will_image = _catalog_recovery_dynamic_image(
                    index, 7, recovery["generation"] + 1, will_payload)
                will_digest = _catalog_digest(b"zyz-recovery-cell-selected-v1", will_image)
                next_recovery_bank = 1 - recovery_bank
                _catalog_pwrite_all(
                    recovery_fd, will_image,
                    index * CATALOG_RECOVERY_CELL_SIZE +
                    next_recovery_bank * CATALOG_RECOVERY_IMAGE_SIZE,
                    "ordinary free will")
                _data_sync(recovery_fd)
                next_entry_bank = 1 - entry_bank
                base = (CATALOG_LAYOUT["cell_directory_a"][0] if next_entry_bank == 0
                        else CATALOG_LAYOUT["cell_directory_b"][0])
                directory = _catalog_directory_image(
                    index, 3, recovery["generation"] + 1, entry["free_generation"],
                    (entry["fields"][0], will_digest, entry["fields"][2],
                     entry["fields"][3], entry["fields"][4]))
                _catalog_pwrite_all(global_fd, directory,
                                    base + index * CATALOG_DIRECTORY_IMAGE_SIZE,
                                    "ordinary free will directory")
                _data_sync(global_fd)
                selector = _catalog_selector_set(selector, index, next_entry_bank)
                _catalog_root_successor(global_fd, recovery_fd, proof, selector, {},
                                        "will-cell-free")
                proof = _catalog_validate_genesis(container)
                os.close(proof.pop("global_fd"))
                selector = proof["root"][2][4096:5120]
                entry_bank, _, entry = _catalog_selected_entry(global_fd, selector, index)
                recovery_bank, _, recovery = _catalog_selected_recovery(
                    recovery_fd, entry, index)
                payload = recovery["payload"]
                flush = payload.get("_flush")
            if (not flush or flush.get("phase") != "free-will" or
                    flush.get("frame_digest") != receipt_frame_digest.hex() or
                    flush.get("frame_length") != len(receipt_frame)):
                raise StateError("catalog-root-invalid", "ordinary free will conflicts", 4)
            if key.startswith("claim.") and HEX64.fullmatch(key[6:]):
                claim_name = f"{key[6:]}.claim-pack.v1"
                claim_path = container / claim_name
                try:
                    claim_identity = _catalog_object_identity(
                        container, claim_name, CLAIM_PACK_SIZE)
                except FileNotFoundError:
                    claim_identity = None
                if claim_identity is not None:
                    identities = {claim_name: claim_identity}
                    identity_digest = _catalog_digest(
                        b"zyz-instance-object-identities-v1",
                        _catalog_json(identities)).hex()
                    if not hmac.compare_digest(
                            identity_digest, payload["object_identities_digest"]):
                        raise StateError("catalog-root-invalid",
                                         "claim pack release identity conflicts", 4)
                    os.unlink(os.fsencode(claim_path))
                    fsync_dir(container)
                    physical_entries_deleted = 1
                    physical_bytes_reclaimed = CLAIM_PACK_SIZE
                _catalog_barrier("catalog-claim-pack", "physical-release")
                try:
                    os.lstat(os.fsencode(claim_path))
                except FileNotFoundError:
                    pass
                else:
                    raise StateError("catalog-root-invalid",
                                     "claim pack release after-set is invalid", 4)
            segment_result = _catalog_commit_active_frame(
                container, proof, flush["segment_generation"],
                flush["frame_offset"], receipt_frame)
            _catalog_barrier("catalog-segment", "free-receipt-frame-committed")
            free_image = _catalog_recovery_free_image(index, material)
            free_directory = _catalog_directory_free_image(index, material)
            next_recovery_bank = 1 - recovery_bank
            _catalog_pwrite_all(
                recovery_fd, free_image,
                index * CATALOG_RECOVERY_CELL_SIZE +
                next_recovery_bank * CATALOG_RECOVERY_IMAGE_SIZE,
                "ordinary free CELL")
            _data_sync(recovery_fd)
            next_entry_bank = 1 - entry_bank
            base = (CATALOG_LAYOUT["cell_directory_a"][0] if next_entry_bank == 0
                    else CATALOG_LAYOUT["cell_directory_b"][0])
            _catalog_pwrite_all(global_fd, free_directory,
                                base + index * CATALOG_DIRECTORY_IMAGE_SIZE,
                                "ordinary FREE_RECEIPT directory")
            _data_sync(global_fd)
            _catalog_barrier("catalog-recovery", "cell-free")
            selector = _catalog_selector_set(selector, index, next_entry_bank)
            updates = {"last_freed_subject_digest": subject.hex(),
                       "last_free_receipt_record_digest": material["record_digest"].hex(),
                       "active_segment_generation": flush["segment_generation"],
                       "active_segment_used_length": segment_result["end"],
                       "active_segment_descriptor_digest": segment_result["descriptor_digest"],
                       "discovery_cursor": (index + 1) % CATALOG_CELL_COUNT}
            chain_region = _catalog_active_append_chain_region(
                proof, segment_result)
            successor = _catalog_root_successor(
                global_fd, recovery_fd, proof, selector, updates,
                "root-did-free", chain_region)
            return {"state": "free", "idempotent": False,
                    "entries_deleted": physical_entries_deleted,
                    "bytes_reclaimed": physical_bytes_reclaimed,
                    "free_receipt_record_digest": material["record_digest"].hex(),
                    "root_digest": successor["digest"].hex()}
        finally:
            os.close(global_fd); os.close(recovery_fd)


def _catalog_migration_source_fact(member: dict) -> dict:
    first = member.get("logical_first_generation", member.get("generation"))
    last = member.get("logical_last_generation", member.get("generation"))
    if (not isinstance(first, int) or not isinstance(last, int) or
            first < 1 or last < first):
        raise StateError("catalog-root-invalid",
                         "migration source logical range is invalid", 4)
    return {
        "segment_generation": member["generation"],
        "logical_first_generation": first,
        "logical_last_generation": last,
        "basename": member["basename"],
        "identity_digest": member["identity_digest"],
        "descriptor_digest": member["descriptor_digest"],
        "descriptor_generation": member["descriptor_generation"],
        "used_length": member["used_length"],
    }


def _catalog_migration_quiesce_intent(container: Path, proof: dict,
                                      migration_generation: int) -> dict:
    root = proof["root_meta"]
    chain = proof.get("chain")
    if (not isinstance(chain, dict) or not chain.get("members") or
            not isinstance(migration_generation, int) or migration_generation < 1):
        raise StateError("catalog-root-invalid", "migration source chain is invalid", 4)
    source_facts = [{"position": position,
                     **_catalog_migration_source_fact(member)}
                    for position, member in enumerate(chain["members"])]
    scratch = _catalog_segment_chain_projection(
        container, ".catalog-compaction-scratch.v1", 0)
    source_digest = _catalog_digest(
        b"zyz-migration-source-chain-v1", _catalog_json(source_facts)).hex()
    scratch_fact = {
        "segment_generation": 0,
        "basename": scratch["basename"],
        "identity_digest": scratch["identity_digest"],
        "descriptor_digest": scratch["descriptor_digest"],
        "descriptor_generation": scratch["descriptor_generation"],
        "used_length": scratch["used_length"],
    }
    if scratch_fact["used_length"] != 0:
        raise StateError("catalog-root-invalid", "migration scratch is not empty", 4)
    next_sequence = root.get("next_sequence")
    counter_generation = root.get("counter_generation")
    if (not isinstance(next_sequence, int) or next_sequence < 1 or
            not isinstance(counter_generation, int) or counter_generation < 0):
        raise StateError("catalog-root-invalid", "migration creator cutoff is invalid", 4)
    return {
        "schema_version": 1,
        "migration_generation": migration_generation,
        "recovery_map_digest": root.get("recovery_sha256"),
        "counter_generation": counter_generation,
        "creator_cutoff_sequence": next_sequence - 1,
        "source_chain_digest": source_digest,
        "source_hybrid_chain_digest": chain["digest"],
        "source_chain_generation": chain["generation"],
        "source_count": len(source_facts),
        "first_source_generation": source_facts[0]["segment_generation"],
        "last_source_generation": source_facts[-1]["segment_generation"],
        "scratch": scratch_fact,
    }


def _catalog_dense_signature_value(root: dict) -> str:
    """Bind the exact five inputs which make a dense result reusable."""
    chain = root.get("hybrid_chain_digest")
    overlay = root.get("recovery_overlay_digest")
    if (not isinstance(chain, str) or not HEX64.fullmatch(chain) or
            not isinstance(overlay, str) or not HEX64.fullmatch(overlay)):
        raise StateError("catalog-root-invalid",
                         "dense-capacity signature digests are invalid", 4)
    counters = []
    for name in ("counter_generation", "owned_bytes",
                 "active_data_claims"):
        value = root.get(name)
        if (not isinstance(value, int) or isinstance(value, bool) or
                not 0 <= value <= 2147483647):
            raise StateError("catalog-root-invalid",
                             "dense-capacity signature counters are invalid", 4)
        counters.append(value)
    payload = (bytes.fromhex(chain) + bytes.fromhex(overlay) +
               struct.pack(">QQQ", *counters))
    return _catalog_digest(
        b"zyz-dense-capacity-signature-v1", payload).hex()


def _catalog_dense_signature_matches(root: dict) -> bool:
    """Validate the stored signature and distinguish stale from malformed."""
    signature = root.get("dense_capacity_signature")
    if signature is None:
        return False
    if not isinstance(signature, str) or not HEX64.fullmatch(signature):
        raise StateError("catalog-root-invalid",
                         "dense-capacity signature is malformed", 4)
    return hmac.compare_digest(signature,
                               _catalog_dense_signature_value(root))


def _catalog_migration_quiesce_begin(container: Path) -> dict:
    """Durably close creator admission at the frozen source-chain cutoff."""
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        os.close(proof.pop("global_fd"))
        global_fd = os.open(
            os.fsencode(container / ".catalog-global-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(
            os.fsencode(container / ".catalog-recovery-pack.v1"),
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            root = proof["root_meta"]
            if root.get("state") in ("migration-quiescing", "migration-active"):
                if (root.get("admission_state") != "closed" or
                        not isinstance(root.get("migration_quiesce_intent"), dict)):
                    raise StateError("catalog-root-invalid",
                                     "migration admission closure is invalid", 4)
                return {
                    "state": root["state"],
                    "migration_generation": root["migration_generation"],
                    "idempotent": True,
                }
            if root.get("state") == "active":
                if (root.get("admission_state") != "open" or
                        proof["group_meta"].get("state") != "idle"):
                    raise StateError("catalog-root-invalid",
                                     "migration quiesce prior is invalid", 4)
                migration_generation = root.get("migration_generation", 0) + 1
                intent = _catalog_migration_quiesce_intent(
                    container, proof, migration_generation)
                _catalog_root_successor(
                    global_fd, recovery_fd, proof,
                    proof["root"][2][4096:5120],
                    {"state": "will-migration-quiesce",
                     "admission_state": "closed",
                     "migration_generation": migration_generation,
                     "migration_quiesce_intent": intent,
                     "migration_creator_cutoff":
                         intent["creator_cutoff_sequence"],
                     "migration_source_chain_digest":
                         intent["source_chain_digest"],
                     "migration_scan_cursor": 0},
                    "will-migration-quiesce")
                proof = _catalog_validate_genesis(container)
                os.close(proof.pop("global_fd"))
                root = proof["root_meta"]
            if root.get("state") != "will-migration-quiesce":
                raise StateError("catalog-root-invalid",
                                 "migration quiesce state conflicts", 4)
            intent = root.get("migration_quiesce_intent")
            if (not isinstance(intent, dict) or
                    intent != _catalog_migration_quiesce_intent(
                        container, proof, root.get("migration_generation"))):
                raise StateError("catalog-root-invalid",
                                 "migration quiesce intent conflicts", 4)
            successor = _catalog_root_successor(
                global_fd, recovery_fd, proof,
                proof["root"][2][4096:5120],
                {"state": "migration-quiescing", "admission_state": "closed"},
                "migration-source-group-initialized")
            return {
                "state": "migration-quiescing",
                "migration_generation": root["migration_generation"],
                "root_digest": successor["digest"].hex(),
                "idempotent": False,
            }
        finally:
            os.close(global_fd)
            os.close(recovery_fd)


def _catalog_previs_group_begin(container: Path, source_segment_generation: int) -> dict:
    """Bind the first quiesce source group before PREVIS cancellation work."""
    if source_segment_generation < 1:
        raise StateError("gc-internal", "PREVIS source generation is invalid", 5)
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_read = proof.pop("global_fd"); os.close(global_read)
        global_fd = os.open(os.fsencode(container / ".catalog-global-pack.v1"),
                            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(os.fsencode(container / ".catalog-recovery-pack.v1"),
                              os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            root = proof["root_meta"]
            group = proof["group_meta"]
            if (root.get("state") in ("migration-quiescing", "migration-active") and
                    group.get("state") != "idle"):
                if (root.get("migration_source_segment_generation") !=
                        source_segment_generation or
                        group.get("group_generation") !=
                            root.get("migration_group_generation")):
                    raise StateError("catalog-root-invalid", "PREVIS group conflicts", 4)
                return {"state": root["state"], "group_generation": group["group_generation"],
                        "idempotent": True}
            if (root.get("state") not in ("migration-quiescing",
                                          "migration-active") or
                    root.get("admission_state") != "closed" or
                    group.get("state") != "idle"):
                raise StateError("catalog-root-invalid", "PREVIS group cannot start", 4)
            matches = [value for value in proof["chain"]["members"]
                       if value["generation"] == source_segment_generation]
            if len(matches) != 1:
                raise StateError("catalog-root-invalid", "PREVIS source is not authoritative", 4)
            source = matches[0]
            source_fact = _catalog_migration_source_fact(source)
            source_group_digest = _catalog_digest(
                b"zyz-migration-source-group-v1", _catalog_json([source_fact])).hex()
            group_generation = group["group_generation"] + 1
            metadata = dict(
                group, state="new-source-initialized",
                group_generation=group_generation,
                source_segment_generation=source_segment_generation,
                source_segments=[source_fact],
                source_group_digest=source_group_digest,
                plan_scan_cursor=0, planned_frame_count=0,
                planned_frame_bytes=0, planned_frame_digest=None,
                copy_cursor=0, copy_bytes=0,
                cancel_count=0,
                cancel_set_digest=_catalog_digest(
                    b"zyz-previs-cancel-set-v1", b"").hex(),
                free_count=0,
                consumed_digest=_catalog_digest(
                    b"zyz-previs-consumed-v1", b"").hex(),
                group_visible_digest=None,
                retirement_cursor=0, retired_bytes=0)
            successor_group = _catalog_group_successor(global_fd, proof, metadata)
            selector = proof["root"][2][4096:5120]
            successor = _catalog_root_successor(
                global_fd, recovery_fd, proof, selector,
                {"migration_group_generation": group_generation,
                 "migration_source_segment_generation": source_segment_generation,
                 "previs_cancel_count": 0, "previs_cancel_will": None,
                 "previs_free_will": None,
                 "group_control_digest": successor_group["digest"].hex()},
                "migration-quiescing")
            return {"state": "migration-quiescing", "group_generation": group_generation,
                    "root_digest": successor["digest"].hex(), "idempotent": False}
        finally:
            os.close(global_fd); os.close(recovery_fd)


def _catalog_group_bitmap_append(encoded: str, slots: int,
                                 selected: bool) -> str:
    try:
        raw = bytearray(base64.b64decode(encoded, validate=True))
    except Exception:
        raise StateError("catalog-root-invalid", "migration plan bitmap is invalid", 4)
    if len(raw) != (slots + 7) // 8:
        raise StateError("catalog-root-invalid", "migration plan bitmap length conflicts", 4)
    if slots % 8 == 0:
        raw.append(0)
    if selected:
        raw[slots // 8] |= 1 << (7 - slots % 8)
    return base64.b64encode(raw).decode("ascii")


def _catalog_group_bitmap_truncate(encoded: str, slots: int) -> str:
    try:
        raw = bytearray(base64.b64decode(encoded, validate=True))
    except Exception:
        raise StateError("catalog-root-invalid", "migration plan bitmap is invalid", 4)
    raw = raw[:(slots + 7) // 8]
    if raw and slots % 8:
        raw[-1] &= (0xff << (8 - slots % 8)) & 0xff
    return base64.b64encode(raw).decode("ascii")


def _catalog_group_claim_active(container: Path, global_fd: int,
                                recovery_fd: int, proof: dict,
                                frame: dict) -> bool:
    if frame["kind"] != "claim":
        return False
    payload = frame["payload"]
    digest = payload.get("logical_key_sha256")
    name = payload.get("claim_pack_basename")
    index = payload.get("recovery_cell_index")
    if (not isinstance(digest, str) or not HEX64.fullmatch(digest) or
            name != f"{digest}.claim-pack.v1" or
            not isinstance(index, int) or not 0 <= index < CATALOG_CELL_COUNT):
        raise StateError("catalog-root-invalid", "migration claim frame is invalid", 4)
    try:
        identity = _catalog_object_identity(container, name, CLAIM_PACK_SIZE)
    except FileNotFoundError:
        return False
    selector = proof["root"][2][4096:5120]
    _, _, entry = _catalog_selected_entry(global_fd, selector, index)
    _, _, recovery = _catalog_selected_recovery(recovery_fd, entry, index)
    immutable = _instance_pack_read(container, digest, "claim", "IMMUTABLE_KEY")
    identities_digest = _catalog_digest(
        b"zyz-instance-object-identities-v1",
        _catalog_json({name: identity})).hex()
    if (entry["state"] != 2 or recovery["state"] not in (3, 4, 5, 6) or
            recovery["payload"].get("state") not in
                ("ACTIVE_ACK", "DELTA_WILL", "DELTA_APPLIED", "FLUSH_ACKED") or
            entry["fields"][0] != _catalog_instance_subject(f"claim.{digest}") or
            recovery["payload"].get("reservation_digest") !=
                payload.get("reservation_digest") or
            recovery["payload"].get("object_identities_digest") !=
                identities_digest or
            not isinstance(immutable, dict) or
            immutable.get("logical_key_sha256") != digest or
            immutable.get("pack_identity_digest") != identity["digest"] or
            immutable.get("reservation_digest") != payload.get("reservation_digest") or
            payload.get("pack_identity_digest") != identity["digest"]):
        raise StateError("catalog-root-invalid",
                         "migration active claim binding conflicts", 4)
    return True


def _catalog_group_plan_step(container: Path, limit: int = 64) -> dict:
    """Freeze a <=16-source active-frame plan in <=64 frame slices."""
    if not 1 <= limit <= 64:
        raise StateError("gc-internal", "migration plan limit is invalid", 5)
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_read = proof.pop("global_fd"); os.close(global_read)
        global_fd = os.open(
            os.fsencode(container / ".catalog-global-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(
            os.fsencode(container / ".catalog-recovery-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            root = proof["root_meta"]
            group = proof["group_meta"]
            if (root.get("state") not in ("migration-quiescing",
                                           "migration-active") or
                    root.get("admission_state") != "closed" or
                    root.get("migration_scan_cursor") != CATALOG_CELL_COUNT):
                raise StateError("catalog-root-invalid",
                                 "migration group planning is not quiesced", 4)
            if group["state"] == "new-source-initialized":
                first = group["source_segment_generation"]
                members = proof["chain"]["members"]
                start = next((position for position, member in enumerate(members)
                              if member["generation"] == first), None)
                if start is None:
                    raise StateError("catalog-root-invalid",
                                     "migration group source left the chain", 4)
                sources = [_catalog_migration_source_fact(member)
                           for member in members[start:start + 16]]
                scratch_basename = root.get("migration_scratch_basename")
                if (not isinstance(scratch_basename, str) or
                        not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", scratch_basename)):
                    raise StateError("catalog-root-invalid",
                                     "migration scratch authority is invalid", 4)
                scratch = _catalog_segment_chain_projection(
                    container, scratch_basename, 0)
                if scratch["used_length"] != 0:
                    raise StateError("catalog-root-invalid",
                                     "migration scratch prior is not empty", 4)
                empty = _catalog_digest(
                    b"zyz-migration-active-frame-list-v1", b"").hex()
                group = dict(
                    group, state="planning", source_segments=sources,
                    source_group_digest=_catalog_digest(
                        b"zyz-migration-source-group-v1",
                        _catalog_json(sources)).hex(),
                    scratch_identity=scratch["identity_digest"],
                    scratch_basename=scratch_basename,
                    scratch_descriptor_digest=scratch["descriptor_digest"],
                    plan_segment_index=0, plan_frame_offset=0,
                    plan_segment_start_slots=0, plan_total_slots=0,
                    plan_bitmap_b64="", plan_selected_source_count=0,
                    planned_frame_count=0, planned_frame_bytes=0,
                    planned_frame_digest=empty,
                    candidate_frame_count=0, candidate_frame_bytes=0,
                    candidate_frame_digest=empty)
                result = _catalog_group_commit(
                    global_fd, recovery_fd, proof, group,
                    "group-plan-started")
                return {"state": "planning", "frames_scanned": 0,
                        "idempotent": False, **result}
            if group["state"] in ("group-planned", "copy-will", "copying", "copied"):
                return {"state": group["state"], "frames_scanned": 0,
                        "idempotent": True}
            if group["state"] != "planning":
                raise StateError("catalog-root-invalid",
                                 "migration group planning phase conflicts", 4)
            required_ints = (
                "plan_segment_index", "plan_frame_offset",
                "plan_segment_start_slots", "plan_total_slots",
                "plan_selected_source_count", "planned_frame_count",
                "planned_frame_bytes", "candidate_frame_count",
                "candidate_frame_bytes")
            if (any(not isinstance(group.get(name), int) or group[name] < 0
                    for name in required_ints) or
                    not isinstance(group.get("source_segments"), list) or
                    not 1 <= len(group["source_segments"]) <= 16 or
                    group["plan_segment_index"] >= len(group["source_segments"]) or
                    not isinstance(group.get("plan_bitmap_b64"), str) or
                    not HEX64.fullmatch(str(group.get("planned_frame_digest"))) or
                    not HEX64.fullmatch(str(group.get("candidate_frame_digest")))):
                raise StateError("catalog-root-invalid",
                                 "migration plan cursor is invalid", 4)
            scanned = 0
            while scanned < limit and group["state"] == "planning":
                source_index = group["plan_segment_index"]
                source = group["source_segments"][source_index]
                fd = os.open(os.fsencode(container / source["basename"]),
                             os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                try:
                    offset = group["plan_frame_offset"]
                    if not 0 <= offset <= source["used_length"]:
                        raise StateError("catalog-root-invalid",
                                         "migration plan source cursor conflicts", 4)
                    if offset < source["used_length"]:
                        header = _catalog_pread_exact(fd, 20, offset)
                        if header[0:8] != b"ZYZFRM1\0":
                            raise StateError("catalog-root-invalid",
                                             "migration plan frame magic is invalid", 4)
                        total = struct.unpack_from(">I", header, 16)[0]
                        if (total < 64 or total % 8 or
                                offset + total > source["used_length"]):
                            raise StateError("catalog-root-invalid",
                                             "migration plan frame length is invalid", 4)
                        raw = _catalog_pread_exact(fd, total, offset)
                        frame = _catalog_parse_frame(raw)
                        active = _catalog_group_claim_active(
                            container, global_fd, recovery_fd, proof, frame)
                        bitmap = _catalog_group_bitmap_append(
                            group["plan_bitmap_b64"], group["plan_total_slots"],
                            active)
                        updates = {
                            "plan_bitmap_b64": bitmap,
                            "plan_total_slots": group["plan_total_slots"] + 1,
                            "plan_frame_offset": offset + total,
                        }
                        if active:
                            accumulator = _catalog_digest(
                                b"zyz-migration-active-frame-step-v1",
                                bytes.fromhex(group["candidate_frame_digest"]) +
                                struct.pack(">QQ", source["segment_generation"],
                                            offset) + frame["digest"])
                            updates.update(
                                candidate_frame_count=
                                    group["candidate_frame_count"] + 1,
                                candidate_frame_bytes=
                                    group["candidate_frame_bytes"] + total,
                                candidate_frame_digest=accumulator.hex())
                        group = dict(group, **updates)
                        scanned += 1
                        continue
                finally:
                    os.close(fd)
                # EOF: accept the largest complete prefix that fits the fixed
                # scratch ordinary area. A single source always fits itself.
                fits = (group["candidate_frame_bytes"] <=
                        CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL)
                if not fits:
                    if group["plan_selected_source_count"] == 0:
                        raise StateError("catalog-root-invalid",
                                         "first migration source exceeds scratch", 4)
                    group = dict(
                        group, state="group-planned",
                        source_segments=group["source_segments"][:
                            group["plan_selected_source_count"]],
                        plan_bitmap_b64=_catalog_group_bitmap_truncate(
                            group["plan_bitmap_b64"],
                            group["plan_segment_start_slots"]),
                        plan_total_slots=group["plan_segment_start_slots"])
                    break
                selected = source_index + 1
                group = dict(
                    group, plan_selected_source_count=selected,
                    planned_frame_count=group["candidate_frame_count"],
                    planned_frame_bytes=group["candidate_frame_bytes"],
                    planned_frame_digest=group["candidate_frame_digest"])
                if selected == len(group["source_segments"]):
                    group = dict(group, state="group-planned",
                                 source_segments=group["source_segments"][:selected])
                    break
                group = dict(
                    group, plan_segment_index=selected, plan_frame_offset=0,
                    plan_segment_start_slots=group["plan_total_slots"])
            if group["state"] == "group-planned":
                group = dict(
                    group, copy_source_index=0, copy_frame_offset=0,
                    copy_slot_cursor=0, copy_cursor=0, copy_bytes=0,
                    copy_will=None,
                    copy_accumulator=_catalog_digest(
                        b"zyz-migration-active-frame-list-v1", b"").hex())
            result = _catalog_group_commit(
                global_fd, recovery_fd, proof, group,
                "group-plan-committed" if group["state"] == "group-planned"
                else "group-plan-checkpoint")
            return {"state": group["state"], "frames_scanned": scanned,
                    "planned_sources": group["plan_selected_source_count"],
                    "planned_frames": group["planned_frame_count"], **result}
        finally:
            os.close(global_fd); os.close(recovery_fd)


def _catalog_group_bitmap_selected(encoded: str, slots: int,
                                    index: int) -> bool:
    try:
        raw = base64.b64decode(encoded, validate=True)
    except Exception:
        raise StateError("catalog-root-invalid", "migration copy bitmap is invalid", 4)
    if (len(raw) != (slots + 7) // 8 or not 0 <= index < slots or
            (slots % 8 and raw[-1] & ((1 << (8 - slots % 8)) - 1))):
        raise StateError("catalog-root-invalid",
                         "migration copy bitmap shape conflicts", 4)
    return bool(raw[index // 8] & (1 << (7 - index % 8)))


def _catalog_group_source_frame(container: Path, source: dict,
                                offset: int) -> tuple[bytes, dict, int]:
    fd = os.open(os.fsencode(container / source["basename"]),
                 os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        projection = _catalog_segment_chain_projection(
            container, source["basename"], source["segment_generation"])
        expected = {"segment_generation": projection["generation"],
                    "basename": projection["basename"],
                    "identity_digest": projection["identity_digest"],
                    "descriptor_digest": projection["descriptor_digest"],
                    "descriptor_generation": projection["descriptor_generation"],
                    "used_length": projection["used_length"]}
        # The frozen plan source (from _catalog_migration_source_fact) also
        # carries logical_first/last_generation, so revalidate on the shared
        # identity fields only.  A missing identity key (or any mismatch) still
        # fails closed as catalog-root-invalid.
        if (not all(key in source for key in expected) or
                {key: source[key] for key in expected} != expected or
                not 0 <= offset < source["used_length"]):
            raise StateError("catalog-root-invalid",
                             "migration copy source changed", 4)
        header = _catalog_pread_exact(fd, 20, offset)
        total = struct.unpack_from(">I", header, 16)[0]
        if (header[0:8] != b"ZYZFRM1\0" or total < 64 or total % 8 or
                offset + total > source["used_length"]):
            raise StateError("catalog-root-invalid",
                             "migration copy frame boundary is invalid", 4)
        raw = _catalog_pread_exact(fd, total, offset)
        return raw, _catalog_parse_frame(raw), offset + total
    finally:
        os.close(fd)


def _catalog_group_copy_step(container: Path, limit: int = 64) -> dict:
    """Advance the planned scratch copy through exact will/frame/did states."""
    if not 1 <= limit <= 64:
        raise StateError("gc-internal", "migration copy limit is invalid", 5)
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_read = proof.pop("global_fd"); os.close(global_read)
        global_fd = os.open(
            os.fsencode(container / ".catalog-global-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(
            os.fsencode(container / ".catalog-recovery-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            group = proof["group_meta"]
            if group["state"] == "group-planned":
                group = dict(group, state="copying")
            if group["state"] == "copied":
                return {"state": "copied", "frames_scanned": 0,
                        "frames_copied": 0, "idempotent": True}
            if group["state"] == "copy-will":
                will = group.get("copy_will")
                if (not isinstance(will, dict) or
                        set(will) != {"source_index", "source_generation",
                                      "source_offset", "source_next_offset",
                                      "source_frame_digest", "frame_length",
                                      "scratch_offset", "scratch_after"}):
                    raise StateError("catalog-root-invalid",
                                     "migration copy will is invalid", 4)
                source = group["source_segments"][will["source_index"]]
                raw, frame, next_offset = _catalog_group_source_frame(
                    container, source, will["source_offset"])
                if (source["segment_generation"] != will["source_generation"] or
                        next_offset != will["source_next_offset"] or
                        len(raw) != will["frame_length"] or
                        frame["digest"].hex() != will["source_frame_digest"] or
                        will["scratch_offset"] != group["copy_bytes"] or
                        will["scratch_after"] != group["copy_bytes"] + len(raw)):
                    raise StateError("catalog-root-invalid",
                                     "migration copy will/source conflicts", 4)
                result = _catalog_scratch_commit_frame(
                    container, group["scratch_basename"],
                    will["scratch_offset"], raw)
                if result["end"] != will["scratch_after"]:
                    raise StateError("catalog-root-invalid",
                                     "migration scratch after-set conflicts", 4)
                _catalog_barrier("catalog-migration-group",
                                 "scratch-frame-committed")
                accumulator = _catalog_digest(
                    b"zyz-migration-active-frame-step-v1",
                    bytes.fromhex(group["copy_accumulator"]) +
                    struct.pack(">QQ", source["segment_generation"],
                                will["source_offset"]) + frame["digest"])
                metadata = dict(
                    group, state="copying", copy_will=None,
                    copy_frame_offset=next_offset,
                    copy_slot_cursor=group["copy_slot_cursor"] + 1,
                    copy_cursor=group["copy_cursor"] + 1,
                    copy_bytes=will["scratch_after"],
                    copy_accumulator=accumulator.hex(),
                    scratch_descriptor_digest=result["descriptor_digest"])
                committed = _catalog_group_commit(
                    global_fd, recovery_fd, proof, metadata,
                    "group-copy-did")
                return {"state": "copying", "frames_scanned": 1,
                        "frames_copied": 1, "idempotent": result["idempotent"],
                        **committed}
            if group["state"] != "copying":
                raise StateError("catalog-root-invalid",
                                 "migration copy phase conflicts", 4)
            ints = ("copy_source_index", "copy_frame_offset",
                    "copy_slot_cursor", "copy_cursor", "copy_bytes",
                    "plan_total_slots", "planned_frame_count",
                    "planned_frame_bytes")
            if (any(not isinstance(group.get(name), int) or group[name] < 0
                    for name in ints) or
                    group.get("copy_will") is not None or
                    not HEX64.fullmatch(str(group.get("copy_accumulator")))):
                raise StateError("catalog-root-invalid",
                                 "migration copy cursor is invalid", 4)
            scanned = 0
            metadata = group
            while scanned < limit:
                source_index = metadata["copy_source_index"]
                if source_index >= len(metadata["source_segments"]):
                    if (metadata["copy_slot_cursor"] !=
                            metadata["plan_total_slots"] or
                            metadata["copy_cursor"] !=
                            metadata["planned_frame_count"] or
                            metadata["copy_bytes"] !=
                            metadata["planned_frame_bytes"] or
                            metadata["copy_accumulator"] !=
                            metadata["planned_frame_digest"]):
                        raise StateError("catalog-root-invalid",
                                         "migration copy EOF digest conflicts", 4)
                    scratch = _catalog_segment_chain_projection(
                        container, metadata["scratch_basename"], 0)
                    if (scratch["used_length"] != metadata["copy_bytes"] or
                            scratch["descriptor_digest"] !=
                                metadata["scratch_descriptor_digest"]):
                        raise StateError("catalog-root-invalid",
                                         "migration copied scratch conflicts", 4)
                    metadata = dict(
                        metadata, state="copied",
                        copied_scratch_identity=scratch["identity_digest"],
                        copied_scratch_descriptor_digest=
                            scratch["descriptor_digest"])
                    committed = _catalog_group_commit(
                        global_fd, recovery_fd, proof, metadata,
                        "group-copy-complete")
                    return {"state": "copied", "frames_scanned": scanned,
                            "frames_copied": 0, "idempotent": False,
                            **committed}
                source = metadata["source_segments"][source_index]
                if metadata["copy_frame_offset"] == source["used_length"]:
                    metadata = dict(
                        metadata, copy_source_index=source_index + 1,
                        copy_frame_offset=0)
                    continue
                raw, frame, next_offset = _catalog_group_source_frame(
                    container, source, metadata["copy_frame_offset"])
                selected = _catalog_group_bitmap_selected(
                    metadata["plan_bitmap_b64"], metadata["plan_total_slots"],
                    metadata["copy_slot_cursor"])
                scanned += 1
                if not selected:
                    metadata = dict(
                        metadata, copy_frame_offset=next_offset,
                        copy_slot_cursor=metadata["copy_slot_cursor"] + 1)
                    continue
                will = {
                    "source_index": source_index,
                    "source_generation": source["segment_generation"],
                    "source_offset": metadata["copy_frame_offset"],
                    "source_next_offset": next_offset,
                    "source_frame_digest": frame["digest"].hex(),
                    "frame_length": len(raw),
                    "scratch_offset": metadata["copy_bytes"],
                    "scratch_after": metadata["copy_bytes"] + len(raw),
                }
                metadata = dict(metadata, state="copy-will", copy_will=will)
                committed = _catalog_group_commit(
                    global_fd, recovery_fd, proof, metadata,
                    "group-copy-will")
                return {"state": "copy-will", "frames_scanned": scanned,
                        "frames_copied": 0, "idempotent": False, **committed}
            committed = _catalog_group_commit(
                global_fd, recovery_fd, proof, metadata,
                "group-copy-checkpoint")
            return {"state": "copying", "frames_scanned": scanned,
                    "frames_copied": 0, "idempotent": False, **committed}
        finally:
            os.close(global_fd); os.close(recovery_fd)


def _catalog_previs_cancel(container: Path, key: str | None, group_generation: int,
                            source_segment_generation: int, frame_offset: int,
                            frame_digest: str,
                            cell_index: int | None = None) -> dict:
    """Cancel one pre-visible reservation without applying a negative RELEASE."""
    if (group_generation < 1 or source_segment_generation < 1 or frame_offset < 0 or
            not isinstance(frame_digest, str) or not HEX64.fullmatch(frame_digest)):
        raise StateError("gc-internal", "PREVIS cancellation input is invalid", 5)
    if ((key is None) == (cell_index is None) or
            cell_index is not None and not 0 <= cell_index < CATALOG_CELL_COUNT):
        raise StateError("gc-internal", "PREVIS cancellation selector is invalid", 5)
    subject = _catalog_instance_subject(key) if key is not None else None
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_read = proof.pop("global_fd"); os.close(global_read)
        global_fd = os.open(os.fsencode(container / ".catalog-global-pack.v1"),
                            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(os.fsencode(container / ".catalog-recovery-pack.v1"),
                              os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            if (proof["root_meta"].get("state") != "migration-quiescing" or
                    proof["root_meta"].get("migration_group_generation") != group_generation or
                    proof["root_meta"].get("migration_source_segment_generation") !=
                        source_segment_generation):
                raise StateError("catalog-migration-pressure", "PREVIS group is not quiescing", 4, True)
            if cell_index is None:
                duplicate, _ = _catalog_find_instance_cell(global_fd, proof, key)
            else:
                duplicate = cell_index
            if duplicate is None:
                raise StateError("catalog-root-invalid", "PREVIS reservation mapping is absent", 4)
            index = duplicate
            selector = proof["root"][2][4096:5120]
            entry_bank, _, entry = _catalog_selected_entry(global_fd, selector, index)
            recovery_bank, _, recovery = _catalog_selected_recovery(recovery_fd, entry, index)
            if subject is None:
                subject = entry["fields"][0]
            if entry["state"] == 4:
                previs = recovery["payload"].get("_previs")
                if (not isinstance(previs, dict) or previs.get("group_generation") != group_generation or
                        previs.get("source_segment_generation") != source_segment_generation or
                        previs.get("frame_offset") != frame_offset or
                        previs.get("frame_digest") != frame_digest):
                    raise StateError("catalog-root-invalid", "PREVIS cancellation conflicts", 4)
                return {"state": "previs-cancelled", "cell_index": index,
                        "cancel_digest": previs["cancel_digest"], "idempotent": True}
            if (entry["state"] != 1 or recovery["state"] != 1 or
                    recovery["payload"].get("subject_digest") != subject.hex()):
                raise StateError("catalog-root-invalid", "PREVIS reservation is already visible", 4)
            core = {"schema_version": 1, "cell_index": index,
                    "cell_generation": recovery["generation"],
                    "subject_digest": subject.hex(),
                    "reservation_digest": recovery["payload"]["reservation_digest"],
                    "consumed_free_receipt_record_digest":
                        recovery["payload"]["consumed_free_receipt_record_digest"],
                    "group_generation": group_generation,
                    "source_segment_generation": source_segment_generation,
                    "frame_offset": frame_offset, "frame_digest": frame_digest}
            cancel_digest = _catalog_digest(
                b"zyz-previs-cancel-v1", _catalog_json(core))
            will = {**core, "cancel_digest": cancel_digest.hex()}
            observed_will = proof["root_meta"].get("previs_cancel_will")
            if observed_will is None:
                _catalog_root_successor(global_fd, recovery_fd, proof, selector,
                                        {"previs_cancel_will": will},
                                        "will-previsibility-cancel")
                proof = _catalog_validate_genesis(container)
                os.close(proof.pop("global_fd"))
                selector = proof["root"][2][4096:5120]
                entry_bank, _, entry = _catalog_selected_entry(global_fd, selector, index)
                recovery_bank, _, recovery = _catalog_selected_recovery(recovery_fd, entry, index)
            elif observed_will != will:
                raise StateError("catalog-root-invalid", "PREVIS cancellation will conflicts", 4)
            region = _catalog_recovery_previs_region(
                group_generation, source_segment_generation, frame_offset,
                bytes.fromhex(frame_digest), cancel_digest,
                bytes.fromhex(recovery["payload"]["consumed_free_receipt_record_digest"]))
            payload = dict(recovery["payload"], state="PREVIS_CANCELLED",
                           object_identities_digest=None, _operation_region=region)
            payload.pop("_operations", None); payload.pop("_flush", None); payload.pop("_previs", None)
            cancelled = _catalog_recovery_dynamic_image(
                index, 8, recovery["generation"] + 1, payload)
            cancelled_digest = _catalog_digest(b"zyz-recovery-cell-selected-v1", cancelled)
            next_recovery_bank = 1 - recovery_bank
            recovery_offset = (index * CATALOG_RECOVERY_CELL_SIZE +
                               next_recovery_bank * CATALOG_RECOVERY_IMAGE_SIZE)
            observed = _catalog_pread_exact(recovery_fd, CATALOG_RECOVERY_IMAGE_SIZE,
                                            recovery_offset)
            if observed != cancelled:
                if observed != bytes(CATALOG_RECOVERY_IMAGE_SIZE):
                    parsed = _catalog_parse_recovery_image(observed, index)
                    if parsed["generation"] >= recovery["generation"] + 1:
                        raise StateError("catalog-root-invalid", "PREVIS CELL successor conflicts", 4)
                _catalog_pwrite_all(recovery_fd, cancelled, recovery_offset,
                                    "PREVIS cancelled CELL")
                _data_sync(recovery_fd)
            _catalog_barrier("catalog-recovery", "previsibility-cancelled")
            next_entry_bank = 1 - entry_bank
            base = (CATALOG_LAYOUT["cell_directory_a"][0] if next_entry_bank == 0
                    else CATALOG_LAYOUT["cell_directory_b"][0])
            directory = _catalog_directory_image(
                index, 4, recovery["generation"] + 1, entry["free_generation"],
                (subject, cancelled_digest, entry["fields"][2], entry["fields"][3],
                 cancel_digest))
            directory_offset = base + index * CATALOG_DIRECTORY_IMAGE_SIZE
            observed_directory = _catalog_pread_exact(
                global_fd, CATALOG_DIRECTORY_IMAGE_SIZE, directory_offset)
            if observed_directory != directory:
                if observed_directory != bytes(CATALOG_DIRECTORY_IMAGE_SIZE):
                    parsed_directory = _catalog_parse_directory_image(observed_directory, index)
                    if parsed_directory["cell_generation"] >= recovery["generation"] + 1:
                        raise StateError("catalog-root-invalid", "PREVIS directory successor conflicts", 4)
                _catalog_pwrite_all(global_fd, directory, directory_offset,
                                    "PREVIS cancelled directory")
                _data_sync(global_fd)
            selector = _catalog_selector_set(selector, index, next_entry_bank)
            successor = _catalog_root_successor(
                global_fd, recovery_fd, proof, selector,
                {"previs_cancel_will": None,
                 "previs_cancel_count": proof["root_meta"].get("previs_cancel_count", 0) + 1},
                "did-previsibility-cancel")
            return {"state": "previs-cancelled", "cell_index": index,
                    "cancel_digest": cancel_digest.hex(),
                    "root_digest": successor["digest"].hex(), "idempotent": False}
        finally:
            os.close(global_fd); os.close(recovery_fd)


def _catalog_quiesce_claim_visibility(container: Path, proof: dict, key: str,
                                       cell_index: int,
                                       reservation_digest: str) -> dict:
    """Find the unique committed did-claim frame in the frozen source chain."""
    if not key.startswith("claim.") or not HEX64.fullmatch(key[6:]):
        raise StateError("catalog-root-invalid", "quiesce claim key is invalid", 4)
    key_digest = key[6:]
    cutoff = proof["root_meta"].get("migration_creator_cutoff")
    if not isinstance(cutoff, int) or cutoff < 0:
        raise StateError("catalog-root-invalid", "quiesce creator cutoff is invalid", 4)
    matches = []
    for member in proof["chain"]["members"]:
        fd = os.open(os.fsencode(container / member["basename"]), os.O_RDONLY |
                     getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
        try:
            cursor = 0
            while cursor < member["used_length"]:
                header = _catalog_pread_exact(fd, 20, cursor)
                if header[0:8] != b"ZYZFRM1\0":
                    raise StateError("catalog-root-invalid",
                                     "quiesce source frame magic is invalid", 4)
                total = struct.unpack_from(">I", header, 16)[0]
                if (total < 64 or total % 8 or
                        cursor + total > member["used_length"]):
                    raise StateError("catalog-root-invalid",
                                     "quiesce source frame length is invalid", 4)
                frame = _catalog_parse_frame(
                    _catalog_pread_exact(fd, total, cursor))
                cursor += total
                if frame["kind"] != "claim":
                    continue
                payload = frame["payload"]
                if payload.get("logical_key_sha256") != key_digest:
                    continue
                if (payload.get("claim_pack_basename") !=
                        f"{key_digest}.claim-pack.v1" or
                        payload.get("recovery_cell_index") != cell_index or
                        payload.get("reservation_digest") != reservation_digest or
                        not isinstance(payload.get("sequence"), int) or
                        not 1 <= payload["sequence"] <= cutoff):
                    raise StateError("catalog-root-invalid",
                                     "quiesce did-claim binding conflicts", 4)
                matches.append(frame["digest"].hex())
        finally:
            os.close(fd)
    if len(matches) > 1:
        raise StateError("catalog-root-invalid", "duplicate quiesce did-claim", 4)
    return {"kind": "did-claim", "committed": bool(matches),
            "marker_digest": matches[0] if matches else None}


def _catalog_quiesce_visibility(container: Path, proof: dict, key: str,
                                 cell_index: int,
                                 reservation_digest: str) -> dict:
    if key.startswith("claim."):
        return _catalog_quiesce_claim_visibility(
            container, proof, key, cell_index, reservation_digest)
    try:
        start = _instance_pack_read(container, key, "audit", "START")
    except FileNotFoundError:
        start = None
    if start is None:
        return {"kind": "START", "committed": False,
                "marker_digest": None}
    if (not isinstance(start, dict) or start.get("schema_version") != 1 or
            start.get("instance_key") != key):
        raise StateError("catalog-root-invalid", "quiesce START marker conflicts", 4)
    return {"kind": "START", "committed": True,
            "marker_digest": _catalog_digest(
                b"zyz-quiesce-start-marker-v1", _catalog_json(start)).hex()}


def _catalog_quiesce_objects(container: Path, key: str, reservation: dict,
                              expected_digest: str) -> list[dict]:
    identities = _instance_validate_reserved_objects(
        container, reservation, expected_digest)
    if key.startswith("claim."):
        order = list(identities)
    else:
        # START lives in audit.  Retire it last so every earlier unlink can
        # still prove that the immutable commit marker did not appear.
        object_set = reservation["object_set"]
        order = [object_set["lock"], object_set["work"], object_set["audit"]]
    objects = [{"basename": name, "expected_size": identities[name]["size"],
                "identity": identities[name], "prior": "present",
                "after": "absent"} for name in order]
    digest = _catalog_digest(
        b"zyz-instance-object-identities-v1", _catalog_json(identities)).hex()
    if not hmac.compare_digest(digest, expected_digest):
        raise StateError("catalog-root-invalid",
                         "quiesce object identity set conflicts", 4)
    return objects


def _catalog_quiesce_idle_metadata(work: dict,
                                    migration_generation: int) -> dict:
    return {
        "schema_version": 1, "state": "idle",
        "work_generation": work["work_generation"] + 1,
        "migration_generation": migration_generation,
        "cell_index": None, "cell_generation": None, "creator_key": None,
        "subject_digest": None, "request_bytes": None,
        "reservation_digest": None, "object_identities_digest": None,
        "commit_visibility": None, "objects": [], "delete_cursor": 0,
        "deleted_count": 0, "release_phase": None,
        "counter_prior": None, "counter_after": None,
    }


def _catalog_quiesce_plan_one(container: Path) -> dict:
    """Freeze one OWNER_ACTIVE creator, ACKing a missing CELL ACK first."""
    while True:
        ack = None
        with CatalogFlock(container):
            proof = _catalog_validate_genesis(container)
            global_read = proof.pop("global_fd"); os.close(global_read)
            global_fd = os.open(
                os.fsencode(container / ".catalog-global-pack.v1"),
                os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
            recovery_fd = os.open(
                os.fsencode(container / ".catalog-recovery-pack.v1"),
                os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
            try:
                root = proof["root_meta"]
                work = proof["quiesce_work_meta"]
                if (root.get("state") != "migration-quiescing" or
                        root.get("admission_state") != "closed"):
                    raise StateError("catalog-root-invalid",
                                     "quiesce work prior is invalid", 4)
                if work["state"] != "idle":
                    return {"state": work["state"], "planned": False}
                cursor = root.get("migration_scan_cursor")
                if not isinstance(cursor, int) or not 0 <= cursor <= CATALOG_CELL_COUNT:
                    raise StateError("catalog-root-invalid",
                                     "quiesce creator cursor is invalid", 4)
                selector = proof["root"][2][4096:5120]
                candidate = None
                for index in range(cursor, CATALOG_CELL_COUNT):
                    _, _, entry = _catalog_selected_entry(global_fd, selector, index)
                    if entry["state"] != 2:
                        continue
                    _, _, recovery = _catalog_selected_recovery(
                        recovery_fd, entry, index)
                    payload = recovery["payload"]
                    if (recovery["state"] not in (2, 3) or
                            payload.get("state") not in
                                ("OWNER_ACTIVE", "ACTIVE_ACK")):
                        continue
                    key = payload.get("_creator_key")
                    request = payload.get("_request_bytes")
                    if (not isinstance(key, str) or
                            _catalog_instance_subject(key) != entry["fields"][0] or
                            not isinstance(request, int) or request < 1 or
                            payload.get("reservation_digest") !=
                                entry["fields"][2].hex() or
                            payload.get("object_identities_digest") !=
                                entry["fields"][4].hex()):
                        raise StateError("catalog-root-invalid",
                                         "quiesce creator locator conflicts", 4)
                    object_set = _catalog_instance_object_set(key, request)
                    reservation = {
                        "cell_index": index,
                        "cell_generation": recovery["generation"],
                        "recovery_bank": 0, "directory_bank": 0,
                        "reservation_digest": payload["reservation_digest"],
                        "subject_digest": payload["subject_digest"],
                        "object_set": object_set,
                        "root_digest": proof["root"][3][3].hex(),
                        "resume_state": ("owner-active" if
                            payload["state"] == "OWNER_ACTIVE" else "active-ack"),
                        "object_identities_digest":
                            payload["object_identities_digest"],
                        "event_matches": True,
                    }
                    if payload["state"] == "OWNER_ACTIVE":
                        ack = (key, reservation)
                        break
                    candidate = (index, entry, recovery, key, request,
                                 reservation)
                    break
                if ack is not None:
                    pass
                elif candidate is None:
                    if cursor < CATALOG_CELL_COUNT:
                        metadata = _catalog_quiesce_idle_metadata(
                            work, root["migration_generation"])
                        result = _catalog_quiesce_work_commit(
                            global_fd, recovery_fd, proof, metadata,
                            "quiesce-scan-complete",
                            {"migration_scan_cursor": CATALOG_CELL_COUNT})
                        return {"state": "quiesced", "planned": False,
                                "cursor": CATALOG_CELL_COUNT, **result}
                    return {"state": "quiesced", "planned": False,
                            "cursor": cursor}
                else:
                    index, entry, recovery, key, request, reservation = candidate
                    visibility = _catalog_quiesce_visibility(
                        container, proof, key, index,
                        reservation["reservation_digest"])
                    objects = _catalog_quiesce_objects(
                        container, key, reservation,
                        reservation["object_identities_digest"])
                    metadata = {
                        "schema_version": 1, "state": "planned",
                        "work_generation": work["work_generation"] + 1,
                        "migration_generation": root["migration_generation"],
                        "cell_index": index,
                        "cell_generation": recovery["generation"],
                        "creator_key": key,
                        "subject_digest": entry["fields"][0].hex(),
                        "request_bytes": request,
                        "reservation_digest": reservation["reservation_digest"],
                        "object_identities_digest":
                            reservation["object_identities_digest"],
                        "commit_visibility": visibility, "objects": objects,
                        "delete_cursor": 0, "deleted_count": 0,
                        "release_phase": None, "counter_prior": None,
                        "counter_after": None,
                    }
                    _catalog_quiesce_work_validate(metadata)
                    result = _catalog_quiesce_work_commit(
                        global_fd, recovery_fd, proof, metadata,
                        "quiesce-work-planned")
                    return {"state": "planned", "planned": True,
                            "cell_index": index, **result}
            finally:
                os.close(global_fd); os.close(recovery_fd)
        if ack is not None:
            key, reservation = ack
            _catalog_instance_cell_transition(
                container, key, reservation, "cell-active-ack")
            _catalog_barrier("catalog-migration-quiesce",
                             "owner-active-ack-recovered")


def _catalog_quiesce_assert_objects(container: Path, work: dict,
                                     allow_current_absent: bool) -> bool:
    """Validate every frozen object against its exact cursor prior/after set."""
    current_absent = False
    cursor = work["delete_cursor"]
    for index, item in enumerate(work["objects"]):
        try:
            observed = _catalog_object_identity(
                container, item["basename"], item["expected_size"])
        except FileNotFoundError:
            if index < cursor:
                continue
            if allow_current_absent and index == cursor:
                current_absent = True
                continue
            raise StateError("catalog-root-invalid",
                             "quiesce object is absent without matching will", 4)
        if index < cursor:
            raise StateError("catalog-root-invalid",
                             "quiesce deleted object reappeared", 4)
        if observed != item["identity"]:
            raise StateError("catalog-root-invalid",
                             "quiesce object identity changed", 4)
    return current_absent


def _catalog_quiesce_visibility_unchanged(container: Path, proof: dict,
                                           work: dict) -> None:
    observed = _catalog_quiesce_visibility(
        container, proof, work["creator_key"], work["cell_index"],
        work["reservation_digest"])
    if observed != work["commit_visibility"]:
        raise StateError("catalog-root-invalid",
                         "quiesce creator commit marker appeared", 4)


def _catalog_quiesce_advance_one(container: Path) -> dict:
    """Advance one authenticated creator work item to its next durable phase."""
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_read = proof.pop("global_fd"); os.close(global_read)
        global_fd = os.open(
            os.fsencode(container / ".catalog-global-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(
            os.fsencode(container / ".catalog-recovery-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            work = proof["quiesce_work_meta"]
            state = work["state"]
            if state == "idle":
                return {"state": "idle", "advanced": False}
            if state == "planned":
                _catalog_quiesce_assert_objects(container, work, False)
                _catalog_quiesce_visibility_unchanged(container, proof, work)
                if work["commit_visibility"]["committed"]:
                    metadata = dict(work, state="committed",
                                    work_generation=work["work_generation"] + 1)
                    result = _catalog_quiesce_work_commit(
                        global_fd, recovery_fd, proof, metadata,
                        "quiesce-committed-creator-retained")
                    return {"state": "committed", "advanced": True, **result}
                metadata = dict(work, state="deleting",
                                work_generation=work["work_generation"] + 1)
                result = _catalog_quiesce_work_commit(
                    global_fd, recovery_fd, proof, metadata,
                    "quiesce-delete-will")
                return {"state": "deleting", "advanced": True, **result}
            if state == "deleting":
                absent = _catalog_quiesce_assert_objects(container, work, True)
                _catalog_quiesce_visibility_unchanged(container, proof, work)
                cursor = work["delete_cursor"]
                if cursor == len(work["objects"]):
                    metadata = dict(work, state="deleted",
                                    work_generation=work["work_generation"] + 1)
                    result = _catalog_quiesce_work_commit(
                        global_fd, recovery_fd, proof, metadata,
                        "quiesce-all-objects-deleted")
                    return {"state": "deleted", "advanced": True, **result}
                if not absent:
                    item = work["objects"][cursor]
                    parent_fd = os.open(
                        os.fsencode(container), os.O_RDONLY |
                        getattr(os, "O_DIRECTORY", 0) |
                        getattr(os, "O_NOFOLLOW", 0) |
                        getattr(os, "O_CLOEXEC", 0))
                    try:
                        os.unlink(os.fsencode(item["basename"]), dir_fd=parent_fd)
                        os.fsync(parent_fd)
                    finally:
                        os.close(parent_fd)
                    _catalog_barrier(
                        "catalog-migration-quiesce",
                        f"post-object-delete-{cursor}")
                metadata = dict(
                    work, work_generation=work["work_generation"] + 1,
                    delete_cursor=cursor + 1, deleted_count=cursor + 1)
                result = _catalog_quiesce_work_commit(
                    global_fd, recovery_fd, proof, metadata,
                    "quiesce-delete-cursor")
                return {"state": "deleting", "advanced": True,
                        "deleted": not absent,
                        "entries_deleted": int(not absent),
                        "bytes_reclaimed": (work["objects"][cursor]["expected_size"]
                                            if not absent else 0),
                        **result}
            if state == "deleted":
                _catalog_quiesce_assert_objects(container, work, False)
                root = proof["root_meta"]
                prior = {name: root.get(name) for name in
                         ("owned_bytes", "active_claims", "active_data_claims",
                          "counter_generation")}
                if (any(not isinstance(value, int) or value < 0
                        for value in prior.values()) or
                        prior["owned_bytes"] - work["request_bytes"] <
                            CATALOG_GENESIS_FLOOR or prior["active_claims"] < 1 or
                        (work["creator_key"].startswith("claim.") and
                         prior["active_data_claims"] < 1)):
                    raise StateError("catalog-root-invalid",
                                     "quiesce RELEASE counters are invalid", 4)
                after = dict(prior,
                             owned_bytes=prior["owned_bytes"] -
                                work["request_bytes"],
                             active_claims=prior["active_claims"] - 1,
                             counter_generation=prior["counter_generation"] + 1)
                if work["creator_key"].startswith("claim."):
                    after["active_data_claims"] -= 1
                metadata = dict(
                    work, state="release-will", release_phase="release-will",
                    work_generation=work["work_generation"] + 1,
                    counter_prior=prior, counter_after=after)
                result = _catalog_quiesce_work_commit(
                    global_fd, recovery_fd, proof, metadata,
                    "quiesce-release-will")
                return {"state": "release-will", "advanced": True, **result}
            if state == "release-applied":
                root = proof["root_meta"]
                if any(root.get(name) != value
                       for name, value in work["counter_after"].items()):
                    raise StateError("catalog-root-invalid",
                                     "quiesce RELEASE after counters changed", 4)
                metadata = dict(work, state="committed",
                                release_phase="committed",
                                work_generation=work["work_generation"] + 1)
                result = _catalog_quiesce_work_commit(
                    global_fd, recovery_fd, proof, metadata,
                    "quiesce-retire-committed")
                return {"state": "committed", "advanced": True, **result}
            if state == "committed":
                next_cursor = work["cell_index"] + 1
                metadata = _catalog_quiesce_idle_metadata(
                    work, proof["root_meta"]["migration_generation"])
                result = _catalog_quiesce_work_commit(
                    global_fd, recovery_fd, proof, metadata,
                    "quiesce-work-consumed",
                    {"migration_scan_cursor": next_cursor})
                return {"state": "idle", "advanced": True,
                        "cursor": next_cursor, **result}
            if state != "release-will":
                raise StateError("catalog-root-invalid",
                                 "quiesce work phase is invalid", 4)
            prior = work["counter_prior"]
            root = proof["root_meta"]
            operations = None
            selector = proof["root"][2][4096:5120]
            _, _, entry = _catalog_selected_entry(
                global_fd, selector, work["cell_index"])
            _, _, recovery = _catalog_selected_recovery(
                recovery_fd, entry, work["cell_index"])
            operations = recovery["payload"].get("_operations", {})
            release = operations.get("RELEASE")
            if release is None and any(root.get(name) != value
                                       for name, value in prior.items()):
                raise StateError("catalog-root-invalid",
                                 "quiesce RELEASE prior counters changed", 4)
        finally:
            os.close(global_fd); os.close(recovery_fd)

    # The standard fixed CELL/ROOT RELEASE machine owns its own catalog lock
    # and can resume either a will or applied image after a killed invocation.
    _catalog_instance_delta(
        container, work["creator_key"], "RELEASE", -work["request_bytes"])
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_read = proof.pop("global_fd"); os.close(global_read)
        global_fd = os.open(
            os.fsencode(container / ".catalog-global-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(
            os.fsencode(container / ".catalog-recovery-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            current = proof["quiesce_work_meta"]
            if (current != work or current["state"] != "release-will" or
                    any(proof["root_meta"].get(name) != value
                        for name, value in work["counter_after"].items())):
                raise StateError("catalog-root-invalid",
                                 "quiesce RELEASE applied state conflicts", 4)
            metadata = dict(
                work, state="release-applied", release_phase="release-applied",
                work_generation=work["work_generation"] + 1)
            result = _catalog_quiesce_work_commit(
                global_fd, recovery_fd, proof, metadata,
                "quiesce-release-applied")
            return {"state": "release-applied", "advanced": True, **result}
        finally:
            os.close(global_fd); os.close(recovery_fd)


def _catalog_quiesce_retire_active(container: Path, limit: int = 64) -> dict:
    """Advance at most ``limit`` creator transactions without public wiring."""
    if not 1 <= limit <= 64:
        raise StateError("gc-internal", "quiesce active limit is invalid", 5)
    completed = 0
    transitions = 0
    entries_deleted = 0
    bytes_reclaimed = 0
    while completed < limit:
        planned = _catalog_quiesce_plan_one(container)
        if planned["state"] == "quiesced":
            transitions += int("root_digest" in planned)
            return {"state": "quiesced", "completed": completed,
                    "transactions_advanced": transitions,
                    "entries_deleted": entries_deleted,
                    "bytes_reclaimed": bytes_reclaimed, "more": False}
        while True:
            result = _catalog_quiesce_advance_one(container)
            transitions += int(result.get("advanced", False))
            entries_deleted += result.get("entries_deleted", 0)
            bytes_reclaimed += result.get("bytes_reclaimed", 0)
            if result["state"] == "idle":
                completed += 1
                break
    return {"state": "quiescing", "completed": completed,
            "transactions_advanced": transitions,
            "entries_deleted": entries_deleted,
            "bytes_reclaimed": bytes_reclaimed, "more": True}


def _catalog_quiesce_cancel_previsible(container: Path, limit: int = 64) -> dict:
    """Cancel at most ``limit`` reserved creators from the frozen cutoff."""
    if not 1 <= limit <= 64:
        raise StateError("gc-internal", "migration quiesce limit is invalid", 5)
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_fd = proof.pop("global_fd")
        recovery_fd = os.open(
            os.fsencode(container / ".catalog-recovery-pack.v1"),
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            root = proof["root_meta"]
            group = proof["group_meta"]
            if (root.get("state") != "migration-quiescing" or
                    root.get("admission_state") != "closed" or
                    group.get("state") != "new-source-initialized"):
                raise StateError("catalog-root-invalid",
                                 "migration quiesce scan prior is invalid", 4)
            selector = proof["root"][2][4096:5120]
            reserved = []
            incomplete_active = []
            for index in range(CATALOG_CELL_COUNT):
                _, _, entry = _catalog_selected_entry(global_fd, selector, index)
                if entry["state"] == 0 or entry["state"] == 4:
                    continue
                _, _, recovery = _catalog_selected_recovery(
                    recovery_fd, entry, index)
                payload_state = recovery["payload"].get("state")
                creator_key = recovery["payload"].get("_creator_key")
                request_bytes = recovery["payload"].get("_request_bytes")
                if entry["state"] in (1, 2) and (
                        not isinstance(creator_key, str) or
                        _catalog_instance_subject(creator_key) !=
                            entry["fields"][0] or
                        not isinstance(request_bytes, int) or
                        request_bytes < 1):
                    raise StateError("catalog-root-invalid",
                                     "migration creator locator conflicts", 4)
                if entry["state"] == 1 and recovery["state"] == 1 and \
                        payload_state == "RESERVED":
                    if len(reserved) < limit:
                        material = _catalog_json({
                            "cell_index": index,
                            "cell_generation": recovery["generation"],
                            "subject_digest": entry["fields"][0].hex(),
                            "reservation_digest":
                                recovery["payload"].get("reservation_digest"),
                            "creator_key": creator_key,
                            "request_bytes": request_bytes,
                            "source_segment_generation":
                                group["source_segment_generation"],
                            "source_used_length":
                                group["source_segments"][0]["used_length"],
                        })
                        reserved.append({
                            "cell_index": index,
                            "frame_offset":
                                group["source_segments"][0]["used_length"],
                            "frame_digest": _catalog_digest(
                                b"zyz-previsibility-absent-frame-v1",
                                material).hex(),
                        })
                elif (entry["state"] == 2 and recovery["state"] in (2, 3) and
                      payload_state in ("OWNER_ACTIVE", "ACTIVE_ACK")):
                    incomplete_active.append({
                        "cell_index": index, "creator_key": creator_key,
                        "request_bytes": request_bytes,
                        "reservation_digest":
                            recovery["payload"].get("reservation_digest"),
                        "object_identities_digest":
                            recovery["payload"].get("object_identities_digest"),
                    })
                elif entry["state"] not in (2, 3):
                    raise StateError("catalog-root-invalid",
                                     "migration quiesce CELL state is invalid", 4)
        finally:
            os.close(global_fd)
            os.close(recovery_fd)
    advanced = 0
    for item in reserved:
        _catalog_previs_cancel(
            container, None, group["group_generation"],
            group["source_segment_generation"], item["frame_offset"],
            item["frame_digest"], cell_index=item["cell_index"])
        advanced += 1
    reserved_advanced = advanced
    active_result = {"completed": 0, "transactions_advanced": 0,
                     "entries_deleted": 0, "bytes_reclaimed": 0}
    if reserved_advanced == 0:
        active_result = _catalog_quiesce_retire_active(container, limit)
        advanced += active_result["completed"]
    with CatalogFlock(container):
        refreshed = _catalog_validate_genesis(container)
        refreshed_global = refreshed.pop("global_fd")
        refreshed_recovery = os.open(
            os.fsencode(container / ".catalog-recovery-pack.v1"),
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            selector = refreshed["root"][2][4096:5120]
            active_cursor = refreshed["root_meta"].get("migration_scan_cursor")
            if (not isinstance(active_cursor, int) or
                    not 0 <= active_cursor <= CATALOG_CELL_COUNT):
                raise StateError("catalog-root-invalid",
                                 "migration active scan cursor is invalid", 4)
            remaining_reserved = 0
            remaining_incomplete_active = 0
            for index in range(CATALOG_CELL_COUNT):
                _, _, entry = _catalog_selected_entry(
                    refreshed_global, selector, index)
                if entry["state"] not in (1, 2):
                    continue
                _, _, recovery = _catalog_selected_recovery(
                    refreshed_recovery, entry, index)
                state = recovery["payload"].get("state")
                if entry["state"] == 1 and state == "RESERVED":
                    remaining_reserved += 1
                elif (index >= active_cursor and entry["state"] == 2 and
                      recovery["state"] in (2, 3) and
                      state in ("OWNER_ACTIVE", "ACTIVE_ACK")):
                    remaining_incomplete_active += 1
        finally:
            os.close(refreshed_global)
            os.close(refreshed_recovery)
    return {
        "state": "quiescing" if (remaining_reserved or
                                  remaining_incomplete_active) else "quiesced",
        "advanced": advanced,
        "active_transactions_advanced":
            active_result["transactions_advanced"],
        "transactions_advanced": reserved_advanced +
            active_result["transactions_advanced"],
        "entries_deleted": active_result["entries_deleted"],
        "bytes_reclaimed": active_result["bytes_reclaimed"],
        "remaining_reserved": remaining_reserved,
        "remaining_incomplete_active": remaining_incomplete_active,
        "more": bool(remaining_reserved or remaining_incomplete_active),
        "blocked": False,
    }


def _catalog_previs_group_visible(container: Path, group_generation: int,
                                   source_segment_generation: int) -> dict:
    """Atomically replace the planned source range with the copied scratch."""
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_read = proof.pop("global_fd"); os.close(global_read)
        global_fd = os.open(os.fsencode(container / ".catalog-global-pack.v1"),
                            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(os.fsencode(container / ".catalog-recovery-pack.v1"),
                              os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            group = proof["group_meta"]
            if (group.get("group_generation") != group_generation or
                    group.get("source_segment_generation") != source_segment_generation):
                raise StateError("catalog-root-invalid", "PREVIS group identity conflicts", 4)
            if group.get("state") in ("group-visible", "freeing", "previs-cells-consumed",
                                     "old-source-retired"):
                return {"state": group["state"],
                        "group_visible_digest": group["group_visible_digest"],
                        "cancel_count": group["cancel_count"], "idempotent": True}
            if group.get("state") not in ("copied", "cutover-will"):
                raise StateError("catalog-root-invalid", "group cutover phase is invalid", 4)
            selector = proof["root"][2][4096:5120]
            accumulator = hashlib.sha256(b"zyz-previs-cancel-set-v1")
            count = 0
            for index in range(CATALOG_CELL_COUNT):
                _, _, entry = _catalog_selected_entry(global_fd, selector, index)
                if entry["state"] != 4:
                    continue
                _, _, recovery = _catalog_selected_recovery(recovery_fd, entry, index)
                previs = recovery["payload"].get("_previs")
                if (not isinstance(previs, dict) or
                        previs.get("group_generation") != group_generation or
                        previs.get("source_segment_generation") != source_segment_generation):
                    continue
                accumulator.update(struct.pack(">I", index))
                accumulator.update(bytes.fromhex(previs["cancel_digest"]))
                accumulator.update(bytes.fromhex(
                    recovery["payload"]["consumed_free_receipt_record_digest"]))
                count += 1
            if count != proof["root_meta"].get("previs_cancel_count"):
                raise StateError("catalog-root-invalid", "PREVIS cancel-set count conflicts", 4)
            cancel_set_digest = accumulator.digest()
            sources = group.get("source_segments")
            if (not isinstance(sources, list) or not sources or
                    sources[0].get("segment_generation") !=
                        source_segment_generation or
                    any(sources[position].get("logical_last_generation") + 1 !=
                        sources[position + 1].get("logical_first_generation")
                        for position in range(len(sources) - 1))):
                raise StateError("catalog-root-invalid",
                                 "group cutover source set is invalid", 4)
            first = sources[0]["logical_first_generation"]
            last = sources[-1]["logical_last_generation"]
            chain = proof["chain"]
            matched = [member for member in chain["members"]
                       if (first <= member.get(
                               "logical_last_generation",
                               member["generation"]) and
                           member.get("logical_first_generation",
                                      member["generation"]) <= last)]
            expected_sources = [_catalog_migration_source_fact(member)
                                for member in matched]
            if expected_sources != sources:
                raise StateError("catalog-root-invalid",
                                 "group cutover source identities changed", 4)
            scratch = _catalog_segment_chain_projection(
                container, group["scratch_basename"], 0)
            if (scratch["identity_digest"] !=
                    group.get("copied_scratch_identity") or
                    scratch["descriptor_digest"] !=
                    group.get("copied_scratch_descriptor_digest") or
                    scratch["used_length"] != group.get("planned_frame_bytes")):
                raise StateError("catalog-root-invalid",
                                 "group cutover scratch changed", 4)
            anchor = {
                "schema_version": 1, "kind": "scratch-object",
                "first_generation": first, "last_generation": last,
                "basename": scratch["basename"],
                "identity_digest": scratch["identity_digest"],
                "descriptor_digest": scratch["descriptor_digest"],
                "descriptor_generation": scratch["descriptor_generation"],
                "used_length": scratch["used_length"],
                "plan_digest": group["planned_frame_digest"],
                "source_group_digest": group["source_group_digest"],
                "cancel_set_digest": cancel_set_digest.hex(),
            }
            entries = []
            inserted = False
            for prior in chain["entries"]:
                prior_first = prior["first_generation"]
                prior_last = prior["last_generation"]
                if prior_last < first:
                    entries.append(prior)
                    continue
                if prior_first > last:
                    if not inserted:
                        entries.append(anchor); inserted = True
                    entries.append(prior)
                    continue
                if prior.get("kind") != "segment-range":
                    if prior_first < first or prior_last > last:
                        raise StateError(
                            "catalog-root-invalid",
                            "group cutover partially overlaps scratch anchor", 4)
                    if not inserted:
                        entries.append(anchor); inserted = True
                    continue
                if prior_first < first:
                    entries.append(_catalog_chain_range_anchor(
                        container, prior_first, first - 1))
                if not inserted:
                    entries.append(anchor); inserted = True
                if prior_last > last:
                    entries.append(_catalog_chain_range_anchor(
                        container, last + 1, prior_last))
            if not inserted:
                entries.append(anchor)
            chain_region, chain_digest = _catalog_chain_region(
                entries, chain["generation"] + 1,
                bytes.fromhex(chain["digest"]))
            visible_core = (_catalog_json({
                "group_generation": group_generation,
                "source_group_digest": group["source_group_digest"],
                "plan_digest": group["planned_frame_digest"],
                "scratch_identity_digest": scratch["identity_digest"],
                "scratch_descriptor_digest": scratch["descriptor_digest"],
                "cancel_count": count,
                "cancel_set_digest": cancel_set_digest.hex(),
                "prior_chain_digest": chain["digest"],
                "after_chain_digest": chain_digest,
            }))
            visible_digest = _catalog_digest(b"zyz-previs-group-visible-v1", visible_core)
            will = {
                "source_group_digest": group["source_group_digest"],
                "plan_digest": group["planned_frame_digest"],
                "scratch_identity_digest": scratch["identity_digest"],
                "scratch_descriptor_digest": scratch["descriptor_digest"],
                "cancel_set_digest": cancel_set_digest.hex(),
                "prior_chain_digest": chain["digest"],
                "after_chain_digest": chain_digest,
                "group_visible_digest": visible_digest.hex(),
            }
            if group["state"] == "copied":
                metadata = dict(group, state="cutover-will",
                                cancel_count=count,
                                cancel_set_digest=cancel_set_digest.hex(),
                                cutover_will=will)
                result = _catalog_group_commit(
                    global_fd, recovery_fd, proof, metadata,
                    "group-cutover-will")
                return {"state": "cutover-will", "idempotent": False,
                        **result}
            if group.get("cutover_will") != will:
                raise StateError("catalog-root-invalid",
                                 "group cutover will conflicts", 4)
            metadata = dict(group, state="group-visible", cancel_count=count,
                            cancel_set_digest=cancel_set_digest.hex(), free_count=0,
                            consumed_digest=_catalog_digest(b"zyz-previs-consumed-v1", b"").hex(),
                            group_visible_digest=visible_digest.hex(),
                            cutover_will=None,
                            visible_chain_digest=chain_digest,
                            visible_scratch_anchor=anchor)
            successor_group = _catalog_group_successor(global_fd, proof, metadata)
            parsed_after = _catalog_parse_chain_region(container, chain_region)
            first_member = parsed_after["members"][0]
            last_member = parsed_after["members"][-1]
            successor = _catalog_root_successor(
                global_fd, recovery_fd, proof, selector,
                {"state": "migration-active",
                 "group_control_digest": successor_group["digest"].hex(),
                 "previs_group_visible_digest": visible_digest.hex(),
                 "first_active_segment_generation": first_member["generation"],
                 "active_segment_generation": last_member["generation"],
                 "active_segment_used_length": last_member["used_length"],
                 "active_segment_descriptor_digest":
                    last_member["descriptor_digest"],
                 "sweep_cutoff_sequence": 0,
                 "sweep_segment_generation": first_member["generation"],
                 "sweep_start_segment_generation": first_member["generation"],
                 "sweep_offset": 0},
                "group-visible", chain_region)
            _catalog_barrier("catalog-migration-group", "group-visible")
            return {"state": "group-visible", "group_visible_digest": visible_digest.hex(),
                    "cancel_count": count, "root_digest": successor["digest"].hex(),
                    "idempotent": False}
        finally:
            os.close(global_fd); os.close(recovery_fd)


def _catalog_previs_free(container: Path, key: str | None, group_generation: int,
                         cell_index: int | None = None) -> dict:
    """Install one PREVIS FREE_RECEIPT and consume its group reference."""
    if (key is None) == (cell_index is None):
        raise StateError("gc-internal", "PREVIS free selector is invalid", 5)
    subject = _catalog_instance_subject(key) if key is not None else None
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_read = proof.pop("global_fd"); os.close(global_read)
        global_fd = os.open(os.fsencode(container / ".catalog-global-pack.v1"),
                            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(os.fsencode(container / ".catalog-recovery-pack.v1"),
                              os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            if key is None:
                duplicate = cell_index
            else:
                duplicate, _ = _catalog_find_instance_cell(global_fd, proof, key)
            if duplicate is None:
                if subject is None:
                    raise StateError("catalog-root-invalid",
                                     "PREVIS cell mapping is absent", 4)
                if proof["root_meta"].get("last_previs_freed_subject_digest") == subject.hex():
                    return {"state": "previs-free", "idempotent": True,
                            "free_receipt_record_digest":
                                proof["root_meta"].get("last_previs_free_receipt_record_digest")}
                raise StateError("catalog-root-invalid", "PREVIS owner mapping is absent", 4)
            index = duplicate
            selector = proof["root"][2][4096:5120]
            entry_bank, _, entry = _catalog_selected_entry(global_fd, selector, index)
            recovery_bank, _, recovery = _catalog_selected_recovery(recovery_fd, entry, index)
            if subject is None:
                subject = entry["fields"][0]
            previs = recovery["payload"].get("_previs")
            group = proof["group_meta"]
            if (entry["state"] != 4 or recovery["state"] != 8 or
                    not isinstance(previs, dict) or previs.get("phase") != "cancelled" or
                    previs.get("group_generation") != group_generation or
                    group.get("group_generation") != group_generation or
                    group.get("state") not in ("group-visible", "freeing") or
                    group.get("group_visible_digest") !=
                        proof["root_meta"].get("previs_group_visible_digest")):
                raise StateError("catalog-root-invalid", "PREVIS free precondition is invalid", 4)
            predecessor = bytes.fromhex(
                recovery["payload"]["consumed_free_receipt_record_digest"])
            cancel_digest = bytes.fromhex(previs["cancel_digest"])
            visible_digest = bytes.fromhex(group["group_visible_digest"])
            material = _catalog_free_material(
                index, entry["free_generation"] + 1, predecessor, 2,
                cancel_digest, visible_digest, recovery["generation"] + 1)
            receipt_payload = {
                "schema_version": 1, "frame_type": "FREE_RECEIPT",
                "kind": "previs", "cell_index": index,
                "cell_generation": recovery["generation"] + 1,
                "free_generation": entry["free_generation"] + 1,
                "predecessor_record_digest": predecessor.hex(),
                "cancel_digest": cancel_digest.hex(),
                "group_visible_digest": visible_digest.hex(),
                "body_b64": base64.b64encode(material["body"]).decode(),
                "body_digest": material["body_digest"].hex(),
                "final_cell_image_digest": material["final_cell_digest"].hex(),
                "record_digest": material["record_digest"].hex(),
            }
            receipt_frame = _catalog_frame_image("free-receipt", receipt_payload)
            receipt_frame_digest = _catalog_digest(
                b"zyz-catalog-frame-v1", receipt_frame).hex()
            observed_will = proof["root_meta"].get("previs_free_will")
            if observed_will is None:
                segment_generation = proof["root_meta"].get(
                    "active_segment_generation")
                _catalog_active_member(proof)
                frame_offset = proof["root_meta"].get(
                    "active_segment_used_length")
                if (not isinstance(segment_generation, int) or
                        not isinstance(frame_offset, int)):
                    raise StateError(
                        "catalog-root-invalid",
                        "PREVIS receipt active coordinate is invalid", 4)
            else:
                segment_generation = observed_will.get("segment_generation") \
                    if isinstance(observed_will, dict) else None
                frame_offset = observed_will.get("frame_offset") \
                    if isinstance(observed_will, dict) else None
            will = {"schema_version": 1, "cell_index": index,
                    "cell_generation": recovery["generation"],
                    "group_generation": group_generation,
                    "cancel_digest": cancel_digest.hex(),
                    "group_visible_digest": visible_digest.hex(),
                    "expected_free_generation": entry["free_generation"] + 1,
                    "free_receipt_record_digest": material["record_digest"].hex(),
                    "segment_generation": segment_generation,
                    "frame_offset": frame_offset,
                    "frame_length": len(receipt_frame),
                    "frame_digest": receipt_frame_digest}
            if observed_will is None:
                _catalog_root_successor(global_fd, recovery_fd, proof, selector,
                                        {"previs_free_will": will},
                                        "will-previs-cell-free")
                proof = _catalog_validate_genesis(container)
                os.close(proof.pop("global_fd"))
                selector = proof["root"][2][4096:5120]
                entry_bank, _, entry = _catalog_selected_entry(global_fd, selector, index)
                recovery_bank, _, recovery = _catalog_selected_recovery(recovery_fd, entry, index)
                group = proof["group_meta"]
            elif observed_will != will:
                raise StateError("catalog-root-invalid", "PREVIS free will conflicts", 4)
            segment_result = _catalog_commit_active_frame(
                container, proof, segment_generation, frame_offset,
                receipt_frame)
            _catalog_barrier(
                "catalog-segment", "previs-free-receipt-frame-committed")
            free_image = _catalog_recovery_free_image(index, material)
            free_directory = _catalog_directory_free_image(index, material)
            next_recovery_bank = 1 - recovery_bank
            recovery_offset = (index * CATALOG_RECOVERY_CELL_SIZE +
                               next_recovery_bank * CATALOG_RECOVERY_IMAGE_SIZE)
            observed = _catalog_pread_exact(recovery_fd, CATALOG_RECOVERY_IMAGE_SIZE,
                                            recovery_offset)
            if observed != free_image:
                if observed != bytes(CATALOG_RECOVERY_IMAGE_SIZE):
                    parsed = _catalog_parse_recovery_image(observed, index)
                    if parsed["generation"] >= recovery["generation"] + 1:
                        raise StateError("catalog-root-invalid", "PREVIS FREE CELL conflicts", 4)
                _catalog_pwrite_all(recovery_fd, free_image, recovery_offset,
                                    "PREVIS FREE CELL")
                _data_sync(recovery_fd)
            _catalog_barrier("catalog-recovery", "previs-cell-free")
            next_entry_bank = 1 - entry_bank
            base = (CATALOG_LAYOUT["cell_directory_a"][0] if next_entry_bank == 0
                    else CATALOG_LAYOUT["cell_directory_b"][0])
            directory_offset = base + index * CATALOG_DIRECTORY_IMAGE_SIZE
            observed_directory = _catalog_pread_exact(
                global_fd, CATALOG_DIRECTORY_IMAGE_SIZE, directory_offset)
            if observed_directory != free_directory:
                if observed_directory != bytes(CATALOG_DIRECTORY_IMAGE_SIZE):
                    parsed_directory = _catalog_parse_directory_image(observed_directory, index)
                    if parsed_directory["cell_generation"] >= recovery["generation"] + 1:
                        raise StateError("catalog-root-invalid", "PREVIS FREE directory conflicts", 4)
                _catalog_pwrite_all(global_fd, free_directory, directory_offset,
                                    "PREVIS FREE directory")
                _data_sync(global_fd)
            consumed = _catalog_digest(
                b"zyz-previs-consumed-successor-v1",
                bytes.fromhex(group["consumed_digest"]) + struct.pack(">I", index) +
                material["record_digest"])
            free_count = group["free_count"] + 1
            metadata = dict(group, state=("previs-cells-consumed" if
                                          free_count == group["cancel_count"] else "freeing"),
                            free_count=free_count, consumed_digest=consumed.hex())
            successor_group = _catalog_group_successor(global_fd, proof, metadata)
            selector = _catalog_selector_set(selector, index, next_entry_bank)
            chain_region = _catalog_active_append_chain_region(
                proof, segment_result)
            successor = _catalog_root_successor(
                global_fd, recovery_fd, proof, selector,
                {"previs_free_will": None,
                 "group_control_digest": successor_group["digest"].hex(),
                 "last_previs_freed_subject_digest": subject.hex(),
                 "last_previs_free_receipt_record_digest": material["record_digest"].hex(),
                 "active_segment_generation": segment_generation,
                 "active_segment_used_length": segment_result["end"],
                 "active_segment_descriptor_digest":
                    segment_result["descriptor_digest"]},
                "did-previs-cell-free", chain_region)
            return {"state": "previs-free", "cell_index": index,
                    "group_state": metadata["state"],
                    "free_receipt_record_digest": material["record_digest"].hex(),
                    "root_digest": successor["digest"].hex(), "idempotent": False}
        finally:
            os.close(global_fd); os.close(recovery_fd)


def _catalog_previs_free_step(container: Path, limit: int = 64) -> dict:
    """Consume the visible group's cancelled cells in deterministic index order."""
    if not 1 <= limit <= 64:
        raise StateError("gc-internal", "PREVIS free limit is invalid", 5)
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_fd = proof.pop("global_fd")
        recovery_fd = os.open(
            os.fsencode(container / ".catalog-recovery-pack.v1"),
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            group = proof["group_meta"]
            if group["state"] == "previs-cells-consumed":
                return {"state": "previs-cells-consumed", "freed": 0,
                        "more": False, "idempotent": True}
            if group["state"] not in ("group-visible", "freeing"):
                raise StateError("catalog-root-invalid",
                                 "PREVIS free group phase conflicts", 4)
            selector = proof["root"][2][4096:5120]
            candidates = []
            for index in range(CATALOG_CELL_COUNT):
                _, _, entry = _catalog_selected_entry(global_fd, selector, index)
                if entry["state"] != 4:
                    continue
                _, _, recovery = _catalog_selected_recovery(
                    recovery_fd, entry, index)
                previs = recovery["payload"].get("_previs")
                if (isinstance(previs, dict) and
                        previs.get("group_generation") ==
                            group["group_generation"]):
                    candidates.append(index)
                    if len(candidates) == limit:
                        break
            group_generation = group["group_generation"]
            cancel_count = group["cancel_count"]
        finally:
            os.close(global_fd); os.close(recovery_fd)
    if not candidates and cancel_count == 0:
        with CatalogFlock(container):
            proof = _catalog_validate_genesis(container)
            global_read = proof.pop("global_fd"); os.close(global_read)
            global_fd = os.open(
                os.fsencode(container / ".catalog-global-pack.v1"),
                os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
            recovery_fd = os.open(
                os.fsencode(container / ".catalog-recovery-pack.v1"),
                os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
            try:
                group = proof["group_meta"]
                if (group["state"] == "previs-cells-consumed" and
                        group["free_count"] == 0):
                    return {"state": "previs-cells-consumed", "freed": 0,
                            "more": False, "idempotent": True}
                if group["state"] != "group-visible" or group["cancel_count"] != 0:
                    raise StateError("catalog-root-invalid",
                                     "empty PREVIS set changed", 4)
                metadata = dict(group, state="previs-cells-consumed")
                result = _catalog_group_commit(
                    global_fd, recovery_fd, proof, metadata,
                    "previs-empty-consumed")
                return {"state": "previs-cells-consumed", "freed": 0,
                        "more": False, "idempotent": False, **result}
            finally:
                os.close(global_fd); os.close(recovery_fd)
    freed = 0
    for index in candidates:
        _catalog_previs_free(
            container, None, group_generation, cell_index=index)
        freed += 1
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        os.close(proof.pop("global_fd"))
        group = proof["group_meta"]
        return {"state": group["state"], "freed": freed,
                "more": group["state"] != "previs-cells-consumed",
                "idempotent": False}


def _catalog_reinitialize_scratch(container: Path, name: str,
                                  prior_identity_digest: str) -> dict:
    """Deterministically turn one retired source inode into an empty scratch."""
    fd = os.open(os.fsencode(container / name),
                 os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
    try:
        observed = os.fstat(fd)
        identity = {"dev": observed.st_dev, "ino": observed.st_ino,
                    "size": observed.st_size,
                    "mount_id": _catalog_mount_identity(container / name)}
        if (not stat.S_ISREG(observed.st_mode) or observed.st_nlink != 1 or
                observed.st_size != CATALOG_SEGMENT_SIZE or
                observed.st_blocks * 512 < CATALOG_SEGMENT_SIZE or
                hashlib.sha256(_catalog_json(identity)).hexdigest() !=
                    prior_identity_digest):
            raise StateError("catalog-root-invalid",
                             "next scratch inode identity changed", 4)
        try:
            current = _catalog_segment_descriptor(fd)[3][2]
        except StateError:
            current = None
        if (isinstance(current, dict) and
                current.get("segment_generation") == 0 and
                current.get("deterministic_basename") == name and
                current.get("committed_used_length") == 0 and
                current.get("committed_content_sha256") ==
                    hashlib.sha256(b"").hexdigest()):
            return _catalog_segment_chain_projection(container, name, 0)
        zero = bytes(1024 * 1024)
        _catalog_pwrite_all(fd, zero, 0, "next migration scratch zero")
        image = _catalog_segment_image(0, name)
        _catalog_pwrite_all(
            fd, image, CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL,
            "next migration scratch descriptor")
        _data_sync(fd)
    finally:
        os.close(fd)
    return _catalog_segment_chain_projection(container, name, 0)


def _catalog_group_retire_step(container: Path) -> dict:
    """Rotate old-first into scratch and retire every extra old source exactly."""
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_read = proof.pop("global_fd"); os.close(global_read)
        global_fd = os.open(
            os.fsencode(container / ".catalog-global-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(
            os.fsencode(container / ".catalog-recovery-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            group = proof["group_meta"]
            sources = group.get("source_segments")
            if not isinstance(sources, list) or not sources:
                raise StateError("catalog-root-invalid",
                                 "retired source set is invalid", 4)
            if group["state"] == "previs-cells-consumed":
                first = sources[0]
                will = {"basename": first["basename"],
                        "identity_digest": first["identity_digest"],
                        "descriptor_digest": first["descriptor_digest"],
                        "source_group_digest": group["source_group_digest"],
                        "group_visible_digest": group["group_visible_digest"],
                        "consumed_digest": group["consumed_digest"]}
                metadata = dict(group, state="next-scratch-will",
                                next_scratch_will=will,
                                retirement_cursor=1, retired_bytes=0)
                result = _catalog_group_commit(
                    global_fd, recovery_fd, proof, metadata,
                    "next-scratch-will")
                return {"state": "next-scratch-will", "advanced": True,
                        **result}
            if group["state"] == "next-scratch-ready":
                cursor = group.get("retirement_cursor")
                if not isinstance(cursor, int) or not 1 <= cursor <= len(sources):
                    raise StateError("catalog-root-invalid",
                                     "retirement cursor is invalid", 4)
                if cursor == len(sources):
                    metadata = dict(group, state="group-committed",
                                    next_scratch_will=None,
                                    retired_delete_will=None)
                    result = _catalog_group_commit(
                        global_fd, recovery_fd, proof, metadata,
                        "group-committed",
                        {"migration_retirement_cursor":
                            sources[-1]["segment_generation"] + 1,
                         "previs_cancel_count": 0})
                    return {"state": "group-committed", "advanced": True,
                            **result}
                source = sources[cursor]
                root = proof["root_meta"]
                owned = root.get("owned_bytes")
                counter = root.get("counter_generation")
                if (not isinstance(owned, int) or owned < CATALOG_SEGMENT_SIZE or
                        not isinstance(counter, int) or counter < 0):
                    raise StateError("catalog-root-invalid",
                                     "retired source counters are invalid", 4)
                will = {"source_index": cursor,
                        "basename": source["basename"],
                        "identity_digest": source["identity_digest"],
                        "descriptor_digest": source["descriptor_digest"],
                        "owned_prior": owned,
                        "owned_after": owned - CATALOG_SEGMENT_SIZE,
                        "counter_generation_prior": counter,
                        "counter_generation_after": counter + 1}
                metadata = dict(group, state="retired-delete-will",
                                retired_delete_will=will)
                result = _catalog_group_commit(
                    global_fd, recovery_fd, proof, metadata,
                    "retired-delete-will")
                return {"state": "retired-delete-will", "advanced": True,
                        **result}
            if group["state"] == "group-committed":
                return {"state": "group-committed", "advanced": False,
                        "idempotent": True}
            if group["state"] not in ("next-scratch-will",
                                      "retired-delete-will"):
                raise StateError("catalog-root-invalid",
                                 "group retirement phase conflicts", 4)
            state = group["state"]
            will = (group.get("next_scratch_will") if
                    state == "next-scratch-will" else
                    group.get("retired_delete_will"))
            if not isinstance(will, dict):
                raise StateError("catalog-root-invalid",
                                 "group retirement will is missing", 4)
        finally:
            os.close(global_fd); os.close(recovery_fd)

    if state == "next-scratch-will":
        scratch = _catalog_reinitialize_scratch(
            container, will["basename"], will["identity_digest"])
        _catalog_barrier("catalog-migration-group",
                         "next-scratch-physical-initialized")
        with CatalogFlock(container):
            proof = _catalog_validate_genesis(container)
            global_read = proof.pop("global_fd"); os.close(global_read)
            global_fd = os.open(
                os.fsencode(container / ".catalog-global-pack.v1"),
                os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
            recovery_fd = os.open(
                os.fsencode(container / ".catalog-recovery-pack.v1"),
                os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
            try:
                group = proof["group_meta"]
                if (group["state"] != "next-scratch-will" or
                        group.get("next_scratch_will") != will):
                    raise StateError("catalog-root-invalid",
                                     "next scratch will changed", 4)
                metadata = dict(
                    group, state="next-scratch-ready",
                    next_scratch_identity=scratch["identity_digest"],
                    next_scratch_descriptor_digest=scratch["descriptor_digest"])
                result = _catalog_group_commit(
                    global_fd, recovery_fd, proof, metadata,
                    "next-scratch-ready",
                    {"migration_scratch_basename": will["basename"]})
                return {"state": "next-scratch-ready", "advanced": True,
                        **result}
            finally:
                os.close(global_fd); os.close(recovery_fd)

    path = container / will["basename"]
    try:
        identity = _catalog_object_identity(
            container, will["basename"], CATALOG_SEGMENT_SIZE)
    except FileNotFoundError:
        identity = None
    physical_deleted = identity is not None
    if physical_deleted:
        if identity["digest"] != will["identity_digest"]:
            raise StateError("catalog-root-invalid",
                             "retired source identity changed", 4)
        parent_fd = os.open(
            os.fsencode(container), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) |
            getattr(os, "O_NOFOLLOW", 0))
        try:
            os.unlink(os.fsencode(will["basename"]), dir_fd=parent_fd)
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
        _catalog_barrier("catalog-migration-group",
                         "retired-source-physical-deleted")
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_read = proof.pop("global_fd"); os.close(global_read)
        global_fd = os.open(
            os.fsencode(container / ".catalog-global-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(
            os.fsencode(container / ".catalog-recovery-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            group = proof["group_meta"]
            root = proof["root_meta"]
            if (group["state"] != "retired-delete-will" or
                    group.get("retired_delete_will") != will or
                    root.get("owned_bytes") != will["owned_prior"] or
                    root.get("counter_generation") !=
                        will["counter_generation_prior"]):
                raise StateError("catalog-root-invalid",
                                 "retired source counter prior changed", 4)
            metadata = dict(
                group, state="next-scratch-ready",
                retirement_cursor=will["source_index"] + 1,
                retired_bytes=group["retired_bytes"] + CATALOG_SEGMENT_SIZE,
                retired_delete_will=None)
            result = _catalog_group_commit(
                global_fd, recovery_fd, proof, metadata,
                "retired-delete-counter-committed",
                {"owned_bytes": will["owned_after"],
                 "counter_generation": will["counter_generation_after"]})
            return {"state": "next-scratch-ready", "advanced": True,
                    "entries_deleted": 1 if physical_deleted else 0,
                    "bytes_reclaimed": (CATALOG_SEGMENT_SIZE
                                        if physical_deleted else 0), **result}
        finally:
            os.close(global_fd); os.close(recovery_fd)


def _catalog_group_idle_metadata(group: dict) -> dict:
    return {
        "schema_version": 1, "state": "idle",
        "group_generation": group["group_generation"],
        "source_segment_generation": None,
        "source_segments": [], "source_group_digest": None,
        "scratch_basename": None,
        "plan_scan_cursor": 0, "planned_frame_count": 0,
        "planned_frame_bytes": 0, "planned_frame_digest": None,
        "copy_cursor": 0, "copy_bytes": 0,
        "scratch_identity": None, "scratch_descriptor_digest": None,
        "cancel_count": 0, "cancel_set_digest": None,
        "free_count": 0, "consumed_digest": None,
        "group_visible_digest": None,
        "retirement_cursor": 0, "retired_bytes": 0,
    }


def _catalog_group_continue_or_finish(container: Path) -> dict:
    """Release the next suffix group, or commit the finite migration."""
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_read = proof.pop("global_fd"); os.close(global_read)
        global_fd = os.open(
            os.fsencode(container / ".catalog-global-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(
            os.fsencode(container / ".catalog-recovery-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            root = proof["root_meta"]
            group = proof["group_meta"]
            if root.get("state") == "migration-committed":
                return {"state": "migration-committed", "idempotent": True}
            if root.get("state") == "will-migration-finish":
                if (group.get("state") != "group-committed" or
                        root.get("admission_state") != "closed"):
                    raise StateError("catalog-root-invalid",
                                     "migration finish will conflicts", 4)
                successor = _catalog_root_successor(
                    global_fd, recovery_fd, proof,
                    proof["root"][2][4096:5120],
                    {"state": "migration-committed",
                     "admission_state": "closed"},
                    "migration-committed")
                return {"state": "migration-committed", "idempotent": False,
                        "root_digest": successor["digest"].hex()}
            if (root.get("state") != "migration-active" or
                    root.get("admission_state") != "closed" or
                    group.get("state") != "group-committed"):
                raise StateError("catalog-root-invalid",
                                 "group continuation prior conflicts", 4)
            last = group["source_segments"][-1]["segment_generation"]
            suffix = [member for member in proof["chain"]["members"]
                      if member["generation"] > last]
            if suffix:
                next_generation = suffix[0]["generation"]
                metadata = _catalog_group_idle_metadata(group)
                result = _catalog_group_commit(
                    global_fd, recovery_fd, proof, metadata,
                    "group-next-ready",
                    {"migration_source_segment_generation": next_generation,
                     "migration_copy_cursor": 0,
                     "migration_retirement_cursor": next_generation})
                return {"state": "next-group-ready",
                        "source_segment_generation": next_generation,
                        "idempotent": False, **result}
            successor = _catalog_root_successor(
                global_fd, recovery_fd, proof,
                proof["root"][2][4096:5120],
                {"state": "will-migration-finish"},
                "will-migration-finish")
            return {"state": "will-migration-finish", "idempotent": False,
                    "root_digest": successor["digest"].hex()}
        finally:
            os.close(global_fd); os.close(recovery_fd)


def _catalog_migration_commit_outcome(container: Path, config: dict) -> dict:
    """Normalize a committed migration to dense pressure or active service."""
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_read = proof.pop("global_fd"); os.close(global_read)
        global_fd = os.open(
            os.fsencode(container / ".catalog-global-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(
            os.fsencode(container / ".catalog-recovery-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            root = proof["root_meta"]
            group = proof["group_meta"]
            if (root.get("state") != "migration-committed" or
                    root.get("admission_state") != "closed" or
                    group.get("state") != "group-committed"):
                raise StateError("catalog-root-invalid",
                                 "migration outcome prior conflicts", 4)
            intent = root.get("migration_quiesce_intent")
            source_count = (intent.get("source_count")
                            if isinstance(intent, dict) else None)
            if (not isinstance(source_count, int) or source_count < 1 or
                    not isinstance(root.get("owned_bytes"), int)):
                raise StateError("catalog-root-invalid",
                                 "migration outcome proof is invalid", 4)
            dense = (root["owned_bytes"] >=
                     config["ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES"] and
                     len(proof["chain"]["members"]) == source_count)
            signature = (_catalog_dense_signature_value(root)
                         if dense else None)
            metadata = _catalog_group_idle_metadata(group)
            successor_group = _catalog_group_successor(
                global_fd, proof, metadata)
            successor = _catalog_root_successor(
                global_fd, recovery_fd, proof,
                proof["root"][2][4096:5120],
                {"state": "active",
                 "admission_state": "closed" if dense else "open",
                 "dense_capacity_signature": signature,
                 "group_control_digest": successor_group["digest"].hex(),
                 "migration_quiesce_intent": None,
                 "migration_creator_cutoff": None,
                 "migration_source_chain_digest": None,
                 "migration_source_segment_generation": None,
                 "migration_scan_cursor": 0,
                 "previs_cancel_count": 0,
                 "previs_cancel_will": None,
                 "previs_free_will": None},
                "migration-outcome-dense" if dense else
                "migration-outcome-active")
            return {"state": "pressure" if dense else "active",
                    "dense": dense, "advanced": True,
                    "transactions_advanced": 1,
                    "root_digest": successor["digest"].hex()}
        finally:
            os.close(global_fd); os.close(recovery_fd)


def _catalog_dense_signature_reconcile(container: Path) -> dict:
    """Clear an input-invalidated dense latch before reevaluation."""
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_read = proof.pop("global_fd"); os.close(global_read)
        root = proof["root_meta"]
        if (root.get("state") != "active" or
                root.get("dense_capacity_signature") is None or
                _catalog_dense_signature_matches(root)):
            raise StateError("catalog-root-invalid",
                             "stale dense-capacity prior conflicts", 4)
        global_fd = os.open(
            os.fsencode(container / ".catalog-global-pack.v1"),
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(
            os.fsencode(container / ".catalog-recovery-pack.v1"),
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            successor = _catalog_root_successor(
                global_fd, recovery_fd, proof,
                proof["root"][2][4096:5120],
                {"admission_state": "open",
                 "dense_capacity_signature": None},
                "dense-signature-invalidated")
            return {"state": "active", "advanced": True,
                    "transactions_advanced": 1,
                    "root_digest": successor["digest"].hex()}
        finally:
            os.close(global_fd); os.close(recovery_fd)


def _catalog_migration_step(container: Path, config: dict) -> dict:
    """Advance at most one selected bounded migration phase."""
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        os.close(proof.pop("global_fd"))
        root = proof["root_meta"]
        group = proof["group_meta"]
        root_state = root.get("state")
        group_state = group.get("state")
        owned = root.get("owned_bytes")
        high = config["ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES"]
        signature_present = root.get("dense_capacity_signature") is not None
        signature_matches = _catalog_dense_signature_matches(root)
        source_generation = root.get("migration_source_segment_generation")
        if source_generation is None and proof["chain"]["members"]:
            source_generation = proof["chain"]["members"][0]["generation"]

    result: dict
    if root_state == "active":
        if signature_matches:
            return {"state": "pressure", "advanced": False,
                    "pressure": True, "pending": False,
                    "transactions_advanced": 0,
                    "entries_deleted": 0, "bytes_reclaimed": 0}
        if signature_present:
            result = _catalog_dense_signature_reconcile(container)
        elif isinstance(owned, int) and owned >= high:
            result = _catalog_migration_quiesce_begin(container)
        else:
            return {"state": "active", "advanced": False,
                    "pressure": False, "pending": False,
                    "transactions_advanced": 0,
                    "entries_deleted": 0, "bytes_reclaimed": 0}
    elif root_state == "will-migration-quiesce":
        result = _catalog_migration_quiesce_begin(container)
    elif root_state in ("migration-quiescing", "migration-active"):
        if group_state == "idle":
            if not isinstance(source_generation, int):
                raise StateError("catalog-root-invalid",
                                 "migration source cursor is invalid", 4)
            result = _catalog_previs_group_begin(
                container, source_generation)
        elif (group_state == "new-source-initialized" and
              root.get("migration_scan_cursor") != CATALOG_CELL_COUNT):
            result = _catalog_quiesce_cancel_previsible(container, 64)
        elif group_state in ("new-source-initialized", "planning"):
            result = _catalog_group_plan_step(container, 64)
        elif group_state in ("group-planned", "copy-will", "copying"):
            result = _catalog_group_copy_step(container, 64)
        elif group_state in ("copied", "cutover-will"):
            result = _catalog_previs_group_visible(
                container, group["group_generation"],
                group["source_segment_generation"])
        elif group_state in ("group-visible", "freeing"):
            result = _catalog_previs_free_step(container, 64)
        elif group_state in ("previs-cells-consumed", "next-scratch-will",
                             "next-scratch-ready", "retired-delete-will",
                             "old-source-retired"):
            result = _catalog_group_retire_step(container)
        elif group_state == "group-committed":
            result = _catalog_group_continue_or_finish(container)
        else:
            raise StateError("catalog-root-invalid",
                             "migration dispatcher phase is invalid", 4)
    elif root_state == "will-migration-finish":
        result = _catalog_group_continue_or_finish(container)
    elif root_state == "migration-committed":
        result = _catalog_migration_commit_outcome(container, config)
    else:
        raise StateError("catalog-root-invalid",
                         "migration dispatcher ROOT state is invalid", 4)

    advanced = bool(result.get("transactions_advanced", 0) or
                    result.get("advanced",
                               not result.get("idempotent", False)))
    pending = result.get(
        "pending", result.get("state") not in ("active", "pressure") or
        (result.get("state") == "active" and
         isinstance(owned, int) and owned >= high))
    return {**result, "advanced": advanced,
            "pressure": result.get("state") == "pressure",
            "pending": pending,
            "transactions_advanced": result.get(
                "transactions_advanced", int(advanced)),
            "entries_deleted": result.get("entries_deleted", 0),
            "bytes_reclaimed": result.get("bytes_reclaimed", 0)}


def _catalog_claim_key(purpose: str, instance_key: str, parent_txn_id: str) -> tuple[str, dict]:
    if (purpose not in ("snapshot-temp", "snapshot-publication", "terminal-cleanup",
                        "legacy-migration") or not KEY_RE.fullmatch(instance_key) or
            not isinstance(parent_txn_id, str) or not 1 <= len(parent_txn_id.encode()) <= 256):
        raise StateError("invalid-request", "logical claim owner key is invalid", 2)
    logical = {"schema_version": 1, "purpose": purpose,
               "instance_key": instance_key, "parent_txn_id": parent_txn_id}
    return hashlib.sha256(_catalog_json(logical)).hexdigest(), logical


def _catalog_claim_frame(logical: dict, key_digest: str, pack_name: str,
                         pack_identity_digest: str, reservation: dict,
                         request: int, sequence: int, segment_generation: int,
                         frame_offset: int) -> tuple[bytes, dict]:
    """Build the immutable claim frame and its ROOT-will coordinates."""
    if (not isinstance(sequence, int) or sequence < 1 or
            not isinstance(segment_generation, int) or segment_generation < 1 or
            not isinstance(frame_offset, int) or frame_offset < 0):
        raise StateError("catalog-root-invalid", "claim frame coordinates are invalid", 4)
    frame_payload = {"schema_version": 1, "frame_type": "claim",
                     "sequence": sequence, "logical_key_sha256": key_digest,
                     "claim_pack_basename": pack_name,
                     "pack_identity_digest": pack_identity_digest,
                     "recovery_cell_index": reservation["cell_index"],
                     "reservation_digest": reservation["reservation_digest"],
                     "reservation_bytes": request, "purpose": logical["purpose"],
                     "instance_key": logical["instance_key"],
                     "parent_txn_sha256": hashlib.sha256(
                         logical["parent_txn_id"].encode()).hexdigest()}
    frame = _catalog_frame_image("claim", frame_payload)
    will = {"sequence": sequence, "logical_key_sha256": key_digest,
            "segment_generation": segment_generation,
            "frame_offset": frame_offset, "frame_length": len(frame),
            "frame_digest": _catalog_digest(
                b"zyz-catalog-frame-v1", frame).hex()}
    return frame, will


def _catalog_claim_staged_observation(will: dict, root_digest: str,
                                      observed_epoch: int) -> dict:
    return {"schema_version": 1, "state": "frame-will",
            "sequence": will["sequence"], "frame_digest": will["frame_digest"],
            "segment_generation": will["segment_generation"],
            "frame_offset": will["frame_offset"],
            "frame_length": will["frame_length"],
            "prepared_root_digest": root_digest,
            "last_observed_epoch": observed_epoch,
            "retry_epoch": None, "blocked": None}


def _catalog_claim_frame_from_observation(logical: dict, key_digest: str,
                                          pack_name: str,
                                          pack_identity_digest: str,
                                          reservation: dict, request: int,
                                          observation: dict) -> tuple[bytes, dict]:
    required = {"schema_version", "state", "sequence", "frame_digest",
                "segment_generation", "frame_offset", "frame_length",
                "prepared_root_digest", "last_observed_epoch", "retry_epoch",
                "blocked"}
    if (set(observation) != required or observation.get("schema_version") != 1 or
            observation.get("state") != "frame-will" or
            not isinstance(observation.get("last_observed_epoch"), int) or
            observation["last_observed_epoch"] < 0 or
            observation.get("retry_epoch") is not None or
            observation.get("blocked") is not None or
            not isinstance(observation.get("prepared_root_digest"), str) or
            not HEX64.fullmatch(observation["prepared_root_digest"])):
        raise StateError("catalog-root-invalid", "claim staged observation is invalid", 4)
    frame, will = _catalog_claim_frame(
        logical, key_digest, pack_name, pack_identity_digest, reservation, request,
        observation.get("sequence"), observation.get("segment_generation"),
        observation.get("frame_offset"))
    if (observation.get("frame_length") != will["frame_length"] or
            observation.get("frame_digest") != will["frame_digest"]):
        raise StateError("catalog-root-invalid", "claim staged frame projection conflicts", 4)
    return frame, will


def _catalog_claim_frame_committed(container: Path, proof: dict,
                                   will: dict, frame: bytes,
                                   tolerate_other_frame: bool = False) -> bool:
    """Authenticate one staged frame at its O(1) immutable segment coordinate."""
    generation = will["segment_generation"]
    offset = will["frame_offset"]
    end = offset + len(frame)
    if (will["frame_length"] != len(frame) or end >
            CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL):
        raise StateError("catalog-root-invalid", "claim frame exceeds its segment", 4)
    member = _catalog_chain_member(proof, generation)
    path = container / member["basename"]
    try:
        fd = os.open(os.fsencode(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        raise StateError("catalog-root-invalid", "claim frame segment is unavailable", 4)
    try:
        if os.fstat(fd).st_size != CATALOG_SEGMENT_SIZE:
            raise StateError("catalog-root-invalid", "claim frame segment size is invalid", 4)
        descriptor = _catalog_segment_descriptor(fd)[3][2]
        physical_generation = (0 if member.get("anchor_kind") ==
                               "scratch-object" else generation)
        if (descriptor.get("segment_generation") != physical_generation or
                descriptor.get("deterministic_basename") != path.name):
            raise StateError("catalog-root-invalid", "claim frame segment identity conflicts", 4)
        used = descriptor.get("committed_used_length")
        if (not isinstance(used, int) or used < 0 or used >
                CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL):
            raise StateError("catalog-root-invalid", "claim frame segment length is invalid", 4)
        if used <= offset:
            return False
        if used < end:
            if tolerate_other_frame:
                return False
            raise StateError("catalog-root-invalid", "claim frame is partially committed", 4)
        observed = _catalog_pread_exact(fd, len(frame), offset)
        if (observed != frame or not hmac.compare_digest(
                _catalog_digest(b"zyz-catalog-frame-v1", observed).hex(),
                will["frame_digest"])):
            if tolerate_other_frame:
                return False
            raise StateError("catalog-root-invalid", "claim frame coordinate conflicts", 4)
        return True
    finally:
        os.close(fd)


def _catalog_claim_create(container: Path, purpose: str, instance_key: str,
                          parent_txn_id: str, max_data_bytes: int,
                          created_epoch: int, config: dict,
                          owner_facts: dict | None = None) -> dict:
    """Create or resume one deterministic 256 KiB claim pack and log frame."""
    if (not isinstance(max_data_bytes, int) or max_data_bytes < 0 or
            max_data_bytes > 2147483647 - CLAIM_PACK_SIZE or
            not isinstance(created_epoch, int) or not 0 <= created_epoch <= 2147483647):
        raise StateError("invalid-request", "claim reservation bounds are invalid", 2)
    key_digest, logical = _catalog_claim_key(purpose, instance_key, parent_txn_id)
    cell_key = f"claim.{key_digest}"
    request = CLAIM_PACK_SIZE + max_data_bytes
    event_nonce = hashlib.sha256(
        b"zyz-claim-event-v1" + _catalog_json(logical)).hexdigest()[:32]
    event = event_identity("claim", purpose, key_digest, event_nonce)
    reservation = _catalog_reserve_instance(
        container, cell_key, request, config, event)
    if not reservation["event_matches"]:
        raise StateError("identity-conflict", "claim reservation event conflicts", 4)
    if reservation["resume_state"] == "reserved":
        identities = _instance_create_reserved_objects(container, cell_key, reservation)
        reservation = _catalog_instance_cell_transition(
            container, cell_key, reservation, "owner-active", identities, True)
    else:
        expected = reservation.get("object_identities_digest")
        if not isinstance(expected, str) or not HEX64.fullmatch(expected):
            raise StateError("catalog-root-invalid", "claim pack identity digest is invalid", 4)
        identities = _instance_validate_reserved_objects(container, reservation, expected)
    if reservation["resume_state"] == "owner-active":
        reservation = _catalog_instance_cell_transition(
            container, cell_key, reservation, "cell-active-ack")

    pack_name = f"{key_digest}.claim-pack.v1"
    pack_identity = _catalog_object_identity(container, pack_name, CLAIM_PACK_SIZE)
    immutable = {**logical, "logical_key_sha256": key_digest,
                 "claim_pack_basename": pack_name,
                 "max_data_bytes": max_data_bytes,
                 "reservation_bytes": request,
                 "recovery_cell_index": reservation["cell_index"],
                 "reservation_digest": reservation["reservation_digest"],
                 "pack_identity_digest": pack_identity["digest"]}
    owner = ({"schema_version": 1, "state": "active", "created_epoch": created_epoch,
              "hostname": socket.gethostname(), "logical_key_sha256": key_digest,
              "instance_key": instance_key, "purpose": purpose,
              "parent_txn_id": parent_txn_id, "targets": []}
             if owner_facts is None else
             {**owner_facts, "schema_version": 1, "state": "will-create",
              "created_epoch": created_epoch, "hostname": socket.gethostname(),
              "logical_key_sha256": key_digest, "instance_key": instance_key,
              "purpose": purpose, "parent_txn_id": parent_txn_id})
    fd = _instance_open_pack(container, key_digest, "claim", True)
    try:
        observed = _instance_pack_read_fd(fd, "claim", key_digest, "IMMUTABLE_KEY")
        if observed is None:
            _instance_pack_write_fd(fd, "claim", key_digest, "IMMUTABLE_KEY", immutable)
        elif observed != immutable:
            raise StateError("catalog-root-invalid", "claim immutable key conflicts", 4)
        observed_owner = _instance_pack_read_fd(fd, "claim", key_digest, "OWNER")
        if observed_owner is None:
            _instance_pack_write_fd(fd, "claim", key_digest, "OWNER", owner)
        elif (observed_owner != owner and
              not _catalog_claim_owner_predecessor(owner, observed_owner)):
            raise StateError("catalog-root-invalid", "claim owner facts conflict", 4)
        if observed_owner is None or observed_owner == owner:
            _catalog_claim_owner_barrier(
                owner,"will-create-header-committed")
        observation = _instance_pack_read_fd(fd, "claim", key_digest, "OBSERVATION")
        if observation is not None and observation.get("state") == "claimed":
            required = {"schema_version", "state", "sequence", "frame_digest",
                        "claimed_root_digest", "last_observed_epoch", "retry_epoch",
                        "blocked"}
            if (set(observation) != required or observation.get("schema_version") != 1 or
                    not isinstance(observation.get("sequence"), int) or
                    observation["sequence"] < 1 or
                    not isinstance(observation.get("frame_digest"), str) or
                    not HEX64.fullmatch(observation["frame_digest"]) or
                    not isinstance(observation.get("claimed_root_digest"), str) or
                    not HEX64.fullmatch(observation["claimed_root_digest"]) or
                    not isinstance(observation.get("last_observed_epoch"), int) or
                    observation["last_observed_epoch"] < 0 or
                    observation.get("retry_epoch") is not None or
                    observation.get("blocked") is not None):
                raise StateError("catalog-root-invalid", "claim observation is invalid", 4)
            return {"state": "claimed", "logical_key_sha256": key_digest,
                    "claim_pack_basename": pack_name,
                    "sequence": observation["sequence"],
                    "frame_digest": observation["frame_digest"],
                    "cell_index": reservation["cell_index"], "idempotent": True,
                    "owner_record": owner}
        if observation is not None and observation.get("state") != "frame-will":
            raise StateError("catalog-root-invalid", "claim observation state is invalid", 4)
    finally:
        os.close(fd)

    recovered = observation is not None
    successor_digest = None
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_read = proof.pop("global_fd"); os.close(global_read)
        global_fd = os.open(os.fsencode(container / ".catalog-global-pack.v1"),
                            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(os.fsencode(container / ".catalog-recovery-pack.v1"),
                              os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            next_sequence = proof["root_meta"].get("next_sequence")
            if not isinstance(next_sequence, int) or next_sequence < 1:
                raise StateError("catalog-root-invalid", "catalog claim sequence is invalid", 4)
            observed_will = proof["root_meta"].get("claim_frame_will")
            if observed_will is not None and (not isinstance(observed_will, dict) or
                    set(observed_will) != {"sequence", "logical_key_sha256",
                                           "segment_generation", "frame_offset",
                                           "frame_length", "frame_digest"}):
                raise StateError("catalog-root-invalid", "claim frame will is invalid", 4)

            if observation is not None:
                frame, will = _catalog_claim_frame_from_observation(
                    logical, key_digest, pack_name, pack_identity["digest"],
                    reservation, request, observation)
            elif observed_will is not None:
                frame, will = _catalog_claim_frame(
                    logical, key_digest, pack_name, pack_identity["digest"],
                    reservation, request, observed_will.get("sequence"),
                    observed_will.get("segment_generation"),
                    observed_will.get("frame_offset"))
                if observed_will != will:
                    raise StateError("catalog-root-invalid", "claim frame will conflicts", 4)
                observation = _catalog_claim_staged_observation(
                    will, proof["root"][3][3].hex(), created_epoch)
                _instance_pack_write(container, key_digest, "claim", "OBSERVATION", observation)
                _catalog_barrier("catalog-claim-pack", "frame-will")
                recovered = True
            else:
                segment_generation = int(proof["root_meta"].get(
                    "active_segment_generation", 1))
                _catalog_active_member(proof)
                frame_offset = proof["root_meta"].get(
                    "active_segment_used_length")
                frame, will = _catalog_claim_frame(
                    logical, key_digest, pack_name, pack_identity["digest"],
                    reservation, request, next_sequence, segment_generation,
                    frame_offset)

            if observation is None and observed_will is None:
                raw_limit = os.environ.get("ZYZ_TEST_CLAIM_SEGMENT_FRAME_LIMIT")
                if raw_limit is None:
                    frame_limit = None
                elif re.fullmatch(r"[1-9][0-9]{0,3}", raw_limit):
                    frame_limit = int(raw_limit)
                else:
                    raise StateError("invalid-request",
                                     "claim segment test limit is invalid", 2)
                claim_count = proof["root_meta"].get("active_segment_claim_count", 0)
                if not isinstance(claim_count, int) or claim_count < 0:
                    raise StateError("catalog-root-invalid",
                                     "active segment claim count is invalid", 4)
                if ((frame_limit is not None and claim_count >= frame_limit) or
                        frame_offset + len(frame) >
                            CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL):
                    proof = _catalog_rotate_claim_segment(
                        container, global_fd, recovery_fd, proof)
                    next_sequence = proof["root_meta"]["next_sequence"]
                    segment_generation = proof["root_meta"][
                        "active_segment_generation"]
                    frame_offset = proof["root_meta"]["active_segment_used_length"]
                    frame, will = _catalog_claim_frame(
                        logical, key_digest, pack_name, pack_identity["digest"],
                        reservation, request, next_sequence, segment_generation,
                        frame_offset)

            sequence = will["sequence"]
            frame_digest = will["frame_digest"]
            segment_generation = will["segment_generation"]
            frame_offset = will["frame_offset"]
            committed = _catalog_claim_frame_committed(
                container, proof, will, frame, observed_will is None)

            if observed_will is None and next_sequence > sequence:
                if committed:
                    successor_digest = proof["root"][3][3].hex()
            if observed_will is None:
                if successor_digest is None:
                    active_generation = int(proof["root_meta"].get(
                        "active_segment_generation", 1))
                    _catalog_active_member(proof)
                    active_offset = proof["root_meta"].get(
                        "active_segment_used_length")
                    if committed or next_sequence < sequence:
                        raise StateError("catalog-root-invalid",
                                         "claim frame committed without ROOT will", 4)
                    if (next_sequence != sequence or
                            active_generation != segment_generation or
                            active_offset != frame_offset):
                        frame, will = _catalog_claim_frame(
                            logical, key_digest, pack_name, pack_identity["digest"],
                            reservation, request, next_sequence, active_generation,
                            active_offset)
                        sequence = will["sequence"]
                        frame_digest = will["frame_digest"]
                        segment_generation = will["segment_generation"]
                        frame_offset = will["frame_offset"]
                    selector = proof["root"][2][4096:5120]
                    _catalog_root_successor(global_fd, recovery_fd, proof, selector,
                                            {"claim_frame_will": will}, "will-claim-frame")
                    proof = _catalog_validate_genesis(container)
                    os.close(proof.pop("global_fd"))
                    observation = _catalog_claim_staged_observation(
                        will, proof["root"][3][3].hex(), created_epoch)
                    _instance_pack_write(
                        container, key_digest, "claim", "OBSERVATION", observation)
                    _catalog_barrier("catalog-claim-pack", "frame-will")
            elif observed_will != will or next_sequence != sequence:
                raise StateError("catalog-root-invalid", "claim frame will conflicts", 4)
            if successor_digest is None:
                result = _catalog_commit_active_frame(
                    container, proof, segment_generation, frame_offset, frame)
                _catalog_barrier("catalog-segment", "claim-frame-committed")
                selector = proof["root"][2][4096:5120]
                chain_region = _catalog_active_append_chain_region(
                    proof, result)
                successor = _catalog_root_successor(
                    global_fd, recovery_fd, proof, selector,
                    {"claim_frame_will": None, "next_sequence": sequence + 1,
                     "last_claim_key_sha256": key_digest,
                     "last_claim_frame_digest": frame_digest,
                     "active_segment_generation": segment_generation,
                     "active_segment_used_length": result["end"],
                     "active_segment_descriptor_digest": result["descriptor_digest"],
                         "active_segment_claim_count":
                         proof["root_meta"].get("active_segment_claim_count", 0) + 1},
                    "did-claim-frame", chain_region)
                successor_digest = successor["digest"].hex()
        finally:
            os.close(global_fd); os.close(recovery_fd)
    observation = {"schema_version": 1, "state": "claimed", "sequence": sequence,
                   "frame_digest": frame_digest, "claimed_root_digest": successor_digest,
                   "last_observed_epoch": created_epoch, "retry_epoch": None,
                   "blocked": None}
    _instance_pack_write(container, key_digest, "claim", "OBSERVATION", observation)
    _catalog_barrier("catalog-claim-pack", "claimed")
    return {"state": "claimed", "logical_key_sha256": key_digest,
            "claim_pack_basename": pack_name, "sequence": sequence,
            "frame_digest": frame_digest, "cell_index": reservation["cell_index"],
            "idempotent": recovered, "owner_record": owner}


def _catalog_claim_owner_did_create(container: Path, key_digest: str,
                                    expected_owner: dict,
                                    target_identities: list[dict]) -> dict:
    """Commit the exact after-set for a catalog-owned producer target."""
    if (not HEX64.fullmatch(key_digest) or not isinstance(expected_owner, dict) or
            expected_owner.get("state") != "will-create" or
            not isinstance(target_identities, list) or not target_identities):
        raise StateError("catalog-root-invalid", "claim did-create input is invalid", 4)
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        os.close(proof.pop("global_fd"))
        fd = _instance_open_pack(container, key_digest, "claim", True)
        try:
            observed = _instance_pack_read_fd(fd, "claim", key_digest, "OWNER")
            successor = dict(expected_owner, state="did-create",
                             target_identities=target_identities)
            if observed == successor:
                return successor
            if observed != expected_owner:
                raise StateError("catalog-root-invalid", "claim OWNER create facts conflict", 4)
            _catalog_claim_owner_barrier(expected_owner,"will-did-create")
            _instance_pack_write_fd(fd, "claim", key_digest, "OWNER", successor)
            _catalog_claim_owner_barrier(
                successor,"did-create-header-committed")
            _catalog_barrier("catalog-claim-pack", "owner-did-create")
            return successor
        finally:
            os.close(fd)


def _catalog_claim_owner_predecessor(expected_owner: dict,
                                     observed_owner: dict) -> bool:
    """Prove that an OWNER after-state descends from exact will-create facts."""
    if (not isinstance(expected_owner, dict) or
            expected_owner.get("state") != "will-create" or
            not isinstance(observed_owner, dict)):
        return False
    state = observed_owner.get("state")
    candidate = dict(observed_owner)
    if state == "released-clean":
        target_identities = candidate.get("target_identities")
        expected_release_digest = _catalog_digest(
            b"zyz-claim-released-target-set-v1",
            _catalog_json(target_identities if isinstance(
                target_identities, list) else [])).hex()
        if (not isinstance(candidate.get("released_epoch"), int) or
                candidate["released_epoch"] < 0 or
                candidate.get("released_target_set_digest") !=
                    expected_release_digest):
            return False
        candidate.pop("released_epoch", None)
        candidate.pop("released_target_set_digest", None)
        candidate["state"] = "did-create"
        state = "did-create"
    if state != "did-create" or not isinstance(
            candidate.get("target_identities"), list):
        return False
    candidate.pop("target_identities", None)
    candidate["state"] = "will-create"
    return candidate == expected_owner


def _catalog_claim_owner_release_clean(container: Path, key_digest: str,
                                       released_epoch: int) -> dict:
    """Record that the producer removed its exact data set; GC may retire metadata."""
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        os.close(proof.pop("global_fd"))
        scan_due = proof["root_meta"].get("claim_scan_due")
        if not isinstance(scan_due, bool):
            raise StateError("catalog-root-invalid", "claim scan hint is invalid", 4)
        if not scan_due:
            global_fd = os.open(
                os.fsencode(container / ".catalog-global-pack.v1"),
                os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
            recovery_fd = os.open(
                os.fsencode(container / ".catalog-recovery-pack.v1"),
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            try:
                _catalog_root_successor(
                    global_fd, recovery_fd, proof,
                    proof["root"][2][4096:5120],
                    {"claim_scan_due": True}, "claim-scan-due")
            finally:
                os.close(global_fd); os.close(recovery_fd)
        fd = _instance_open_pack(container, key_digest, "claim", True)
        try:
            observed = _instance_pack_read_fd(fd, "claim", key_digest, "OWNER")
            if not isinstance(observed, dict):
                raise StateError("catalog-root-invalid", "claim OWNER is absent", 4)
            if observed.get("state") == "released-clean":
                return observed
            if (observed.get("state") != "did-create" or
                    not isinstance(released_epoch, int) or released_epoch < 0):
                raise StateError("catalog-root-invalid", "claim OWNER is not releasable", 4)
            successor = dict(observed, state="released-clean",
                             released_epoch=released_epoch,
                             released_target_set_digest=_catalog_digest(
                                 b"zyz-claim-released-target-set-v1",
                                 _catalog_json(observed.get("target_identities", []))).hex())
            _catalog_claim_owner_barrier(observed,"will-release-clean")
            _instance_pack_write_fd(fd, "claim", key_digest, "OWNER", successor)
            _catalog_claim_owner_barrier(
                successor,"released-clean-header-committed")
            _catalog_barrier("catalog-claim-pack", "owner-released-clean")
            return successor
        finally:
            os.close(fd)


def _catalog_claim_owner_release_clean_locked(container: Path, key_digest: str,
                                              released_epoch: int) -> dict:
    """Commit OWNER released-clean while the caller holds CatalogFlock."""
    fd = _instance_open_pack(container, key_digest, "claim", True)
    try:
        observed = _instance_pack_read_fd(fd, "claim", key_digest, "OWNER")
        if not isinstance(observed, dict):
            raise StateError("catalog-root-invalid", "claim OWNER is absent", 4)
        if observed.get("state") == "released-clean":
            targets=observed.get("target_identities")
            expected=_catalog_digest(
                b"zyz-claim-released-target-set-v1",
                _catalog_json(targets if isinstance(targets,list) else [])).hex()
            if (not isinstance(observed.get("released_epoch"),int) or
                    observed["released_epoch"] < 0 or
                    observed.get("released_target_set_digest") != expected):
                raise StateError("catalog-root-invalid",
                                 "claim OWNER release receipt is invalid", 4)
            return observed
        if (observed.get("state") != "did-create" or
                not isinstance(released_epoch,int) or released_epoch < 0 or
                not isinstance(observed.get("target_identities"),list)):
            raise StateError("catalog-root-invalid",
                             "claim OWNER is not releasable", 4)
        successor=dict(
            observed,state="released-clean",released_epoch=released_epoch,
            released_target_set_digest=_catalog_digest(
                b"zyz-claim-released-target-set-v1",
                _catalog_json(observed["target_identities"])).hex())
        _catalog_claim_owner_barrier(observed,"will-release-clean")
        _instance_pack_write_fd(fd,"claim",key_digest,"OWNER",successor)
        _catalog_claim_owner_barrier(
            successor,"released-clean-header-committed")
        _catalog_barrier("catalog-claim-pack","owner-released-clean")
        return successor
    finally:
        os.close(fd)


def read_json(path: Path, limit: int = 16384) -> dict | None:
    parent=os.open(os.fsencode(path.parent),os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|
                   getattr(os,"O_NOFOLLOW",0)|getattr(os,"O_CLOEXEC",0))
    try: return read_json_at(parent,os.fsencode(path.name),limit)
    finally: os.close(parent)


def read_json_bytes_at(dirfd: int, name: bytes, limit: int = 16384) -> tuple[dict,bytes,os.stat_result] | None:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try: fd = os.open(name, flags, dir_fd=dirfd)
    except FileNotFoundError: return None
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink < 1 or before.st_size > limit:
            raise StateError("invalid-schema", "descriptor-bound JSON identity/size is invalid")
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(fd, min(131072, limit + 1 - len(data)))
            if not chunk: break
            data.extend(chunk)
        after = os.fstat(fd)
    finally: os.close(fd)
    if len(data) > limit or (before.st_dev,before.st_ino,before.st_nlink,before.st_size,before.st_mtime_ns) != (
            after.st_dev,after.st_ino,after.st_nlink,after.st_size,after.st_mtime_ns):
        raise StateError("invalid-schema", "descriptor-bound JSON changed or is oversized")
    try: value = json.loads(data)
    except Exception: raise StateError("invalid-schema", "descriptor-bound JSON is invalid")
    if not isinstance(value, dict): raise StateError("invalid-schema", "descriptor-bound JSON is not an object")
    return value,bytes(data),before


def read_json_at(dirfd: int, name: bytes, limit: int = 16384) -> dict | None:
    observed=read_json_bytes_at(dirfd,name,limit)
    return None if observed is None else observed[0]


@dataclass
class SnapshotArtifact:
    """A snapshot file whose parent directory remains pinned by descriptor."""
    path: Path
    parent_fd: int
    raw_name: bytes
    expected_identity: dict
    claim_container: Path | None = None
    claim_key_digest: str | None = None

    def __fspath__(self):
        return os.fspath(self.path)

    @property
    def parent(self):
        return self.path.parent

    @property
    def name(self):
        return self.path.name

    def open_snapshot_fd(self) -> tuple[int, str]:
        fd = os.open(self.raw_name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0)|
                     getattr(os,"O_CLOEXEC",0),dir_fd=self.parent_fd)
        mount = runtime_native._mount_id_at(self.parent_fd,self.raw_name,fd)
        observed = os.fstat(fd)
        expected = self.expected_identity
        if ((observed.st_dev,observed.st_ino,observed.st_nlink,observed.st_size,
             observed.st_mtime_ns,mount) !=
                (expected["dev"],expected["ino"],expected["nlink"],expected["size"],
                 expected["mtime_ns"],expected["mount_id"])):
            os.close(fd)
            raise StateError("snapshot-unavailable", "retained snapshot artifact name binding changed")
        return fd, mount

    def close(self) -> None:
        if self.parent_fd >= 0:
            os.close(self.parent_fd); self.parent_fd = -1
        if self.claim_container is not None and self.claim_key_digest is not None:
            try:
                os.lstat(os.fsencode(self.path.parent))
            except FileNotFoundError:
                _catalog_claim_owner_release_clean(
                    self.claim_container, self.claim_key_digest, int(time.time()))

    def unlink(self) -> None:
        try: os.unlink(self.raw_name,dir_fd=self.parent_fd)
        except FileNotFoundError: pass

    def exists(self) -> bool:
        try: os.stat(self.raw_name,dir_fd=self.parent_fd,follow_symlinks=False)
        except FileNotFoundError: return False
        return True

    def stat(self):
        return os.stat(self.raw_name,dir_fd=self.parent_fd,follow_symlinks=False)


def process_birth(pid: int | None = None) -> tuple[str, str]:
    pid = os.getpid() if pid is None else pid
    if sys.platform.startswith("linux"):
        boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        stat = Path(f"/proc/{pid}/stat").read_text()
        close = stat.rfind(")")
        fields = stat[close + 2:].split()
        return boot, fields[19]
    if sys.platform == "darwin":
        import ctypes
        import subprocess
        boot = subprocess.check_output(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"], text=True).strip()
        lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        # PROC_PIDUNIQIDENTIFIERINFO is currently 56 bytes. Keep the complete
        # opaque kernel record as the strong token instead of guessing a short
        # ctypes struct; libproc rejects undersized buffers with ENOMEM.
        info = ctypes.create_string_buffer(56)
        got = lib.proc_pidinfo(pid, 17, 0, info, len(info))
        if got != len(info):
            raise OSError(ctypes.get_errno(), "proc_pidinfo")
        return boot, bytes(info.raw).hex()
    raise OSError("strong process identity unavailable")


def _membership_item(name: bytes, observed: os.stat_result) -> bytes:
    body=(len(name).to_bytes(4,"big")+name+
          struct.pack(">QQQQ",stat.S_IFMT(observed.st_mode),observed.st_rdev,
                      observed.st_dev,observed.st_ino))
    return hashlib.sha256(body).digest()


def _directory_membership(fd: int, exclude: bytes | None = None) -> dict:
    accumulator=bytearray(32); count=0
    with os.scandir(fd) as entries:
        for entry in entries:
            name=os.fsencode(entry.name)
            if name == exclude: continue
            observed=os.stat(name,dir_fd=fd,follow_symlinks=False)
            item=_membership_item(name,observed)
            for index,value in enumerate(item): accumulator[index]^=value
            count+=1
    return {"count":count,"xor_sha256":bytes(accumulator).hex()}


def agents_dir(task: str) -> Path:
    task_b = raw_bytes(task)
    if not task_b or len(task_b) > MAX_ARG:
        raise StateError("invalid-task-dir", "task-dir must contain 1..4096 bytes", 2)
    root = Path(task)
    if not root.is_dir():
        raise StateError("missing-task", "task directory does not exist", 3)
    path = root / "runtime" / "agents"
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def base_envelope(args: list[str]) -> dict:
    total = sum(len(raw_bytes(a)) for a in args)
    if total > 12288 or any(len(raw_bytes(a)) > MAX_ARG for a in args):
        raise StateError("invalid-argument", "argv bounds exceeded", 2)
    utf8 = []
    for a in args:
        try: a.encode("utf-8"); utf8.append(a)
        except UnicodeEncodeError: utf8 = None; break
    return {
        "schema_version": 1, "command": args[0] if args else None,
        "ok": True, "state": None, "error": None, "instance_key": None,
        "trusted": None, "tracking_capability": None,
        "terminal_kind": None, "terminal_epoch": None,
        "cleanup_state": "not-applicable", "cleanup_pending": False,
        "cleanup_error": None, "cleanup_intent_digest": None,
        "cleanup_receipt_digest": None, "probe_id": None,
        "probe_id_sha256": None, "deadline_epoch": None,
        "creation_enabled": None, "idempotent": False, "late_clean": False,
        "preserved_terminal_kind": None, "argv": utf8,
        "argv_b64": [base64.b64encode(raw_bytes(a)).decode() for a in args],
        "human_message": None, "shell_command": None,
        "inflight_capability": "unknown", "inflight_count": 0,
        "no_output_state": None, "no_output_changed": None,
        "baseline_epoch": None, "baseline_digest": None,
        "current_digest": None,
    }


SNAPSHOT_POLICY = (
    ("ZYZ_NO_OUTPUT_MAX_PATHS",10000,1,1000000),
    ("ZYZ_NO_OUTPUT_MAX_FILE_BYTES",16777216,1,1073741824),
    ("ZYZ_NO_OUTPUT_MAX_TOTAL_BYTES",67108864,1,2147483647),
    ("ZYZ_NO_OUTPUT_MAX_INVENTORY_BYTES",33554432,1,2147483647),
    ("ZYZ_NO_OUTPUT_MAX_MANIFEST_BYTES",33554432,1,2147483647),
    ("ZYZ_NO_OUTPUT_MAX_RSS_BYTES",134217728,16777216,1073741824),
    ("ZYZ_NO_OUTPUT_MAX_TEMP_BYTES",134217728,1,2147483647),
    ("ZYZ_NO_OUTPUT_SNAPSHOT_TIMEOUT_SEC",8,1,8),
)


def snapshot_policy(source: dict | None = None) -> dict:
    if source is None:
        return {name: env_uint(name, default, low, high) for name,default,low,high in SNAPSHOT_POLICY}
    expected = {name for name,_,_,_ in SNAPSHOT_POLICY}
    if set(source) != expected:
        raise StateError("snapshot-unavailable", "baseline comparison policy is invalid")
    result = {}
    for name, default, low, high in SNAPSHOT_POLICY:
        value = source.get(name)
        if not isinstance(value, int) or not low <= value <= high:
            raise StateError("snapshot-unavailable", f"baseline {name} is invalid")
        result[name] = value
    return result


def snapshot_task_id(task: str) -> str:
    path = Path(task)
    if path.parent.name != "tasks" or path.parent.parent.name != ".zyz-worker":
        raise StateError("snapshot-unavailable", "task is outside .zyz-worker/tasks namespace")
    value = path.name
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", value) or value in (".", ".."):
        raise StateError("snapshot-unavailable", "task id is outside namespace grammar")
    return value


def native_snapshot_round(task: str, agents: Path, key: str, policy: dict, label: str,
                          absolute_deadline: float | None = None,
                          binding_authority=None) -> tuple[SnapshotArtifact, dict]:
    # Fixed claim GC is the only recovery authority.  It runs outside the
    # instance lock and never discovers ownership from `.snapshot-owner.*`.
    gc_step_command(task, "lifecycle")
    task_id = snapshot_task_id(task)
    nonce = nonce_hex() + nonce_hex()
    temp_dir = agents / f".snapshot-tmp.{nonce}"
    boot, birth = process_birth()
    binding = (binding_authority.revalidate() if binding_authority is not None
               else runtime_native.owner_binding(task_id))
    _, fixed_live_digest = read_live_inventory(agents, key)
    owner = {"schema_version": 1, "nonce": nonce, "pid": os.getpid(),
             "hostname": socket.gethostname(), "boot_id": boot,
             "process_birth_token": birth, "created_epoch": int(time.time()),
             "instance_key": key, "task_id": task_id, "scanner_schema": 1,
             "temp_basename": temp_dir.name,
             "task_identity_digest": binding["task_identity_digest"],
             "root_identity_digest": binding["root_identity_digest"],
             "runtime_identity_digest": binding["runtime_identity_digest"],
             "baseline_inventory_digest": fixed_live_digest,
             "runtime_mount_id": binding["runtime_mount_id"],
             "max_temp_bytes":policy["ZYZ_NO_OUTPUT_MAX_TEMP_BYTES"],
             "native_binding_digest": binding["native_binding_digest"],
             "writer_pid": None,"writer_birth_token": None}
    output = temp_dir / f"{label}.records"
    process = None; gate_read = gate_write = agents_fd = -1
    temp_stat=None; claim_container=None; claim_result=None
    command = [sys.executable, str(Path(runtime_native.__file__).resolve()), "scan", task_id,
               str(temp_dir), json.dumps(policy, sort_keys=True, separators=(",", ":")), str(output),
               binding["native_binding_digest"]]
    def cleanup_owned_temp() -> None:
        if temp_stat is None:
            return
        temp_fd = -1
        try:
            temp_name = os.fsencode(temp_dir.name)
            temp_fd = os.open(temp_name,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|
                              getattr(os,"O_NOFOLLOW",0)|getattr(os,"O_CLOEXEC",0),dir_fd=agents_fd)
            rebound = os.fstat(temp_fd)
            if ((rebound.st_dev,rebound.st_ino,rebound.st_mode,rebound.st_nlink,
                 runtime_native._mount_id_at(agents_fd,temp_name,temp_fd)) !=
                    (temp_stat.st_dev,temp_stat.st_ino,temp_stat.st_mode,temp_stat.st_nlink,
                     owner["runtime_mount_id"])):
                return
            with os.scandir(temp_fd) as children:
              for child in children:
                raw_name = os.fsencode(child.name)
                if raw_name in (b".",b"..") or b"/" in raw_name:
                    return
                observed = os.stat(raw_name,dir_fd=temp_fd,follow_symlinks=False)
                if not stat.S_ISREG(observed.st_mode) or observed.st_nlink < 1:
                    return
                os.unlink(raw_name,dir_fd=temp_fd)
            os.fsync(temp_fd)
            os.close(temp_fd); temp_fd = -1
            os.rmdir(temp_name,dir_fd=agents_fd)
            if claim_container is not None and claim_result is not None:
                _catalog_claim_owner_release_clean(
                    claim_container, claim_result["logical_key_sha256"], int(time.time()))
        except Exception:
            pass
        finally:
            if temp_fd >= 0: os.close(temp_fd)
    cleanup_requested=False
    try:
        gate_read, gate_write = os.pipe()
        agents_fd = os.open(os.fsencode(agents), os.O_RDONLY | getattr(os,"O_DIRECTORY",0) |
                            getattr(os,"O_NOFOLLOW",0) | getattr(os,"O_CLOEXEC",0))
        process = subprocess.Popen(command, start_new_session=True, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, close_fds=True, pass_fds=(gate_read,agents_fd),
                                   env={**os.environ,"ZYZ_SNAPSHOT_START_GATE_FD":str(gate_read),
                                        "ZYZ_SNAPSHOT_AGENTS_FD":str(agents_fd),
                                        "ZYZ_SNAPSHOT_TEMP_BASENAME":temp_dir.name})
        os.close(gate_read); gate_read = -1
        _, writer_birth = process_birth(process.pid)
        owner.update(writer_pid=process.pid,writer_birth_token=writer_birth)
        claim_container, _ = ensure_catalog_genesis(task)
        claim_owner_facts = {
            "nonce": nonce, "creator_pid": os.getpid(),
            "creator_boot_id": boot, "creator_birth_token": birth,
            "writer_pid": process.pid, "writer_birth_token": writer_birth,
            "task_id": task_id,
            "task_identity_digest": binding["task_identity_digest"],
            "root_identity_digest": binding["root_identity_digest"],
            "runtime_identity_digest": binding["runtime_identity_digest"],
            "runtime_mount_id": binding["runtime_mount_id"],
            "native_binding_digest": binding["native_binding_digest"],
            "instance_key_digest": hashlib.sha256(key.encode()).hexdigest(),
            "temp_basename": temp_dir.name,
            "max_paths":policy["ZYZ_NO_OUTPUT_MAX_PATHS"],
            "max_file_bytes":policy["ZYZ_NO_OUTPUT_MAX_FILE_BYTES"],
            "max_total_bytes":policy["ZYZ_NO_OUTPUT_MAX_TOTAL_BYTES"],
            "max_temp_bytes":policy["ZYZ_NO_OUTPUT_MAX_TEMP_BYTES"],
            "targets": [
                {"basename": temp_dir.name, "type": "directory", "mode": 0o700,
                 "max_physical_bytes": policy["ZYZ_NO_OUTPUT_MAX_TEMP_BYTES"]},
                {"basename": output.name, "parent_basename": temp_dir.name,
                 "type": "regular", "max_physical_bytes":
                     policy["ZYZ_NO_OUTPUT_MAX_MANIFEST_BYTES"]},
                {"basename": "observation.json", "parent_basename": temp_dir.name,
                 "type": "regular", "max_physical_bytes": 16384},
            ],
        }
        claim_result = _catalog_claim_create(
            claim_container, "snapshot-temp", key, nonce,
            policy["ZYZ_NO_OUTPUT_MAX_TEMP_BYTES"], owner["created_epoch"],
            _gc_config(), claim_owner_facts)
        if os.environ.get("ZYZ_TEST_CLAIM_REPLAY_SAME_OWNER") == "1":
            replay = _catalog_claim_create(
                claim_container, "snapshot-temp", key, nonce,
                policy["ZYZ_NO_OUTPUT_MAX_TEMP_BYTES"], owner["created_epoch"],
                _gc_config(), claim_owner_facts)
            if (not replay.get("idempotent") or
                    replay.get("logical_key_sha256") !=
                    claim_result.get("logical_key_sha256") or
                    replay.get("sequence") != claim_result.get("sequence") or
                    replay.get("frame_digest") != claim_result.get("frame_digest") or
                    replay.get("owner_record") != claim_result.get("owner_record")):
                raise StateError("catalog-root-invalid",
                                 "same-owner public claim replay diverged", 4)
            _catalog_barrier("catalog-claim-pack", "same-owner-replay")
        temp_dir.mkdir(mode=0o700)
        temp_fd = os.open(os.fsencode(temp_dir), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) |
                          getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
        try:
            temp_stat = os.fstat(temp_fd)
            if (stat.S_IMODE(temp_stat.st_mode) != 0o700 or
                    runtime_native.mount_id_path(temp_dir) != owner["runtime_mount_id"]):
                raise StateError("snapshot-unavailable", "snapshot temp binding/mount is invalid")
            target_identity = {
                "basename": temp_dir.name, "type": "directory",
                "dev": temp_stat.st_dev, "ino": temp_stat.st_ino,
                "nlink": temp_stat.st_nlink, "mode": stat.S_IMODE(temp_stat.st_mode),
                "mount_id": runtime_native._mount_id_at(
                    agents_fd, os.fsencode(temp_dir.name), temp_fd),
            }
        finally: os.close(temp_fd)
        _catalog_claim_owner_did_create(
            claim_container, claim_result["logical_key_sha256"],
            claim_result["owner_record"], [target_identity])
        if (_instance_pack_read(claim_container, claim_result["logical_key_sha256"],
                                "claim", "OWNER") !=
                {**claim_result["owner_record"], "state":"did-create",
                 "target_identities":[target_identity]}):
            raise StateError("snapshot-unavailable", "snapshot claim changed before temp activation")
        _write_all(gate_write,b"G","snapshot gate"); os.close(gate_write); gate_write = -1
        try:
            if os.getpgid(process.pid) != process.pid:
                raise StateError("snapshot-unavailable", "scanner process group was not isolated")
        except ProcessLookupError:
            pass
        deadline = min(time.monotonic() + policy["ZYZ_NO_OUTPUT_SNAPSHOT_TIMEOUT_SEC"],
                       absolute_deadline if absolute_deadline is not None else float("inf"))
        if time.monotonic() >= deadline - 0.25:
            raise StateError("snapshot-unavailable", "snapshot deadline lacks cleanup reserve")
        while process.poll() is None and time.monotonic() < deadline:
            if _publication_disabled(claim_container, key):
                try: os.killpg(process.pid, __import__("signal").SIGTERM)
                except ProcessLookupError: pass
                try: process.wait(timeout=.2)
                except subprocess.TimeoutExpired:
                    try: os.killpg(process.pid, __import__("signal").SIGKILL)
                    except ProcessLookupError: pass
                    process.wait()
                raise StateError("snapshot-unavailable", "native snapshot was cancelled by terminal state")
            time.sleep(.01)
        if process.poll() is None:
            try: os.killpg(process.pid, __import__("signal").SIGTERM)
            except ProcessLookupError: pass
            try: process.wait(timeout=.2)
            except subprocess.TimeoutExpired:
                try: os.killpg(process.pid, __import__("signal").SIGKILL)
                except ProcessLookupError: pass
                process.wait()
            raise StateError("snapshot-unavailable", "native snapshot child timed out")
        temp_fd = os.open(os.fsencode(temp_dir), os.O_RDONLY | getattr(os,"O_DIRECTORY",0) |
                          getattr(os,"O_NOFOLLOW",0) | getattr(os,"O_CLOEXEC",0))
        try:
            observation_record = read_json_at(temp_fd, b"observation.json", 16384)
            if (os.fstat(temp_fd).st_dev,os.fstat(temp_fd).st_ino) != (temp_stat.st_dev,temp_stat.st_ino):
                raise StateError("snapshot-unavailable", "snapshot temp fd binding changed before observation")
        finally: os.close(temp_fd)
        if process.returncode != 0 or not observation_record or "error" in observation_record:
            detail = (observation_record or {}).get("error", f"child exit {process.returncode}")
            raise StateError("snapshot-unavailable", str(detail)[:512])
        observation = observation_record
        if observation.get("native_binding_digest") != binding["native_binding_digest"]:
            raise StateError("snapshot-unavailable", "scanner observation changed native binding")
        if (binding_authority is not None and
                binding_authority.revalidate()["native_binding_digest"] != binding["native_binding_digest"]):
            raise StateError("snapshot-unavailable", "retained scanner authority changed")
        artifact = artifact_record(output, "private-records", 0)
        retained_parent = os.open(os.fsencode(temp_dir.name),os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|
                                  getattr(os,"O_NOFOLLOW",0)|getattr(os,"O_CLOEXEC",0),dir_fd=agents_fd)
        retained = SnapshotArtifact(
            output, retained_parent, os.fsencode(output.name), artifact,
            claim_container, claim_result["logical_key_sha256"])
        parsed = runtime_native.read_snapshot_records(
            retained, policy["ZYZ_NO_OUTPUT_MAX_PATHS"], policy["ZYZ_NO_OUTPUT_MAX_MANIFEST_BYTES"],
            expected_identity=artifact)
        if (parsed["path_count"] != observation.get("path_count") or
                parsed["records_bytes"] != observation.get("manifest_bytes") or
                parsed["records_sha256"] != observation.get("manifest_digest")):
            raise StateError("snapshot-unavailable", "scanner observation differs from records artifact")
        observation["records_sha256"] = parsed["whole_sha256"]
        temp_fd = os.open(os.fsencode(temp_dir), os.O_RDONLY | getattr(os,"O_DIRECTORY",0) |
                          getattr(os,"O_NOFOLLOW",0) | getattr(os,"O_CLOEXEC",0))
        try: os.unlink(b"observation.json", dir_fd=temp_fd); os.fsync(temp_fd)
        finally: os.close(temp_fd)
        return retained, observation
    except runtime_native.NativeSnapshotError as exc:
        cleanup_requested=True
        raise StateError("snapshot-unavailable", str(exc))
    except (MemoryError, OSError, StateError) as exc:
        cleanup_requested=True
        if isinstance(exc, StateError):
            raise
        raise StateError("snapshot-unavailable", f"native snapshot failed: {exc}")
    finally:
        if gate_read >= 0: os.close(gate_read)
        if gate_write >= 0: os.close(gate_write)
        if process is not None and process.poll() is None:
            try: os.killpg(process.pid, __import__("signal").SIGKILL)
            except ProcessLookupError: pass
            process.wait()
        if cleanup_requested and process is not None and process.poll() is not None and agents_fd >= 0:
            cleanup_owned_temp()
        if agents_fd >= 0: os.close(agents_fd)


def artifact_record(path: Path, purpose: str, generation: int) -> dict:
    if hasattr(path,"open_snapshot_fd"):
        fd, mount = path.open_snapshot_fd()
        try:
            st = os.fstat(fd); digest = sha_open_fd(fd)
        finally: os.close(fd)
    else:
        st = os.lstat(os.fsencode(path)); digest = sha_file(path)
        mount = runtime_native.mount_id_path(path)
    if not stat.S_ISREG(st.st_mode) or st.st_nlink < 1:
        raise StateError("publication-invalid", "snapshot artifact is not a linked regular file")
    return {"purpose": purpose, "generation": generation, "basename": path.name,
            "type": "regular", "size": st.st_size, "sha256": digest,
            "dev": st.st_dev, "ino": st.st_ino, "nlink": st.st_nlink,
            "mtime_ns": st.st_mtime_ns,
            "mount_id": mount}


def validate_artifact(agents: Path, item: dict) -> Path:
    required = {"purpose","generation","basename","type","size","sha256","dev","ino",
                "nlink","mtime_ns","mount_id"}
    if set(item) != required or item["type"] != "regular" or not re.fullmatch(r"[A-Za-z0-9._-]{1,255}", str(item["basename"])):
        raise StateError("published-inventory-invalid", "published artifact schema is invalid")
    path = agents / item["basename"]
    try: st = os.lstat(os.fsencode(path)); digest = sha_file(path)
    except OSError: raise StateError("published-inventory-invalid", "published artifact is missing")
    if (not stat.S_ISREG(st.st_mode) or
            (st.st_size, st.st_dev, st.st_ino, st.st_nlink, st.st_mtime_ns,
             digest, runtime_native.mount_id_path(path)) !=
            (item["size"], item["dev"], item["ino"], item["nlink"], item["mtime_ns"],
             item["sha256"], item["mount_id"])):
        raise StateError("published-inventory-invalid", "published artifact identity changed")
    return path


def _publication_container(agents: Path) -> Path:
    """Resolve the fixed control container paired with the legacy data dir."""
    if agents.name != "agents":
        raise StateError("publication-invalid", "publication data directory is invalid")
    return _catalog_container(agents.parent, False)


def _publication_read_journal(container: Path, key: str) -> dict | None:
    try:
        return _instance_pack_read(container, key, "work", "PUBLICATION_JOURNAL")
    except FileNotFoundError:
        return None


def _publication_write_journal(container: Path, key: str, journal: dict,
                               phase: str | None = None) -> dict:
    successor = dict(journal)
    if phase is not None:
        successor["phase"] = phase
    limit = 4096 if successor.get("txn_type") == "snapshot-publish-receipt" else 8192
    if len(_catalog_json(successor)) > limit:
        raise StateError("publication-invalid", "publication journal exceeds its fixed bound")
    _instance_pack_write(container, key, "work", "PUBLICATION_JOURNAL", successor)
    barrier = os.environ.get("ZYZ_TEST_TRANSITION_STOP_AFTER")
    selected_phase = str(successor.get("phase", ""))
    if barrier in (selected_phase, f"snapshot-publish:{selected_phase}"):
        os._exit(86)
    return successor


def _publication_disabled(container: Path, key: str) -> bool:
    """Read the fixed terminal gate without consulting reachable pathnames."""
    audit_fd = work_fd = -1
    try:
        audit_fd = _instance_open_pack(container, key, "audit", False)
        work_fd = _instance_open_pack(container, key, "work", False)
    except FileNotFoundError:
        if audit_fd >= 0: os.close(audit_fd)
        return True
    try:
        if any(_instance_pack_read_fd(audit_fd, "audit", key, slot) is not None
               for slot in ("DONE", "FINALIZED")):
            return True
        if _instance_pack_read_fd(work_fd, "work", key, "TERMINAL_HANDOFF") is not None:
            return True
        transition = _instance_pack_read_fd(
            work_fd, "work", key, "TRANSITION_JOURNAL")
        return (isinstance(transition, dict) and
                transition.get("txn_type") in ("stop", "finalize") and
                transition.get("phase") != "committed-start")
    finally:
        if work_fd >= 0: os.close(work_fd)
        if audit_fd >= 0: os.close(audit_fd)


def _publication_commit_cleanup_intent(container: Path, key: str,
                                       intent: dict) -> str:
    """Append one bounded retired-generation owner to a fixed work slot."""
    digest = json_digest(intent)
    fd = _instance_open_pack(container, key, "work", True)
    try:
        current = _instance_pack_read_fd(
            fd, "work", key, "TERMINAL_STAGING")
        if current is None:
            current = {"schema_version": 1, "instance_key": key,
                       "publication_cleanup_intents": []}
        if (set(current) != {"schema_version","instance_key",
                            "publication_cleanup_intents"} or
                current.get("schema_version") != 1 or
                current.get("instance_key") != key or
                not isinstance(current.get("publication_cleanup_intents"),list)):
            raise StateError("publication-invalid", "cleanup intent slot is invalid")
        intents = []
        for row in current["publication_cleanup_intents"]:
            claim_digest=(row.get("retired_claim_key_sha256")
                          if isinstance(row,dict) else None)
            if (isinstance(row,dict) and row.get("claim_state") == "retired" and
                    HEX64.fullmatch(str(claim_digest))):
                try:
                    os.lstat(os.fsencode(
                        container/f"{claim_digest}.claim-pack.v1"))
                except FileNotFoundError:
                    continue
            intents.append(row)
        matches = [row for row in intents if json_digest(row) == digest]
        if matches:
            if len(matches) != 1 or matches[0] != intent:
                raise StateError("publication-invalid", "cleanup intent digest conflicts")
            return digest
        if len(intents) >= 16:
            raise StateError("publication-invalid", "cleanup intent slot is full", 4, True)
        successor = {**current, "publication_cleanup_intents":intents + [intent]}
        if len(_catalog_json(successor)) > 8192:
            raise StateError("publication-invalid", "cleanup intent slot exceeds its bound")
        _instance_pack_write_fd(fd,"work",key,"TERMINAL_STAGING",successor,
                                "snapshot-publish")
        return digest
    finally: os.close(fd)


def read_live_inventory(agents: Path, key: str) -> tuple[dict | None, str | None]:
    container = _publication_container(agents)
    try: record = _instance_pack_read(container, key, "work", "LIVE_INVENTORY")
    except FileNotFoundError: return None, None
    if record is None: return None, None
    if (set(record) != {"schema_version","instance_key","generation","active","committed_epoch"} or
            record["schema_version"] != 1 or record["instance_key"] != key or
            not isinstance(record["generation"], int) or not isinstance(record["active"], list) or
            len(record["active"]) > 16):
        raise StateError("published-inventory-invalid", "live published inventory schema is invalid")
    for item in record["active"]: validate_artifact(agents, item)
    return record, json_digest(record)


def published_snapshot_pair(agents: Path, key: str, purpose: str) -> tuple[dict, Path, dict, dict]:
    live, _ = read_live_inventory(agents, key)
    if live is None:
        raise StateError("snapshot-unavailable", "published snapshot inventory is absent")
    records = [item for item in live["active"] if item.get("purpose") == purpose + "-records"]
    headers = [item for item in live["active"] if item.get("purpose") == purpose + "-header"]
    if len(records) != 1 or len(headers) != 1:
        raise StateError("snapshot-unavailable", f"published {purpose} snapshot pair is not unique")
    if records[0]["generation"] != headers[0]["generation"]:
        raise StateError("snapshot-unavailable", f"published {purpose} snapshot generations differ")
    records_path = validate_artifact(agents, records[0])
    header = read_json(validate_artifact(agents, headers[0]), 16384)
    if not isinstance(header, dict) or header.get("instance_key") != key:
        raise StateError("snapshot-unavailable", f"published {purpose} header is invalid")
    try:
        parsed = runtime_native.read_snapshot_records(
            records_path, int(header["comparison_policy"]["ZYZ_NO_OUTPUT_MAX_PATHS"]),
            int(header["comparison_policy"]["ZYZ_NO_OUTPUT_MAX_MANIFEST_BYTES"]),
            expected_identity=records[0])
    except (KeyError, TypeError, ValueError, runtime_native.NativeSnapshotError) as exc:
        raise StateError("snapshot-unavailable", f"published {purpose} records are invalid: {exc}")
    observation = header.get("observation")
    if (not isinstance(observation, dict) or parsed["path_count"] != observation.get("path_count") or
            parsed["records_bytes"] != observation.get("manifest_bytes") or
            parsed["records_sha256"] != observation.get("manifest_digest") or
            parsed["whole_sha256"] != records[0].get("sha256")):
        raise StateError("snapshot-unavailable", f"published {purpose} header/records binding differs")
    return header, records_path, parsed, records[0]


def publication_step(agents: Path, journal: dict, binding_authority=None) -> dict:
    key = journal["instance_key"]
    container = _publication_container(agents)
    def advance(next_phase: str) -> None:
        nonlocal journal, phase
        journal = _publication_write_journal(container, key, journal, next_phase)
        phase = next_phase
    active = journal["staged_inventory"]["active"]
    targets = journal["publish_targets"]
    phase = journal.get("phase")
    for index, item in enumerate(targets, 1):
        will, did = f"will-target-{index}", f"did-target-{index}"
        prior = "prepared" if index == 1 else f"did-target-{index - 1}"
        if phase == prior or phase == will:
            if phase == prior: advance(will)
            source = agents / item["source_parent_basename"] / item["source_basename"]
            target = agents / item["basename"]
            if source.exists(): atomic_rename_noreplace(source, target)
            validate_artifact(agents, {name:item[name] for name in
                ("purpose","generation","basename","type","size","sha256","dev","ino",
                 "nlink","mtime_ns","mount_id")})
            advance(did)
        elif phase == did:
            validate_artifact(agents, {name:item[name] for name in
                ("purpose","generation","basename","type","size","sha256","dev","ino",
                 "nlink","mtime_ns","mount_id")})
        elif phase not in ("will-live-inventory","did-live-inventory","committed") and not re.fullmatch(
                r"(?:will|did)-retired-cleanup-intent-[0-9]+",str(phase)):
            continue
    if phase == f"did-target-{len(targets)}":
        if binding_authority is not None:
            observed = binding_authority.revalidate()
            if observed["native_binding_digest"] != journal.get("native_binding_digest"):
                raise StateError("publication-invalid", "retained authority changed before visibility commit")
        advance("will-live-inventory")
    live = {k:v for k,v in journal["staged_inventory"].items() if k != "staged"}
    if phase == "will-live-inventory":
        current, current_digest = read_live_inventory(agents, key)
        if current != live:
            if current_digest != journal.get("prior_inventory_digest"):
                raise StateError("publication-invalid", "LIVE_INVENTORY prior digest changed")
            fd = _instance_open_pack(container, key, "work", True)
            try:
                _instance_pack_write_fd(fd, "work", key, "LIVE_INVENTORY", live,
                                        "snapshot-publish")
            finally: os.close(fd)
        elif current_digest != json_digest(live):
            raise StateError("publication-invalid", "LIVE_INVENTORY candidate digest changed")
        advance("did-live-inventory")
    elif phase in ("did-live-inventory","committed") or re.fullmatch(
            r"(?:will|did)-retired-cleanup-intent-[0-9]+",str(phase)):
        current, current_digest = read_live_inventory(agents, key)
        if current != live or current_digest != json_digest(live):
            raise StateError("publication-invalid", "LIVE_INVENTORY changed after visibility commit")
    retired = journal.get("retired", [])
    for index,item in enumerate(retired):
        prior="did-live-inventory" if index == 0 else f"did-retired-cleanup-intent-{index-1}"
        will=f"will-retired-cleanup-intent-{index}"; did=f"did-retired-cleanup-intent-{index}"
        if phase in (prior,will):
            if phase == prior: advance(will)
            intent={"schema_version":1,"instance_key":key,"owner_generation":journal["generation"],
                    "retired_index":index,"retired":item,"live_inventory_digest":json_digest(live),
                    "created_epoch":journal["created_epoch"],
                    "retired_claim_key_sha256":_catalog_claim_key(
                        "snapshot-publication",key,
                        f"publication-{item['generation']}")[0],
                    "claim_state":"pending","claim_receipt_digest":None}
            intent_digest=_publication_commit_cleanup_intent(container,key,intent)
            digests=list(journal.get("retired_intent_digests",[]))
            if len(digests) == index: digests.append(intent_digest)
            elif digests[index] != intent_digest:
                raise StateError("publication-invalid","retired intent digest changed")
            journal["retired_intent_digests"]=digests
            advance(did)
    final_prior=("did-live-inventory" if not retired else
                 f"did-retired-cleanup-intent-{len(retired)-1}")
    if phase == final_prior:
        if binding_authority is not None:
            observed = binding_authority.revalidate()
            if observed["native_binding_digest"] != journal.get("native_binding_digest"):
                raise StateError("publication-invalid", "retained authority changed before publication commit")
        journal["committed_epoch"] = int(time.time())
        advance("committed")
    return live


def retire_publication_journal(agents: Path, record: dict) -> dict:
    """Compact a committed publish WAL without an unjournaled unlink window."""
    container = _publication_container(agents)
    key = record.get("instance_key")
    if record.get("txn_type") == "snapshot-publish":
        if record.get("phase") == "committed":
            committed_digest=json_digest(record)
            live={k:v for k,v in record["staged_inventory"].items() if k != "staged"}
            receipt={"schema_version":1,"txn_type":"snapshot-publish-receipt",
                     "phase":"did-receipt","instance_key":record["instance_key"],
                     "generation":record["generation"],"result":"committed",
                     "committed_journal_digest":committed_digest,
                     "live_inventory_digest":json_digest(live),
                     "retired_intent_digests":record.get("retired_intent_digests",[]),
                     "committed_epoch":record["committed_epoch"]}
            record.update(phase="will-receipt",committed_journal_digest=committed_digest,
                          receipt_record=receipt,receipt_digest=json_digest(receipt))
            record = _publication_write_journal(container,key,record)
        elif record.get("phase") == "will-receipt":
            receipt=record.get("receipt_record")
            committed_view=dict(record)
            committed_view["phase"]="committed"
            for name in ("committed_journal_digest","receipt_record","receipt_digest"):
                committed_view.pop(name,None)
            if (not isinstance(receipt,dict) or receipt.get("phase") != "did-receipt" or
                    receipt.get("txn_type") != "snapshot-publish-receipt" or
                    receipt.get("instance_key") != record.get("instance_key") or
                    receipt.get("generation") != record.get("generation") or
                    json_digest(receipt) != record.get("receipt_digest") or
                    json_digest(committed_view) != record.get("committed_journal_digest") or
                    receipt.get("committed_journal_digest") != record.get("committed_journal_digest")):
                raise StateError("publication-invalid","publication compact receipt WAL is invalid")
        else:
            raise StateError("publication-invalid","publication journal is not committed for retirement")
        _publication_write_journal(container,key,receipt)
        record=receipt
    if (record.get("txn_type") != "snapshot-publish-receipt" or
            record.get("phase") != "did-receipt" or
            not isinstance(record.get("generation"),int)):
        raise StateError("publication-invalid","publication compact receipt is invalid")
    observed = _publication_read_journal(container, record["instance_key"])
    if observed != record:
        raise StateError("publication-invalid","publication fixed receipt conflicts")
    return record


def _publication_validate_claim_plan(journal: dict, key: str) -> None:
    """Validate the fixed plan before dropping the instance lock."""
    try:
        generation=journal["generation"]
        created_epoch=journal["created_epoch"]
        parent_txn_id=journal["publication_claim_parent_txn_id"]
        claim_key=journal["publication_claim_key_sha256"]
        max_data_bytes=journal["publication_claim_max_data_bytes"]
        owner_facts=journal["publication_claim_owner_facts"]
        targets=journal["publish_targets"]
        projected=[{name:item[name] for name in
                    ("basename","type","size","sha256","dev","ino","nlink",
                     "mtime_ns","mount_id")} for item in targets]
        projected_bytes=sum(item["size"] for item in projected)
        expected_key,_=_catalog_claim_key(
            "snapshot-publication",key,parent_txn_id)
        expected_owner={**owner_facts,"schema_version":1,"state":"will-create",
            "created_epoch":created_epoch,"hostname":socket.gethostname(),
            "logical_key_sha256":claim_key,"instance_key":key,
            "purpose":"snapshot-publication","parent_txn_id":parent_txn_id}
    except (KeyError,TypeError,ValueError):
        raise StateError("publication-invalid",
                         "publication claim plan schema is invalid")
    if (journal.get("schema_version") != 1 or
            journal.get("txn_type") != "snapshot-publish" or
            journal.get("instance_key") != key or
            not isinstance(generation,int) or not 1 <= generation <= 2147483647 or
            parent_txn_id != f"publication-{generation}" or
            expected_key != claim_key or
            not isinstance(created_epoch,int) or
            not 0 <= created_epoch <= 2147483647 or
            not isinstance(max_data_bytes,int) or max_data_bytes < 0 or
            max_data_bytes > 2147483647 - CLAIM_PACK_SIZE or
            max_data_bytes != projected_bytes or
            not isinstance(owner_facts,dict) or
            owner_facts.get("targets") != projected or
            journal.get("publication_claim_owner_digest") !=
                json_digest(expected_owner)):
        raise StateError("publication-invalid",
                         "publication claim plan binding is invalid")


def publish_snapshot(agents: Path, key: str, purpose: str, records: Path,
                     header: dict, recovery_temps: list[Path] | None = None,
                     binding_authority=None) -> dict:
    container = _publication_container(agents)
    journal = None
    with InstanceFlock(container, key):
        if _publication_disabled(container, key):
            raise StateError("snapshot-unavailable", "snapshot publication is disabled")
        existing = _publication_read_journal(container, key)
        if (existing and existing.get("txn_type") == "snapshot-publish" and
                existing.get("phase") != "will-receipt"):
            if (existing.get("phase") == "committed" and
                    existing.get("source_cleanup_state") == "released-clean"):
                retire_publication_journal(agents, existing)
            else:
                journal = existing
        elif existing:
            retire_publication_journal(agents,existing)
        if journal is None:
            prior, prior_digest = read_live_inventory(agents, key)
            generation = 1 if prior is None else prior["generation"] + 1
            if generation > 2147483647:
                raise StateError("publication-invalid", "generation exhausted")
            records_target = f"{key}.snapshot.{generation}.records"
            header_target = f"{key}.snapshot.{generation}.header"
            source_owner_basename = records.parent.name
            source_claim_digest = getattr(records, "claim_key_digest", None)
            if (getattr(records,"claim_container",None) != container or
                    not HEX64.fullmatch(str(source_claim_digest))):
                raise StateError("publication-invalid", "source snapshot claim is absent")
            source_owner = _instance_pack_read(container,source_claim_digest,"claim","OWNER")
            if (not isinstance(source_owner,dict) or source_owner.get("state") != "did-create" or
                    source_owner.get("temp_basename") != source_owner_basename or
                    source_owner.get("instance_key") != key):
                raise StateError("publication-invalid", "source snapshot claim is invalid")
            source_parent_st=os.fstat(records.parent_fd)
            source_parent_identity={"dev":source_parent_st.st_dev,"ino":source_parent_st.st_ino,
                "nlink":source_parent_st.st_nlink,"mode":source_parent_st.st_mode,
                "mount_id":runtime_native._mount_id_at(records.parent_fd,b".",records.parent_fd)}
            header_source = records.parent / f".{header_target}.source.{nonce_hex()}"
            atomic_json(header_source, header, 16384, True)
            rec_item=artifact_record(records,purpose+"-records",generation);rec_item["basename"]=records_target
            head_item=artifact_record(header_source,purpose+"-header",generation);head_item["basename"]=header_target
            rec_target=dict(rec_item,source_basename=records.name,source_parent_basename=source_owner_basename)
            head_target=dict(head_item,source_basename=header_source.name,source_parent_basename=source_owner_basename)
            active=[] if prior is None else [item for item in prior["active"] if not item["purpose"].startswith(purpose+"-")]
            retired=[] if prior is None else [item for item in prior["active"] if item["purpose"].startswith(purpose+"-")]
            active.extend([rec_item,head_item]); created_epoch=int(time.time())
            inventory={"schema_version":1,"instance_key":key,"generation":generation,
                       "active":active,"committed_epoch":created_epoch,"staged":True}
            parent_txn_id=f"publication-{generation}"
            publication_claim_digest,_=_catalog_claim_key("snapshot-publication",key,parent_txn_id)
            boot,birth=process_birth()
            max_data_bytes=sum(item["size"] for item in (rec_item,head_item))
            if (max_data_bytes < 0 or
                    max_data_bytes > 2147483647 - CLAIM_PACK_SIZE):
                raise StateError(
                    "snapshot-unavailable",
                    "publication claim data bound exceeds the fixed reservation limit")
            claim_owner_facts={"nonce":hashlib.sha256(parent_txn_id.encode()).hexdigest()[:32],
                "creator_pid":os.getpid(),"creator_boot_id":boot,"creator_birth_token":birth,
                "writer_pid":os.getpid(),"writer_birth_token":birth,
                "task_id":agents.parent.parent.name,
                "task_identity_digest":source_owner["task_identity_digest"],
                "root_identity_digest":source_owner["root_identity_digest"],
                "runtime_identity_digest":source_owner["runtime_identity_digest"],
                "runtime_mount_id":source_owner["runtime_mount_id"],
                "native_binding_digest":source_owner["native_binding_digest"],
                "instance_key_digest":hashlib.sha256(key.encode()).hexdigest(),
                "publication_generation":generation,
                "targets":[{name:item[name] for name in ("basename","type","size","sha256","dev","ino","nlink","mtime_ns","mount_id")}
                           for item in (rec_item,head_item)]}
            expected_claim_owner={**claim_owner_facts,"schema_version":1,"state":"will-create",
                "created_epoch":created_epoch,"hostname":socket.gethostname(),
                "logical_key_sha256":publication_claim_digest,"instance_key":key,
                "purpose":"snapshot-publication","parent_txn_id":parent_txn_id}
            journal={"schema_version":1,"txn_type":"snapshot-publish","instance_key":key,
                "phase":"prepared","generation":generation,"created_epoch":created_epoch,
                "prior_inventory_digest":prior_digest,"staged_inventory":inventory,
                "publish_targets":[rec_target,head_target],
                "native_binding_digest":header.get("observation",{}).get("native_binding_digest"),
                "source_owner_basename":source_owner_basename,"source_owner_digest":json_digest(source_owner),
                "source_claim_key_sha256":source_claim_digest,"source_parent_identity":source_parent_identity,
                "publication_claim_key_sha256":publication_claim_digest,
                "publication_claim_parent_txn_id":parent_txn_id,
                "publication_claim_max_data_bytes":max_data_bytes,
                "publication_claim_owner_facts":claim_owner_facts,
                "publication_claim_owner_digest":json_digest(expected_claim_owner),
                "retired":retired,"recovery_temps":[
                    {"basename":path.name,"parent_basename":path.parent.name,
                     "claim_key_sha256":getattr(path,"claim_key_digest",None),
                     **{name:value for name,value in artifact_record(path,"recovery-temp",0).items()
                        if name in ("size","sha256","dev","ino","nlink","mtime_ns","mount_id")},
                     **(lambda value:{"parent_dev":value.st_dev,"parent_ino":value.st_ino,
                        "parent_nlink":value.st_nlink,"parent_mount_id":runtime_native._mount_id_at(path.parent_fd,b".",path.parent_fd)})(os.fstat(path.parent_fd))}
                    for path in (recovery_temps or []) if path.exists()]}
            journal=_publication_write_journal(container,key,journal,"prepared")
        _publication_validate_claim_plan(journal,key)

    # Catalog reservation is deliberately outside the instance lock.
    claim_result=_catalog_claim_create(container,"snapshot-publication",key,
        journal["publication_claim_parent_txn_id"],journal["publication_claim_max_data_bytes"],
        journal["created_epoch"],_gc_config(),journal["publication_claim_owner_facts"])
    if (claim_result["logical_key_sha256"] != journal["publication_claim_key_sha256"] or
            json_digest(claim_result["owner_record"]) != journal["publication_claim_owner_digest"]):
        raise StateError("publication-invalid","publication claim differs from fixed plan")
    with InstanceFlock(container,key):
        if _publication_disabled(container,key):
            raise StateError("snapshot-unavailable","snapshot publication was terminally disabled")
        current=_publication_read_journal(container,key)
        if current != journal:
            raise StateError("publication-invalid","publication plan changed while reserving claim")
        live=publication_step(agents,journal,binding_authority)
        completed_journal = _publication_read_journal(container,key)
        if not isinstance(completed_journal,dict) or completed_journal.get("phase") != "committed":
            raise StateError("publication-invalid","publication did not reach committed state")
    target_identities=[{name:item[name] for name in
        ("basename","type","size","sha256","dev","ino","nlink","mtime_ns","mount_id")}
        for item in completed_journal["publish_targets"]]
    _catalog_claim_owner_did_create(container,claim_result["logical_key_sha256"],
                                    claim_result["owner_record"],target_identities)
    with InstanceFlock(container,key):
        current=_publication_read_journal(container,key)
        if current != completed_journal:
            raise StateError("publication-invalid",
                             "publication journal changed before OWNER handoff")
        completed_journal=dict(completed_journal,
                               publication_owner_state="did-create")
        completed_journal=_publication_write_journal(
            container,key,completed_journal,"committed")
    cleanup_publication_temps(agents, completed_journal)
    with InstanceFlock(container,key):
        current=_publication_read_journal(container,key)
        if current != completed_journal:
            raise StateError("publication-invalid",
                             "publication journal changed before source cleanup handoff")
        completed_journal=dict(completed_journal,
                               source_cleanup_state="released-clean")
        _publication_write_journal(container,key,completed_journal,"committed")
    return live


def cleanup_publication_temps(agents: Path, journal: dict) -> None:
    agents_fd=os.open(os.fsencode(agents),os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|
                      getattr(os,"O_NOFOLLOW",0)|getattr(os,"O_CLOEXEC",0))
    try:
      _cleanup_publication_temps_at(agents,agents_fd,journal)
    finally: os.close(agents_fd)


def _cleanup_publication_temps_at(agents: Path, agents_fd: int, journal: dict) -> None:
    container = _publication_container(agents)
    for item in journal.get("recovery_temps", []):
        required={"basename","parent_basename","size","sha256","dev","ino","nlink","mtime_ns","mount_id",
                  "parent_dev","parent_ino","parent_nlink","parent_mount_id","claim_key_sha256"}
        if set(item) != required or not HEX64.fullmatch(str(item.get("claim_key_sha256",""))):
            raise StateError("publication-invalid", "publication temp ownership is invalid")
        parent_name=os.fsencode(item["parent_basename"]); name=os.fsencode(item["basename"])
        temp_claim=_instance_pack_read(
            container,item["claim_key_sha256"],"claim","OWNER")
        if (not isinstance(temp_claim,dict) or
                temp_claim.get("logical_key_sha256") != item["claim_key_sha256"] or
                temp_claim.get("instance_key") != journal.get("instance_key") or
                temp_claim.get("purpose") != "snapshot-temp" or
                temp_claim.get("state") not in ("did-create","released-clean")):
            raise StateError("publication-invalid",
                             "publication temp claim is invalid")
        if temp_claim.get("state") == "released-clean":
            try: os.stat(parent_name,dir_fd=agents_fd,follow_symlinks=False)
            except FileNotFoundError: continue
            raise StateError("publication-invalid",
                             "released publication temp parent reappeared")
        parent_fd=-1
        try:
            parent_fd=os.open(parent_name,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|
                              getattr(os,"O_NOFOLLOW",0)|getattr(os,"O_CLOEXEC",0),dir_fd=agents_fd)
            parent_st=os.fstat(parent_fd)
            if ((parent_st.st_dev,parent_st.st_ino,parent_st.st_nlink,
                 runtime_native._mount_id_at(agents_fd,parent_name,parent_fd)) !=
                    (item["parent_dev"],item["parent_ino"],item["parent_nlink"],item["parent_mount_id"])):
                raise StateError("publication-invalid", "owned publication temp parent changed")
            fd=os.open(name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0)|getattr(os,"O_CLOEXEC",0),dir_fd=parent_fd)
            try:
                st=os.fstat(fd); digest=sha_open_fd(fd)
                observed=(st.st_size,st.st_dev,st.st_ino,st.st_nlink,st.st_mtime_ns,digest,
                          runtime_native._mount_id_at(parent_fd,name,fd))
                expected=(item["size"],item["dev"],item["ino"],item["nlink"],item["mtime_ns"],
                          item["sha256"],item["mount_id"])
                if observed != expected:
                    raise StateError("publication-invalid", "owned publication temp changed")
            finally: os.close(fd)
            os.unlink(name,dir_fd=parent_fd); os.fsync(parent_fd)
            os.close(parent_fd); parent_fd=-1
            os.rmdir(parent_name,dir_fd=agents_fd)
            _catalog_claim_owner_release_clean(
                container,item["claim_key_sha256"],int(time.time()))
        except FileNotFoundError:
            if parent_fd >= 0:
                # A present bound parent with a missing expected child is not a
                # legal after-set until the parent itself is also absent.
                raise StateError("publication-invalid", "owned publication temp after-set is incomplete")
            _catalog_claim_owner_release_clean(
                container,item["claim_key_sha256"],int(time.time()))
        finally:
            if parent_fd >= 0: os.close(parent_fd)
    original_parent=journal.get("source_owner_basename")
    if original_parent:
        match=re.fullmatch(r"\.snapshot-tmp\.([0-9a-f]{64})",original_parent)
        expected_parent=journal.get("source_parent_identity")
        source_claim=journal.get("source_claim_key_sha256")
        if (not match or not isinstance(expected_parent,dict) or
                not HEX64.fullmatch(str(source_claim))):
            raise StateError("publication-invalid","source snapshot cleanup WAL is invalid")
        parent_name=os.fsencode(original_parent)
        source_owner=_instance_pack_read(container,source_claim,"claim","OWNER")
        if not isinstance(source_owner,dict):
            raise StateError("publication-invalid","source snapshot claim changed")
        source_released=source_owner.get("state") == "released-clean"
        source_did=dict(source_owner)
        if source_released:
            target_identities=source_did.get("target_identities")
            if (not isinstance(source_did.get("released_epoch"),int) or
                    source_did["released_epoch"] < 0 or
                    source_did.get("released_target_set_digest") !=
                        _catalog_digest(
                            b"zyz-claim-released-target-set-v1",
                            _catalog_json(target_identities if isinstance(
                                target_identities,list) else [])).hex()):
                raise StateError("publication-invalid",
                                 "source snapshot release receipt is invalid")
            source_did.pop("released_epoch",None)
            source_did.pop("released_target_set_digest",None)
            source_did["state"]="did-create"
        if (source_did.get("state") != "did-create" or
                source_did.get("temp_basename") != original_parent or
                json_digest(source_did) != journal.get("source_owner_digest")):
            raise StateError("publication-invalid","source snapshot claim changed")
        if source_released:
            try: os.stat(parent_name,dir_fd=agents_fd,follow_symlinks=False)
            except FileNotFoundError:
                os.fsync(agents_fd)
                return
            raise StateError("publication-invalid",
                             "released source snapshot parent reappeared")
        source_fd=-1
        try:
            source_fd=os.open(parent_name,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|
                              getattr(os,"O_NOFOLLOW",0)|getattr(os,"O_CLOEXEC",0),dir_fd=agents_fd)
            st=os.fstat(source_fd)
            observed={"dev":st.st_dev,"ino":st.st_ino,"nlink":st.st_nlink,"mode":st.st_mode,
                      "mount_id":runtime_native._mount_id_at(agents_fd,parent_name,source_fd)}
            # Some filesystems update a directory's nlink as its entries are
            # renamed out.  Bind the stable descriptor identity and require a
            # still-linked empty directory; the frozen pre-publish nlink is
            # evidence, not an invariant after the two legitimate renames.
            if ({name:observed[name] for name in ("dev","ino","mode","mount_id")} !=
                    {name:expected_parent[name] for name in
                     ("dev","ino","mode","mount_id")} or
                    observed["nlink"] < 1 or
                    _directory_membership(source_fd)["count"] != 0):
                raise StateError("publication-invalid","source snapshot parent changed or is not empty")
            os.close(source_fd); source_fd=-1
            os.rmdir(parent_name,dir_fd=agents_fd)
        except FileNotFoundError:
            if source_fd >= 0:
                raise StateError("publication-invalid","source snapshot parent after-set is incomplete")
        finally:
            if source_fd >= 0: os.close(source_fd)
        try: os.stat(parent_name,dir_fd=agents_fd,follow_symlinks=False)
        except FileNotFoundError: pass
        else: raise StateError("publication-invalid","source snapshot parent remained after cleanup")
        _catalog_claim_owner_release_clean(container,source_claim,int(time.time()))
    os.fsync(agents_fd)


def create_baseline(task: str, agents: Path, key: str, absolute_deadline: float | None = None):
    first = second = None; authority = None; published = False
    try:
        policy = snapshot_policy()
        overall_deadline = absolute_deadline if absolute_deadline is not None else time.monotonic() + 15
        authority = runtime_native.open_owner_binding(snapshot_task_id(task))
        first, obs1 = native_snapshot_round(task, agents, key, policy, "baseline-a", overall_deadline, authority)
        second, obs2 = native_snapshot_round(task, agents, key, policy, "baseline-b", overall_deadline, authority)
        invariant_names = ("root_dev","root_ino","root_mount_id","git_binding","runtime_binding",
                           "cwd_chain_digest","native_binding_digest","raw_path_capability",
                           "mount_capability","rlimit_as_capability")
        if (not files_equal(first, second) or obs1["integrity_digest"] != obs2["integrity_digest"] or
                any(obs1.get(name) != obs2.get(name) for name in invariant_names)):
            raise StateError("snapshot-unavailable", "two descriptor snapshot rounds were not identical")
        now = int(time.time())
        summary = {"schema_version": 1, "instance_key": key, "baseline_epoch": now,
                   "manifest_digest": obs1["manifest_digest"], "observation": obs1,
                   "comparison_policy": policy,
                   "cross_invocation_invariants": {name: obs1[name] for name in
                       ("root_dev","root_ino","root_mount_id","git_binding","runtime_binding",
                       "raw_path_capability","mount_capability","rlimit_as_capability")}}
        if authority.revalidate()["native_binding_digest"] != obs1["native_binding_digest"]:
            raise StateError("snapshot-unavailable", "native binding changed before baseline publication")
        publish_snapshot(agents, key, "baseline", first, summary, [second], authority)
        published = True
    except Exception:
        # Baseline capture is observational and host-fail-open. Absence of a
        # fixed LIVE_INVENTORY baseline is the complete unavailable state; do
        # not create a second pathname authority or a synthetic empty baseline.
        published = False
    finally:
        if authority is not None: authority.close()
        for path in (first, second):
            if path is None: continue
            parent = path.parent
            try: path.unlink()
            except FileNotFoundError: pass
            try: parent.rmdir()
            except OSError: pass
            if hasattr(path,"close"): path.close()
    return published


def no_output_status(task: str, agents: Path, key: str, start: dict, env: dict):
    enabled = env_uint("ZYZ_WATCHDOG_NO_OUTPUT_SEC", 1800, 1, 604800, True)
    if enabled == 0:
        env.update(no_output_state="disabled", no_output_changed=None); return
    try:
        live, _ = read_live_inventory(agents, key)
        header, baseline_records, baseline_parsed, baseline_identity = published_snapshot_pair(
            agents, key, "baseline")
        if (not isinstance(live, dict) or not isinstance(header, dict) or
                header.get("instance_key") != key or
                not isinstance(header.get("baseline_epoch"), int) or
                not isinstance(header.get("observation"), dict) or
                not isinstance(header.get("comparison_policy"), dict) or
                not isinstance(header.get("cross_invocation_invariants"), dict)):
            raise StateError("snapshot-unavailable", "fixed baseline header is invalid")
    except (StateError, FileNotFoundError):
        env.update(no_output_state="unavailable", no_output_changed=None); return
    baseline_epoch = header["baseline_epoch"]
    baseline_digest = header["observation"].get("manifest_digest")
    start_epoch = start.get("start_epoch") if isinstance(start, dict) else None
    if (not isinstance(start_epoch, int) or start_epoch < 0 or
            not isinstance(baseline_digest, str) or
            not HEX64.fullmatch(baseline_digest)):
        env.update(no_output_state="unavailable", no_output_changed=None); return
    env["baseline_epoch"] = baseline_epoch
    env["baseline_digest"] = baseline_digest
    anchor = min(baseline_epoch, start_epoch)
    if int(time.time()) - anchor < enabled:
        env.update(no_output_state="within-threshold", no_output_changed=None); return
    first = second = None; authority = None
    try:
        policy = snapshot_policy(header.get("comparison_policy"))
        overall_deadline = time.monotonic() + 15
        authority = runtime_native.open_owner_binding(snapshot_task_id(task))
        first, obs1 = native_snapshot_round(task, agents, key, policy, "current-a", overall_deadline, authority)
        second, obs2 = native_snapshot_round(task, agents, key, policy, "current-b", overall_deadline, authority)
        invariant_names = ("root_dev","root_ino","root_mount_id","git_binding","runtime_binding",
                           "cwd_chain_digest","native_binding_digest","raw_path_capability",
                           "mount_capability","rlimit_as_capability")
        if (not files_equal(first, second) or obs1["integrity_digest"] != obs2["integrity_digest"] or
                any(obs1.get(name) != obs2.get(name) for name in invariant_names)):
            raise StateError("snapshot-unavailable", "two current descriptor rounds differ")
        invariants = {name:obs1[name] for name in
                      ("root_dev","root_ino","root_mount_id","git_binding","runtime_binding",
                       "raw_path_capability","mount_capability","rlimit_as_capability")}
        if invariants != header.get("cross_invocation_invariants"):
            raise StateError("snapshot-unavailable", "snapshot root/runtime capabilities changed")
        if authority.revalidate()["native_binding_digest"] != obs1["native_binding_digest"]:
            raise StateError("snapshot-unavailable", "native binding changed before no-output comparison")
        comparison = runtime_native.compare_snapshot_records(
            baseline_records, first, policy["ZYZ_NO_OUTPUT_MAX_PATHS"],
            policy["ZYZ_NO_OUTPUT_MAX_MANIFEST_BYTES"],
            baseline_identity, artifact_record(first, "current-records", 0))
        if (comparison["left_artifact_sha256"] != baseline_parsed["whole_sha256"] or
                comparison["right_artifact_sha256"] != first.expected_identity["sha256"] or
                obs1["manifest_digest"] != runtime_native.read_snapshot_records(
                    first, policy["ZYZ_NO_OUTPUT_MAX_PATHS"],
                    policy["ZYZ_NO_OUTPUT_MAX_MANIFEST_BYTES"],
                    expected_identity=first.expected_identity)["records_sha256"]):
            raise StateError("snapshot-unavailable", "current comparison artifacts changed")
        current = comparison["right_digest"]; env["current_digest"] = current
        changed = comparison["changed"]
        env.update(no_output_state="changed" if changed else "unchanged", no_output_changed=changed)
    except Exception:
        env.update(no_output_state="unavailable", no_output_changed=None)
    finally:
        if authority is not None: authority.close()
        for path in (first, second):
            if path is None: continue
            parent = path.parent
            try: path.unlink()
            except FileNotFoundError: pass
            try: parent.rmdir()
            except OSError: pass
            if hasattr(path,"close"): path.close()


def _catalog_observer_snapshot(container: Path) -> tuple[int | None, list[str]]:
    """Return fixed main heartbeat and catalog-owned dynamic instance keys."""
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_fd = proof.pop("global_fd")
        recovery_fd = os.open(
            os.fsencode(container / ".catalog-recovery-pack.v1"),
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            header = _catalog_select_ab(
                global_fd, CATALOG_LAYOUT["pack_header"][0], 4096,
                b"ZYZPACK1")
            main_epoch = header[3][2].get("main_heartbeat_epoch")
            if main_epoch is not None and (
                    not isinstance(main_epoch, int) or
                    not 0 <= main_epoch <= 2147483647):
                raise StateError("catalog-root-invalid",
                                 "main heartbeat record is invalid", 4)
            selector = proof["root"][2][4096:5120]
            keys = set()
            for index in range(CATALOG_CELL_COUNT):
                _, _, entry = _catalog_selected_entry(
                    global_fd, selector, index)
                if entry["state"] == 0:
                    continue
                _, _, recovery = _catalog_selected_recovery(
                    recovery_fd, entry, index)
                key = recovery["payload"].get("_creator_key")
                if isinstance(key, str) and KEY_RE.fullmatch(key):
                    keys.add(key)
            return main_epoch, sorted(keys)
        finally:
            os.close(recovery_fd)
            os.close(global_fd)


def _fixed_instance_observation(task: str, container: Path, key: str,
                                include_no_output: bool) -> dict:
    now = int(time.time())
    result = {"instance_key": key, "role": None, "tracking_capability": "unknown",
              "terminal": False, "terminal_kind": None, "terminal_epoch": None,
              "start_epoch": None,
              "heartbeat_epoch": None, "last_liveness_epoch": None,
              "probe_state": None, "probe_id": None, "probe_deadline_epoch": None,
              "inflight_count": None, "no_output_state": "not-applicable",
              "no_output_changed": None}
    terminal_cell = _terminal_lookup(container, key)
    if terminal_cell is not None and terminal_cell.get("state") == "handoff-accepted":
        marker = terminal_cell.get("terminal_record", {})
        result.update(role=marker.get("canonical_role"), tracking_capability="armed",
                      terminal=True, terminal_kind=marker.get("terminal_kind"),
                      terminal_epoch=marker.get("terminal_epoch"))
        return result
    start = None
    try:
        with InstanceFlock(container, key):
            audit_fd = _instance_open_pack(container, key, "audit", False)
            work_fd = _instance_open_pack(container, key, "work", False)
            try:
                identity = _instance_pack_read_fd(
                    audit_fd, "audit", key, "IDENTITY")
                start = _instance_pack_read_fd(
                    audit_fd, "audit", key, "START")
                heartbeat = _instance_local_read_fd(
                    audit_fd, "audit", "HEARTBEAT")
                ambiguous = _instance_pack_read_fd(
                    audit_fd, "audit", key, "AMBIGUOUS")
                done = _instance_pack_read_fd(audit_fd, "audit", key, "DONE")
                finalized = _instance_pack_read_fd(
                    audit_fd, "audit", key, "FINALIZED")
                probe = _instance_pack_read_fd(
                    audit_fd, "audit", key, "PROBE_STATE")
                inflight = _instance_pack_read_fd(
                    work_fd, "work", key, "INFLIGHT")
                diagnostics = _instance_pack_read_fd(
                    audit_fd, "audit", key, "DIAGNOSTICS")
            finally:
                os.close(work_fd); os.close(audit_fd)
    except FileNotFoundError:
        terminal_cell = _terminal_lookup(container, key)
        if terminal_cell is not None and terminal_cell.get("state") == "handoff-accepted":
            marker = terminal_cell.get("terminal_record", {})
            result.update(role=marker.get("canonical_role"),
                          tracking_capability="armed", terminal=True,
                          terminal_kind=marker.get("terminal_kind"),
                          terminal_epoch=marker.get("terminal_epoch"))
        else:
            result["tracking_capability"] = "missing"
        return result
    except StateError:
        result["tracking_capability"] = "invalid"
        return result
    if (not isinstance(identity, dict) or identity.get("instance_key") != key or
            not isinstance(start, dict) or start.get("instance_key") != key):
        result["tracking_capability"] = "invalid"
        return result
    role = identity.get("canonical_role")
    start_epoch = start.get("start_epoch")
    heartbeat_epoch = (heartbeat.get("heartbeat_epoch")
                       if isinstance(heartbeat, dict) else None)
    if (role not in ("implementation-agent", "test-agent", "review-agent") or
            not isinstance(start_epoch, int) or start_epoch < 0 or
            (heartbeat_epoch is not None and
             (not isinstance(heartbeat_epoch, int) or heartbeat_epoch < 0))):
        result["tracking_capability"] = "invalid"
        return result
    result.update(role=role, start_epoch=start_epoch,
                  heartbeat_epoch=heartbeat_epoch,
                  last_liveness_epoch=max(start_epoch, heartbeat_epoch or 0))
    if ambiguous is not None:
        result["tracking_capability"] = "invalid"
        return result
    marker = done if done is not None else finalized
    if marker is not None:
        result.update(tracking_capability="armed", terminal=True,
                      terminal_kind=marker.get("terminal_kind"),
                      terminal_epoch=marker.get("terminal_epoch"))
        return result
    if diagnostics is not None:
        entries = diagnostics.get("entries") if isinstance(diagnostics, dict) else None
        if not isinstance(entries, list):
            result["tracking_capability"] = "invalid"
            return result
        unresolved = [item for item in entries if isinstance(item, dict) and
                      item.get("needs_reconcile") is True]
        if unresolved:
            result["tracking_capability"] = "needs-reconcile"
        else:
            result["tracking_capability"] = "armed"
    else:
        result["tracking_capability"] = "armed"
    if probe is not None:
        try:
            probe = validate_probe(probe, key)
            probe_state = probe.get("state")
            deadline = probe.get("deadline_epoch")
            if probe_state == "pending" and isinstance(deadline, int) and now >= deadline:
                probe_state = "overdue"
            result.update(probe_state=probe_state,
                          probe_id=probe.get("probe_id"),
                          probe_deadline_epoch=deadline)
        except StateError:
            result["tracking_capability"] = "invalid"
            result["probe_state"] = "invalid"
    if isinstance(inflight, dict) and isinstance(inflight.get("entries"), dict):
        result["inflight_count"] = len(inflight["entries"])
    elif inflight is None:
        result["inflight_count"] = 0
    if include_no_output and role in ("implementation-agent", "test-agent"):
        fields = {}
        no_output_status(task, agents_dir(task), key, start, fields)
        result["no_output_state"] = fields.get("no_output_state", "unavailable")
        result["no_output_changed"] = fields.get("no_output_changed")
        for name in ("baseline_epoch", "baseline_digest", "current_digest"):
            if name in fields:
                result[name] = fields[name]
    return result


def observe_task(task: str, include_no_output_arg: str) -> dict:
    if include_no_output_arg not in ("true", "false"):
        raise StateError("usage", "hook-observe requires true or false", 2)
    container, _ = ensure_catalog_genesis(task)
    main_epoch, keys = _catalog_observer_snapshot(container)
    instances = []
    for key in keys:
        instances.append(_fixed_instance_observation(
            task, container, key, include_no_output_arg == "true"))
    return {"ok": True, "state": "observed",
            "main_heartbeat_epoch": main_epoch,
            "instances": instances}


def validate_probe(data: dict, key: str) -> dict:
    if data.get("schema_version") != 2 or data.get("instance_key") != key:
        raise StateError("history-upgrade-required", "probe state is not trusted v2")
    history = data.get("history")
    if not isinstance(history, list) or len(history) > 16:
        raise StateError("invalid-schema", "invalid probe history")
    for item in history:
        if not isinstance(item, dict) or not HEX64.fullmatch(str(item.get("probe_id_sha256", ""))):
            raise StateError("history-upgrade-required", "probe history lacks id hash")
    pid = data.get("probe_id")
    if pid is not None and (not isinstance(pid, str) or not PROBE_RE.fullmatch(pid) or sha(pid.encode()) != data.get("probe_id_sha256")):
        raise StateError("invalid-schema", "invalid current probe id")
    return data


def rotate_probe(data: dict, kind: str, epoch: int, reason_hash: str) -> list:
    history = list(data.get("history", []))
    if data.get("probe_id"):
        history.append({"prior_record_sha256": sha(json.dumps(data, sort_keys=True, separators=(",", ":")).encode()),
                        "probe_id_sha256": data["probe_id_sha256"], "terminal_kind": kind,
                        "epoch": epoch, "reason_sha256": reason_hash})
    return history[-16:]


def select_probe_candidate(tokens: list[str], retained_hashes: set[str],
                           retained_sources: dict[str, str] | None = None) -> tuple[str | None, int, list[dict]]:
    """Select a non-colliding probe id after at most eight CSPRNG candidates."""
    trace = []
    sources = retained_sources or {}
    for attempt in range(8):
        token = tokens[attempt] if attempt < len(tokens) and re.fullmatch(r"[0-9a-f]{32}", tokens[attempt]) else secrets.token_hex(16)
        candidate = "probe1-" + token
        candidate_hash = sha(candidate.encode())
        matches = sorted(sources.get(retained, "retained") for retained in retained_hashes
                         if hmac.compare_digest(candidate_hash, retained))
        collided = bool(matches)
        trace.append({"attempt": attempt + 1, "candidate_probe_id_sha256": candidate_hash,
                      "collided": collided, "collision_sources": matches,
                      "selected": not collided})
        if not collided:
            return candidate, attempt + 1, trace
    return None, 8, trace


def status_result(task: str, raw_id: str, env: dict) -> dict:
    key, _, digest = instance(raw_id)
    env["instance_key"] = key
    container, _ = ensure_catalog_genesis(task)
    terminal_cell = _terminal_lookup(container, key)
    if terminal_cell is not None and terminal_cell["state"] == "handoff-accepted":
        marker = terminal_cell["terminal_record"]
        release = terminal_cell["instance_release"]
        late = terminal_cell.get("late_clean")
        late_committed = (isinstance(late, dict) and
                          late.get("phase") == "committed")
        env.update(state="terminal", trusted=True, tracking_capability="armed",
                   terminal_kind=marker.get("terminal_kind"),
                   terminal_epoch=marker.get("terminal_epoch"),
                   cleanup_state=marker.get("cleanup_state", "compacted"),
                   cleanup_pending=marker.get("cleanup_state") == "pending",
                   cleanup_error=marker.get("cleanup_error"),
                   cleanup_intent_digest=marker.get("cleanup_intent_digest"),
                   cleanup_receipt_digest=marker.get("cleanup_receipt_digest"),
                   handoff_state="accepted",
                   instance_release_state=release["phase"],
                   late_clean=late_committed,
                   preserved_terminal_kind=(marker.get("terminal_kind")
                                              if late_committed else None))
        return env
    try:
        with InstanceFlock(container, key):
            audit_fd = _instance_open_pack(container, key, "audit", False)
            work_fd = _instance_open_pack(container, key, "work", False)
            try:
                identity = _instance_pack_read_fd(
                    audit_fd, "audit", key, "IDENTITY")
                start = _instance_pack_read_fd(audit_fd, "audit", key, "START")
                ambiguous = _instance_pack_read_fd(
                    audit_fd, "audit", key, "AMBIGUOUS")
                done = _instance_pack_read_fd(audit_fd, "audit", key, "DONE")
                finalized = _instance_pack_read_fd(
                    audit_fd, "audit", key, "FINALIZED")
                probe = _instance_pack_read_fd(
                    audit_fd, "audit", key, "PROBE_STATE")
                latch = _instance_pack_read_fd(
                    work_fd, "work", key, "TERMINAL_HANDOFF")
            finally:
                os.close(work_fd)
                os.close(audit_fd)
    except FileNotFoundError:
        # P may have become visible between terminal miss and carrier open.
        terminal_cell = _terminal_lookup(container, key)
        if terminal_cell is not None and terminal_cell["state"] == "handoff-accepted":
            return status_result(task, raw_id, env)
        env.update(state="missing", trusted=False, tracking_capability="missing")
        return env
    if (not isinstance(identity, dict) or
            identity.get("agent_id_sha256") != digest or
            identity.get("instance_key") != key):
        env.update(state="invalid", trusted=False, tracking_capability="invalid")
        return env
    if ambiguous is not None:
        env.update(state="ambiguous", trusted=False, tracking_capability="invalid")
        return env
    marker = done if done is not None else finalized
    if marker is not None:
        env.update(state="terminal", trusted=True, tracking_capability="armed",
                   terminal_kind=marker.get("terminal_kind"),
                   terminal_epoch=marker.get("terminal_epoch"),
                   cleanup_state=marker.get("cleanup_state", "pending"),
                   cleanup_pending=marker.get("cleanup_state") == "pending",
                   cleanup_error=marker.get("cleanup_error"),
                   cleanup_intent_digest=marker.get("cleanup_intent_digest"),
                   cleanup_receipt_digest=marker.get("cleanup_receipt_digest"),
                   handoff_state=("freeze-latched" if latch is not None else
                                  "reservation-pending" if terminal_cell is not None else
                                  "not-started"),
                   instance_release_state="not-started")
        return env
    if start is None:
        env.update(state="missing", trusted=False, tracking_capability="missing")
        return env
    if probe is None:
        env.update(state="disabled", trusted=True, tracking_capability="armed",
                   creation_enabled=env_uint("ZYZ_RECONNECT_ACK_SEC", 600, 1, 86400, True) != 0)
        no_output_status(task, agents_dir(task), key, start, env)
        return env
    try: probe = validate_probe(probe, key)
    except StateError:
        env.update(state="invalid", trusted=False, tracking_capability="invalid")
        return env
    state = probe["state"]
    if state == "pending" and int(time.time()) >= probe["deadline_epoch"]:
        state = "overdue"
    env.update(state=state, trusted=True, tracking_capability="armed",
               probe_id=probe.get("probe_id"), probe_id_sha256=probe.get("probe_id_sha256"),
               deadline_epoch=probe.get("deadline_epoch"), creation_enabled=env_uint("ZYZ_RECONNECT_ACK_SEC", 600, 1, 86400, True) != 0)
    no_output_status(task, agents_dir(task), key, start, env)
    return env


def _instance_commit_start(container: Path, key: str, display: str, digest: str,
                           role: str, event: dict) -> None:
    """Resume or commit the fixed-pack START transaction idempotently."""
    with InstanceFlock(container, key):
        audit_fd = _instance_open_pack(container, key, "audit", True)
        work_fd = _instance_open_pack(container, key, "work", True)
        try:
            journal = _instance_pack_read_fd(
                work_fd, "work", key, "TRANSITION_JOURNAL")
            if journal is None:
                created_epoch = int(time.time())
                journal = {"schema_version": 1, "txn_type": "start", "phase": "prepared",
                           "instance_key": key, "canonical_role": role,
                           "agent_id_sha256": digest, "event_token": event["event_token"],
                           "nonce_sha256": event["nonce_sha256"],
                           "event_record_digest": event["event_record_digest"],
                           "created_epoch": created_epoch}
                _instance_pack_write_fd(
                    work_fd, "work", key, "TRANSITION_JOURNAL", journal)
            if (journal.get("schema_version") != 1 or journal.get("txn_type") != "start" or
                    journal.get("instance_key") != key or
                    journal.get("canonical_role") != role or
                    journal.get("agent_id_sha256") != digest or
                    any(journal.get(field) != event[field] for field in
                        ("event_token", "nonce_sha256", "event_record_digest"))):
                raise StateError("identity-conflict",
                                 "instance START transaction identity conflicts", 4)
            if journal.get("phase") not in ("prepared", "committed"):
                raise StateError("invalid-schema", "instance START phase is invalid", 4)
            validate_event_identity_fields("journal", journal)
            created_epoch = journal.get("created_epoch")
            if not isinstance(created_epoch, int) or created_epoch < 0:
                raise StateError("invalid-schema", "instance START epoch is invalid", 4)

            identity_record = {"schema_version": 1, "instance_key": key,
                               "agent_id_sha256": digest, "display_prefix": display,
                               "canonical_role": role}
            observed_identity = _instance_pack_read_fd(
                audit_fd, "audit", key, "IDENTITY")
            if observed_identity is None:
                _instance_pack_write_fd(
                    audit_fd, "audit", key, "IDENTITY", identity_record)
            elif observed_identity != identity_record:
                raise StateError("identity-conflict", "instance IDENTITY record conflicts", 4)
            audit_header = _instance_pack_header(audit_fd, "audit", key)[3][2]
            identity_ref = audit_header["selected"].get("IDENTITY")
            if identity_ref is None:
                raise StateError("invalid-schema", "instance IDENTITY selector is missing", 4)

            start_record = {"schema_version": 1, "instance_key": key,
                            "agent_id_sha256": digest, "canonical_role": role,
                            "start_epoch": created_epoch,
                            "start_iso": time.strftime(
                                "%Y-%m-%dT%H:%M:%SZ", time.gmtime(created_epoch)),
                            "event_token": journal["event_token"],
                            "nonce_sha256": journal["nonce_sha256"],
                            "event_record_digest": journal["event_record_digest"],
                            "identity_generation": identity_ref["generation"],
                            "identity_digest": identity_ref["digest"]}
            observed_start = _instance_pack_read_fd(audit_fd, "audit", key, "START")
            if observed_start is None:
                _instance_pack_write_fd(audit_fd, "audit", key, "START", start_record)
            elif observed_start != start_record:
                raise StateError("identity-conflict", "instance START record conflicts", 4)
            audit_header = _instance_pack_header(audit_fd, "audit", key)[3][2]
            start_ref = audit_header["selected"].get("START")
            if start_ref is None:
                raise StateError("invalid-schema", "instance START selector is missing", 4)

            if journal["phase"] == "committed":
                if (journal.get("identity_digest") != identity_ref["digest"] or
                        journal.get("start_generation") != start_ref["generation"] or
                        journal.get("start_digest") != start_ref["digest"]):
                    raise StateError("invalid-schema",
                                     "committed instance START references changed", 4)
                return
            journal.update(phase="committed", identity_digest=identity_ref["digest"],
                           start_generation=start_ref["generation"],
                           start_digest=start_ref["digest"],
                           committed_epoch=int(time.time()))
            _instance_pack_write_fd(
                work_fd, "work", key, "TRANSITION_JOURNAL", journal)
        finally:
            os.close(audit_fd); os.close(work_fd)


def _instance_latch_ambiguous(container: Path, key: str, digest: str, role: str,
                              reservation: dict, event: dict) -> None:
    """Persist the first fresh-event collision without advancing START."""
    with InstanceFlock(container, key):
        audit_fd = _instance_open_pack(container, key, "audit", True)
        try:
            observed = _instance_pack_read_fd(audit_fd, "audit", key, "AMBIGUOUS")
            if observed is not None:
                if (observed.get("schema_version") != 1 or
                        observed.get("instance_key") != key or
                        observed.get("agent_id_sha256") != digest):
                    raise StateError("invalid-schema", "AMBIGUOUS record is invalid", 4)
                return
            record = {"schema_version": 1, "instance_key": key,
                      "agent_id_sha256": digest, "canonical_role": role,
                      "existing_reservation_digest": reservation["reservation_digest"],
                      "detected_epoch": int(time.time()), **event}
            _instance_pack_write_fd(audit_fd, "audit", key, "AMBIGUOUS", record)
        finally:
            os.close(audit_fd)


def _catalog_public_claim_batch_test_count() -> int | None:
    """Validate the exact private batch contract before any public mutation."""
    raw_batch = os.environ.get("ZYZ_TEST_PUBLIC_CLAIM_BATCH_COUNT")
    if raw_batch is None:
        return None
    if (not re.fullmatch(r"[1-9][0-9]{0,2}", raw_batch) or
            not 1 <= int(raw_batch) <= 128 or
            os.environ.get("ZYZ_TEST_TRANSITION_STOP_AFTER") !=
                    "catalog-claim-pack:public-batch-committed"):
        raise StateError(
            "invalid-request", "public claim batch fixture contract is invalid", 2)
    return int(raw_batch)


def _catalog_public_claim_batch_test_route(task: str, role: str, key: str,
                                           display: str, digest: str,
                                           count: int) -> None:
    """Produce authentic claims only after the public START is committed."""

    # Authenticate the catalog carrier and fixed START authority before the
    # first batch claim. The normal public path committed them in this call.
    task_path = Path(task).absolute()
    runtime = _catalog_runtime(task)
    container = _catalog_container(runtime, False)
    block = max(4096, os.statvfs(os.fsencode(container)).f_frsize)
    request = INSTANCE_AUDIT_SIZE + INSTANCE_WORK_SIZE + block
    object_set = _catalog_instance_object_set(key, request)
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_fd = proof.pop("global_fd")
        recovery_fd = os.open(
            os.fsencode(container / ".catalog-recovery-pack.v1"),
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            index, _ = _catalog_find_instance_cell(global_fd, proof, key)
            if index is None:
                raise StateError("missing-start", "fixed instance CELL is absent", 3)
            selector = proof["root"][2][4096:5120]
            _, _, entry = _catalog_selected_entry(global_fd, selector, index)
            _, _, recovery = _catalog_selected_recovery(
                recovery_fd, entry, index)
            payload = recovery["payload"]
            identities_digest = payload.get("object_identities_digest")
            if (entry["state"] != 2 or recovery["state"] != 3 or
                    payload.get("state") != "ACTIVE_ACK" or
                    entry["fields"][0] != _catalog_instance_subject(key) or
                    payload.get("subject_digest") != entry["fields"][0].hex() or
                    payload.get("_creator_key") != key or
                    payload.get("_request_bytes") != request or
                    not isinstance(identities_digest, str) or
                    not HEX64.fullmatch(identities_digest)):
                raise StateError(
                    "identity-conflict", "fixed instance CELL authority conflicts", 4)
        finally:
            os.close(recovery_fd)
            os.close(global_fd)
    _instance_validate_reserved_objects(
        container, {"object_set": object_set}, identities_digest)

    expected_identity = {
        "schema_version": 1, "instance_key": key,
        "agent_id_sha256": digest, "display_prefix": display,
        "canonical_role": role,
    }
    with InstanceFlock(container, key):
        audit_fd = _instance_open_pack(container, key, "audit", False)
        work_fd = _instance_open_pack(container, key, "work", False)
        try:
            identity = _instance_pack_read_fd(
                audit_fd, "audit", key, "IDENTITY")
            start = _instance_pack_read_fd(audit_fd, "audit", key, "START")
            journal = _instance_pack_read_fd(
                work_fd, "work", key, "TRANSITION_JOURNAL")
            ambiguous = _instance_pack_read_fd(
                audit_fd, "audit", key, "AMBIGUOUS")
            done = _instance_pack_read_fd(audit_fd, "audit", key, "DONE")
            finalized = _instance_pack_read_fd(
                audit_fd, "audit", key, "FINALIZED")
            selected = _instance_pack_header(
                audit_fd, "audit", key)[3][2]["selected"]
            identity_ref = selected.get("IDENTITY")
            start_ref = selected.get("START")
            if (identity != expected_identity or
                    not isinstance(start, dict) or
                    start.get("schema_version") != 1 or
                    start.get("instance_key") != key or
                    start.get("agent_id_sha256") != digest or
                    start.get("canonical_role") != role or
                    not isinstance(journal, dict) or
                    journal.get("schema_version") != 1 or
                    journal.get("txn_type") != "start" or
                    journal.get("phase") != "committed" or
                    journal.get("instance_key") != key or
                    journal.get("agent_id_sha256") != digest or
                    journal.get("canonical_role") != role or
                    not isinstance(identity_ref, dict) or
                    not isinstance(start_ref, dict) or
                    start.get("identity_generation") !=
                        identity_ref.get("generation") or
                    start.get("identity_digest") != identity_ref.get("digest") or
                    journal.get("identity_digest") != identity_ref.get("digest") or
                    journal.get("start_generation") != start_ref.get("generation") or
                    journal.get("start_digest") != start_ref.get("digest") or
                    any(start.get(field) != journal.get(field) for field in
                        ("event_token", "nonce_sha256", "event_record_digest")) or
                    any(value is not None for value in
                        (ambiguous, done, finalized))):
                raise StateError(
                    "identity-conflict", "committed fixed START authority conflicts", 4)
            validate_event_identity_fields("committed", start)
            validate_event_identity_fields("journal", journal)
        finally:
            os.close(work_fd)
            os.close(audit_fd)

    seed = nonce_hex(1)
    boot, birth = process_birth()
    config = _gc_config()
    mount_id = _catalog_mount_identity(container)
    for index in range(count):
        parent = hashlib.sha256(
            b"zyz-public-claim-batch-v1" + bytes.fromhex(seed) +
            struct.pack(">I", index)).hexdigest()
        owner_facts = {
            "nonce": parent, "creator_pid": os.getpid(),
            "creator_boot_id": boot, "creator_birth_token": birth,
            "writer_pid": os.getpid(), "writer_birth_token": birth,
            "task_id": snapshot_task_id(task),
            "task_identity_digest": hashlib.sha256(
                os.fsencode(task_path)).hexdigest(),
            "root_identity_digest": hashlib.sha256(
                os.fsencode(task_path.parents[2])).hexdigest(),
            "runtime_identity_digest": hashlib.sha256(
                os.fsencode(task_path / "runtime")).hexdigest(),
            "runtime_mount_id": mount_id,
            "native_binding_digest": hashlib.sha256(
                b"zyz-public-claim-batch-binding-v1" +
                os.fsencode(task_path)).hexdigest(),
            "instance_key_digest": hashlib.sha256(key.encode()).hexdigest(),
            "targets": [],
        }
        _catalog_claim_create(
            container, "snapshot-publication", key, parent, 0,
            int(time.time()), config, owner_facts)
    _catalog_barrier("catalog-claim-pack", "public-batch-committed")
    raise StateError("gc-internal", "public claim batch barrier did not stop", 5)


def hook_start(task: str, raw_id: str, role_arg: str):
    """Create a tracked instance through catalog reservation and fixed packs.

    Host hooks are fail-open: a capacity/capability/identity failure is reported
    to stderr and leaves the role unarmed, but never prevents the host action.
    """
    hook_deadline = time.monotonic() + 15.0
    try:
        role = canonical_role(role_arg)
        key, display, digest = instance(raw_id)
        public_batch_count = _catalog_public_claim_batch_test_count()
        event = event_identity("start", role, digest, nonce_hex())
        container, _ = ensure_catalog_genesis(task)
        block = max(4096, os.statvfs(os.fsencode(container)).f_frsize)
        request = INSTANCE_AUDIT_SIZE + INSTANCE_WORK_SIZE + block
        config = _gc_config()
        reservation = _catalog_reserve_instance(container, key, request, config, event)
        if not reservation["event_matches"]:
            if reservation["resume_state"] in ("owner-active", "active-ack"):
                expected_identities = reservation.get("object_identities_digest")
                if not isinstance(expected_identities, str) or not HEX64.fullmatch(expected_identities):
                    raise StateError("catalog-root-invalid",
                                     "instance object identities digest is invalid", 4)
                _instance_validate_reserved_objects(
                    container, reservation, expected_identities)
                _instance_latch_ambiguous(
                    container, key, digest, role, reservation, event)
            raise StateError("identity-conflict", "fresh event reuses an instance id", 4)
        if reservation["resume_state"] == "reserved":
            identities = _instance_create_reserved_objects(container, key, reservation)
            reservation = _catalog_instance_cell_transition(
                container, key, reservation, "owner-active", identities, True)
        else:
            expected_identities = reservation.get("object_identities_digest")
            if not isinstance(expected_identities, str) or not HEX64.fullmatch(expected_identities):
                raise StateError("catalog-root-invalid",
                                 "instance object identities digest is invalid", 4)
            _instance_validate_reserved_objects(
                container, reservation, expected_identities)
        if reservation["resume_state"] == "owner-active":
            reservation = _catalog_instance_cell_transition(
                container, key, reservation, "cell-active-ack")
        # The catalog reservation precedes the instance lock because the lock
        # carrier itself is one of the reserved objects.  Once it exists, scan
        # the complete fixed inventory under that lock before any START WAL
        # mutation.  A fabricated primary failure exercises the supported
        # persisted diagnostic/reconcile route without creating a pathname.
        with InstanceFlock(container, key):
            audit_fd = _instance_open_pack(container, key, "audit", True)
            work_fd = _instance_open_pack(container, key, "work", False)
            try:
                retained = _fixed_event_inventory_fd(audit_fd, work_fd, key)
                if any(any(hmac.compare_digest(event[field], row[field])
                           for field in ("event_token", "nonce_sha256",
                                         "event_record_digest"))
                       for row in retained):
                    raise StateError("event-token-collision",
                                     "reserved start identity collides with retained event", 4)
                if os.environ.get("ZYZ_TEST_PRIMARY_FAIL_BEFORE_JOURNAL") == "start":
                    if os.environ.get("ZYZ_TEST_DIAGNOSTIC_WRITE_FAIL") == "1":
                        raise StateError("primary-diagnostic-write-failed",
                                         "injected diagnostic write failure", 4)
                    _fixed_append_diagnostic_fd(
                        audit_fd, key,
                        _fixed_diagnostic_record(
                            "start", key, digest, role, event,
                            int(time.time()), "primary-start-before-journal"))
                    print(f"zyz-worker: start-unarmed {event['event_token']}",
                          file=sys.stderr)
                    return
            finally:
                os.close(work_fd); os.close(audit_fd)
        _instance_commit_start(container, key, display, digest, role, event)
        if public_batch_count is not None:
            _catalog_public_claim_batch_test_route(
                task, role, key, display, digest, public_batch_count)
            return
        if role in ("implementation-agent", "test-agent"):
            snapshot_timeout = env_uint(
                "ZYZ_NO_OUTPUT_SNAPSHOT_TIMEOUT_SEC", 8, 1, 8)
            # Leave fixed mutation and cleanup reserve inside the one 15-second
            # hook budget. An insufficient remainder simply leaves the fixed
            # baseline capability unavailable for this instance.
            if time.monotonic() + snapshot_timeout + 3.0 < hook_deadline:
                create_baseline(
                    task, agents_dir(task), key,
                    min(hook_deadline - 2.0,
                        time.monotonic() + snapshot_timeout))
        # Lifecycle GC is an opportunity, not a nested operation and not a
        # reason to fail the already completed host start.
        if time.monotonic() + 2.0 < hook_deadline:
            gc_step_command(task, "lifecycle")
    except StateError as exc:
        code = "event-lock-unavailable" if exc.code in ("catalog-lock-timeout", "lock-timeout") else exc.code
        print(f"zyz-worker: {code}", file=sys.stderr)
        return
    except Exception as exc:
        print(f"zyz-worker: tracking-unavailable: {str(exc)[:256]}", file=sys.stderr)
        return


def hook_heartbeat(task: str, raw_id: str, agent_type: str, hook_event: str,
                   call_id: str, tool_name: str) -> None:
    """Fail-open fixed-pack heartbeat and bounded inflight update."""
    try:
        if hook_event not in ("PreToolUse", "PostToolUse"):
            return
        if any(len(raw_bytes(value)) > MAX_ARG for value in
               (raw_id, agent_type, call_id, tool_name)):
            return
        key, _, digest = instance(raw_id)
        runtime = _catalog_runtime(task)
        container = _catalog_container(runtime, False)
        with InstanceFlock(container, key):
            audit_fd = _instance_open_pack(container, key, "audit", True)
            work_fd = _instance_open_pack(container, key, "work", True)
            try:
                if any(_instance_pack_read_fd(audit_fd, "audit", key, slot) is not None
                       for slot in ("AMBIGUOUS", "DONE", "FINALIZED")):
                    return
                now = int(time.time())
                heartbeat = {"schema_version": 1, "instance_key": key,
                             "agent_id_sha256": digest, "heartbeat_epoch": now,
                             "agent_type": agent_type[:128]}
                _instance_local_write_fd(
                    audit_fd, "audit", "HEARTBEAT", heartbeat)
                if not call_id:
                    return
                current = _instance_pack_read_fd(
                    work_fd, "work", key, "INFLIGHT")
                if current is None:
                    current = {"schema_version": 1, "instance_key": key,
                               "entries": {}}
                if (current.get("schema_version") != 1 or
                        current.get("instance_key") != key or
                        not isinstance(current.get("entries"), dict)):
                    raise StateError("invalid-schema", "INFLIGHT table is invalid", 4)
                entries = dict(current["entries"])
                call_digest = sha(raw_bytes(call_id))
                if hook_event == "PreToolUse":
                    if call_digest not in entries and len(entries) >= 64:
                        raise StateError("inflight-capacity", "INFLIGHT table is full", 4, True)
                    entries[call_digest] = {
                        "call_id_sha256": call_digest,
                        "tool_name_sha256": sha(raw_bytes(tool_name)),
                        "started_epoch": now}
                else:
                    entries.pop(call_digest, None)
                successor = {"schema_version": 1, "instance_key": key,
                             "entries": dict(sorted(entries.items()))}
                if successor != current:
                    _instance_pack_write_fd(
                        work_fd, "work", key, "INFLIGHT", successor)
            finally:
                os.close(audit_fd); os.close(work_fd)
    except Exception:
        return


def _catalog_complete_instance_release(container: Path, key: str,
                                       request: int, config: dict) -> dict:
    """Resume ordinary RELEASE/flush/free from the selected CELL grammar."""
    if key.startswith("claim.") and HEX64.fullmatch(key[6:]):
        claim_digest = key[6:]
        try:
            fd = _instance_open_pack(container, claim_digest, "claim", True)
        except FileNotFoundError:
            fd = -1
        if fd >= 0:
            try:
                owner = _instance_pack_read_fd(fd, "claim", claim_digest, "OWNER")
                journal = _instance_pack_read_fd(fd, "claim", claim_digest, "GC_JOURNAL")
                key_record = _instance_pack_read_fd(fd, "claim", claim_digest, "KEY")
                receipt = _instance_pack_read_fd(fd, "claim", claim_digest, "RECEIPT")
                anchor = _instance_pack_read_fd(fd, "claim", claim_digest, "ANCHOR_ACK")
            finally:
                os.close(fd)
            receipt_digest = json_digest(receipt) if isinstance(receipt, dict) else None
            if (not isinstance(owner, dict) or owner.get("state") != "released-clean" or
                    not isinstance(journal, dict) or
                    journal.get("phase") != "will-claim-release" or
                    journal.get("logical_key_sha256") != claim_digest or
                    not isinstance(key_record, dict) or key_record.get("state") != "retired" or
                    key_record.get("key_digest") != journal.get("key_digest") or
                    not isinstance(receipt, dict) or
                    receipt.get("state") != "waiting-receipt-anchor" or
                    receipt.get("logical_key_sha256") != claim_digest or
                    not isinstance(anchor, dict) or anchor.get("state") != "did-anchor-ack" or
                    anchor.get("receipt_digest") != receipt_digest or
                    journal.get("receipt_digest") != receipt_digest or
                    journal.get("anchor_ack_digest") != json_digest(anchor)):
                raise StateError("catalog-root-invalid",
                                 "claim release lacks receipt/anchor/key authority", 4)
        else:
            # After physical-release, the selected recovery free-will is the
            # only surviving owner and is revalidated by the common path below.
            with CatalogFlock(container):
                proof = _catalog_validate_genesis(container)
                global_fd = proof.pop("global_fd")
                try:
                    duplicate, _ = _catalog_find_instance_cell(global_fd, proof, key)
                    if duplicate is None:
                        if proof["root_meta"].get("last_freed_subject_digest") == \
                                _catalog_instance_subject(key).hex():
                            return {"state": "free", "idempotent": True,
                                    "entries_deleted": 0, "bytes_reclaimed": 0,
                                    "free_receipt_record_digest": proof["root_meta"].get(
                                        "last_free_receipt_record_digest")}
                        raise StateError("catalog-root-invalid",
                                         "released claim owner mapping is absent", 4)
                    selector = proof["root"][2][4096:5120]
                    _, _, entry = _catalog_selected_entry(global_fd, selector, duplicate)
                    recovery_fd = os.open(
                        os.fsencode(container / ".catalog-recovery-pack.v1"),
                        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                    try:
                        _, _, recovery = _catalog_selected_recovery(
                            recovery_fd, entry, duplicate)
                    finally:
                        os.close(recovery_fd)
                    if recovery["payload"].get("_flush", {}).get("phase") != "free-will":
                        raise StateError("catalog-root-invalid",
                                         "claim pack disappeared before release authority", 4)
                finally:
                    os.close(global_fd)
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        global_fd = proof.pop("global_fd")
        try:
            duplicate, _ = _catalog_find_instance_cell(global_fd, proof, key)
            if duplicate is None:
                if proof["root_meta"].get("last_freed_subject_digest") == \
                        _catalog_instance_subject(key).hex():
                    return {"state": "free", "idempotent": True,
                            "entries_deleted": 0, "bytes_reclaimed": 0,
                            "free_receipt_record_digest":
                                proof["root_meta"].get("last_free_receipt_record_digest")}
                raise StateError("catalog-root-invalid", "instance release mapping is absent", 4)
            selector = proof["root"][2][4096:5120]
            _, _, entry = _catalog_selected_entry(global_fd, selector, duplicate)
            recovery_fd = os.open(os.fsencode(container / ".catalog-recovery-pack.v1"),
                                  os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            try:
                _, _, recovery = _catalog_selected_recovery(recovery_fd, entry, duplicate)
            finally:
                os.close(recovery_fd)
            flush = recovery["payload"].get("_flush")
            release = recovery["payload"].get("_operations", {}).get("RELEASE")
        finally:
            os.close(global_fd)
    if not flush or flush.get("phase") != "free-will":
        if release is None or release.get("phase") != "applied":
            _catalog_instance_delta(container, key, "RELEASE", -request)
        # A SETTLE/RELEASE overlay is historical only after its immutable frame
        # and CELL ACK; the helper is replay-safe at will/frame/ROOT/ACK priors.
        with CatalogFlock(container):
            proof = _catalog_validate_genesis(container)
            global_fd = proof.pop("global_fd")
            try:
                duplicate, _ = _catalog_find_instance_cell(global_fd, proof, key)
                if duplicate is None:
                    return {"state": "free", "idempotent": True,
                            "entries_deleted": 0, "bytes_reclaimed": 0,
                            "free_receipt_record_digest":
                                proof["root_meta"].get("last_free_receipt_record_digest")}
                selector = proof["root"][2][4096:5120]
                _, _, entry = _catalog_selected_entry(global_fd, selector, duplicate)
                recovery_fd = os.open(os.fsencode(container / ".catalog-recovery-pack.v1"),
                                      os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                try:
                    _, _, recovery = _catalog_selected_recovery(recovery_fd, entry, duplicate)
                finally:
                    os.close(recovery_fd)
                flush = recovery["payload"].get("_flush")
            finally:
                os.close(global_fd)
        if not flush or flush.get("phase") not in ("acked", "free-will"):
            _catalog_flush_cell(container, key, config)
    return _catalog_ordinary_free(container, key)


def hook_stop(task: str, raw_id: str, role_arg: str):
    """Commit a clean stop through fixed packs and the public CELL lifecycle."""
    try:
        role = canonical_role(role_arg)
        key, display, digest = instance(raw_id)
        container, _ = ensure_catalog_genesis(task)
        block = max(4096, os.statvfs(os.fsencode(container)).f_frsize)
        request = INSTANCE_AUDIT_SIZE + INSTANCE_WORK_SIZE + block
        config = _gc_config()
        terminal_cell = _terminal_lookup(container, key)
        if (terminal_cell is not None and
                terminal_cell.get("state") == "handoff-accepted"):
            event = event_identity("stop", role, digest, nonce_hex())
            terminal_record = terminal_cell["terminal_record"]
            if (terminal_record.get("agent_id_sha256") != digest or
                    terminal_record.get("canonical_role") != role):
                raise StateError("identity-conflict",
                                 "terminal cell identity conflicts", 3)
            if terminal_record.get("terminal_kind") == "done":
                return
            if terminal_record.get("terminal_kind") != "finalized":
                raise StateError("catalog-root-invalid",
                                 "terminal cell kind is invalid", 4)
            late_done = {
                "schema_version": 1, "instance_key": key,
                "agent_id_sha256": digest, "display_prefix": display,
                "canonical_role": role, "terminal_kind": "done",
                "terminal_epoch": int(time.time()), **event,
            }
            _terminal_late_clean(container, key, late_done)
            gc_step_command(task, "lifecycle")
            return
        if _terminal_has_reachable_tombstone(container, key):
            print("zyz-worker: late-event-retention-expired", file=sys.stderr)
            return
        with InstanceFlock(container, key):
            audit_fd = _instance_open_pack(container, key, "audit", True)
            work_fd = _instance_open_pack(container, key, "work", True)
            try:
                identity = _instance_pack_read_fd(audit_fd, "audit", key, "IDENTITY")
                start = _instance_pack_read_fd(audit_fd, "audit", key, "START")
                ambiguous = _instance_pack_read_fd(audit_fd, "audit", key, "AMBIGUOUS")
                done = _instance_pack_read_fd(audit_fd, "audit", key, "DONE")
                if (not isinstance(identity, dict) or identity.get("agent_id_sha256") != digest or
                        identity.get("canonical_role") != role):
                    raise StateError("identity-conflict", "fixed-pack identity conflicts", 3)
                if ambiguous is not None:
                    raise StateError("identity-conflict", "instance namespace is ambiguous", 4)
                if done is not None:
                    return
                if start is None:
                    raise StateError("missing-start", "fixed-pack START is missing", 3)
                event = _fixed_select_event_identity_fd(
                    audit_fd, work_fd, key, "stop", role, digest)
                if os.environ.get("ZYZ_TEST_PRIMARY_FAIL_BEFORE_JOURNAL") == "stop":
                    if os.environ.get("ZYZ_TEST_DIAGNOSTIC_WRITE_FAIL") == "1":
                        raise StateError("primary-diagnostic-write-failed",
                                         "injected diagnostic write failure", 4)
                    _fixed_append_diagnostic_fd(
                        audit_fd, key,
                        _fixed_diagnostic_record(
                            "stop", key, digest, role, event,
                            int(time.time()), "primary-stop-before-journal"))
                    print(f"zyz-worker: stop-uncommitted {event['event_token']}",
                          file=sys.stderr)
                    return
                journal = _instance_pack_read_fd(
                    work_fd, "work", key, "TRANSITION_JOURNAL")
                if (journal is None or
                        (journal.get("txn_type") in ("start", "reconcile-start") and
                         journal.get("phase") == "committed")):
                    journal = {"schema_version": 1, "txn_type": "stop",
                               "phase": "prepared", "instance_key": key,
                               "agent_id_sha256": digest, "canonical_role": role,
                               "display_prefix": display, "request_bytes": request,
                               "created_epoch": int(time.time()), **event}
                    _instance_pack_write_fd(
                        work_fd, "work", key, "TRANSITION_JOURNAL", journal)
                elif (journal.get("txn_type") != "stop" or
                      any(journal.get(field) != event[field] for field in
                          ("event_token", "nonce_sha256", "event_record_digest")) or
                      journal.get("request_bytes") != request):
                    raise StateError("identity-conflict", "stop event journal conflicts", 4)
            finally:
                os.close(audit_fd); os.close(work_fd)

        with InstanceFlock(container, key):
            audit_fd = _instance_open_pack(container, key, "audit", True)
            work_fd = _instance_open_pack(container, key, "work", True)
            try:
                done = _instance_pack_read_fd(audit_fd, "audit", key, "DONE")
                marker = {"schema_version": 1, "instance_key": key,
                          "agent_id_sha256": digest, "display_prefix": display,
                          "canonical_role": role, "terminal_kind": "done",
                          "terminal_epoch": int(time.time()),
                          "cleanup_state": "pending", "cleanup_pending": True,
                          "cleanup_error": None, "cleanup_intent_digest": None,
                          "cleanup_receipt_digest": None,
                          "free_receipt_record_digest": None, **event}
                if done is None:
                    _instance_pack_write_fd(audit_fd, "audit", key, "DONE", marker)
                elif any(done.get(field) != marker[field] for field in
                         ("instance_key", "agent_id_sha256", "canonical_role",
                          "event_token", "nonce_sha256", "event_record_digest")):
                    raise StateError("identity-conflict", "DONE record conflicts", 4)
                _instance_pack_retire_slots_fd(
                    audit_fd, "audit", key, ("START", "HEARTBEAT", "PROBE_STATE"))
                _instance_pack_retire_slots_fd(work_fd, "work", key, ("INFLIGHT",))
                journal = _instance_pack_read_fd(
                    work_fd, "work", key, "TRANSITION_JOURNAL")
                if journal is None or journal.get("txn_type") != "stop":
                    raise StateError("invalid-schema", "stop journal disappeared", 4)
                if journal.get("phase") != "committed":
                    journal = dict(journal, phase="committed",
                                   committed_epoch=marker["terminal_epoch"],
                                   done_digest=json_digest(marker),
                                   free_receipt_record_digest=None)
                    _instance_pack_write_fd(
                        work_fd, "work", key, "TRANSITION_JOURNAL", journal)
            finally:
                os.close(audit_fd); os.close(work_fd)
        _terminal_handoff_instance(container, key, request)
        _terminal_release_instance_objects(container, key, config)
        gc_step_command(task, "lifecycle")
    except StateError as exc:
        code = "event-lock-unavailable" if exc.code in ("catalog-lock-timeout", "lock-timeout") else exc.code
        print(f"zyz-worker: {code}", file=sys.stderr)
        return
    except Exception as exc:
        print(f"zyz-worker: tracking-unavailable: {str(exc)[:256]}", file=sys.stderr)
        return


def finalize_fixed(task: str, raw_id: str, role_arg: str, reason: str,
                   replacement: str | None = None) -> tuple[str, dict, bool]:
    """Finalize one fixed-pack instance, then compact it through terminal R/F/P."""
    role = canonical_role(role_arg)
    rb64, rh = normalize_reason(reason)
    replacement_digest = (sha(raw_bytes(replacement))
                          if replacement is not None else None)
    if replacement is not None:
        instance(replacement)
    key, display, digest = instance(raw_id)
    container, _ = ensure_catalog_genesis(task)
    block = max(4096, os.statvfs(os.fsencode(container)).f_frsize)
    request = INSTANCE_AUDIT_SIZE + INSTANCE_WORK_SIZE + block
    config = _gc_config()
    cell = _terminal_lookup(container, key)
    if cell is not None and cell["state"] == "handoff-accepted":
        marker = cell["terminal_record"]
        if (marker.get("terminal_kind") != "finalized" or
                marker.get("reason_sha256") != rh or
                marker.get("replacement_agent_id_sha256") != replacement_digest or
                marker.get("canonical_role") != role or
                marker.get("agent_id_sha256") != digest):
            raise StateError("already-terminal",
                             "instance already has a different terminal marker")
        if cell["instance_release"]["phase"] != "committed":
            cell = _terminal_release_instance_objects(container, key, config)
            marker = cell["terminal_record"]
        return key, marker, True

    idempotent = False
    with InstanceFlock(container, key):
        audit_fd = _instance_open_pack(container, key, "audit", True)
        work_fd = _instance_open_pack(container, key, "work", True)
        try:
            identity = _instance_pack_read_fd(
                audit_fd, "audit", key, "IDENTITY")
            start = _instance_pack_read_fd(audit_fd, "audit", key, "START")
            ambiguous = _instance_pack_read_fd(
                audit_fd, "audit", key, "AMBIGUOUS")
            done = _instance_pack_read_fd(audit_fd, "audit", key, "DONE")
            marker = _instance_pack_read_fd(
                audit_fd, "audit", key, "FINALIZED")
            journal = _instance_pack_read_fd(
                work_fd, "work", key, "TRANSITION_JOURNAL")
            if (not isinstance(identity, dict) or
                    identity.get("instance_key") != key or
                    identity.get("agent_id_sha256") != digest or
                    identity.get("canonical_role") != role):
                raise StateError("identity-conflict",
                                 "fixed-pack instance identity conflicts", 3)
            if ambiguous is not None:
                raise StateError("ambiguous", "instance namespace is ambiguous")
            if done is not None:
                raise StateError("already-terminal",
                                 "instance already completed naturally")
            if marker is not None:
                if (marker.get("terminal_kind") != "finalized" or
                        marker.get("reason_sha256") != rh or
                        marker.get("replacement_agent_id_sha256") !=
                            replacement_digest):
                    raise StateError("already-terminal",
                                     "instance has a different finalization")
                if (not isinstance(journal, dict) or
                        journal.get("schema_version") != 1 or
                        journal.get("txn_type") != "finalize" or
                        journal.get("instance_key") != key or
                        journal.get("agent_id_sha256") != digest or
                        journal.get("canonical_role") != role or
                        journal.get("reason_sha256") != rh or
                        journal.get("replacement_agent_id_sha256") !=
                            replacement_digest or
                        journal.get("terminal_record_digest") !=
                            json_digest(marker) or
                        journal.get("phase") not in
                            ("prepared", "committed-terminal")):
                    raise StateError("invalid-schema",
                                     "FINALIZED journal replay is invalid", 4)
                idempotent = True
            else:
                if start is None:
                    raise StateError("missing-start",
                                     "active fixed-pack START is missing", 3)
                now = int(time.time())
                marker = {
                    "schema_version": 1, "instance_key": key,
                    "agent_id_sha256": digest, "display_prefix": display,
                    "canonical_role": role, "terminal_kind": "finalized",
                    "terminal_epoch": now,
                    "terminal_iso": time.strftime(
                        "%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
                    "reason_b64": rb64, "reason_sha256": rh,
                    "replacement_agent_id_sha256": replacement_digest,
                    "cleanup_state": "pending", "cleanup_pending": True,
                    "cleanup_error": None, "cleanup_intent_digest": None,
                    "cleanup_receipt_digest": None,
                    "free_receipt_record_digest": None,
                }
                journal = {
                    "schema_version": 1, "txn_type": "finalize",
                    "phase": "prepared", "instance_key": key,
                    "agent_id_sha256": digest, "canonical_role": role,
                    "reason_sha256": rh,
                    "replacement_agent_id_sha256":
                        marker["replacement_agent_id_sha256"],
                    "created_epoch": now,
                    "terminal_record_digest": json_digest(marker),
                }
                _instance_pack_write_fd(
                    work_fd, "work", key, "TRANSITION_JOURNAL", journal)
                _instance_pack_write_fd(
                    audit_fd, "audit", key, "FINALIZED", marker)
                _catalog_barrier("terminal-handoff", "finalized-marker-committed")
            _instance_pack_retire_slots_fd(
                audit_fd, "audit", key,
                ("START", "HEARTBEAT", "PROBE_STATE"))
            _instance_pack_retire_slots_fd(
                work_fd, "work", key, ("INFLIGHT",))
            if journal["phase"] != "committed-terminal":
                journal = dict(
                    journal, phase="committed-terminal",
                    committed_epoch=marker["terminal_epoch"],
                    terminal_record_digest=json_digest(marker))
                _instance_pack_write_fd(
                    work_fd, "work", key, "TRANSITION_JOURNAL", journal)
        finally:
            os.close(work_fd)
            os.close(audit_fd)
    cell = _terminal_lookup(container, key)
    if cell is None or cell["state"] != "handoff-accepted":
        _terminal_handoff_instance(container, key, request)
    _terminal_release_instance_objects(container, key, config)
    gc_step_command(task, "lifecycle")
    return key, marker, idempotent


def probe_create(task, raw_id, role_arg, env):
    role = canonical_role(role_arg)
    key, display, digest = instance(raw_id)
    env["instance_key"] = key
    container, _ = ensure_catalog_genesis(task)
    if _terminal_lookup(container, key) is not None:
        raise StateError("terminal", "instance is terminal or handoff-pending")
    with InstanceFlock(container, key):
        audit_fd = _instance_open_pack(container, key, "audit", True)
        work_fd = _instance_open_pack(container, key, "work", False)
        try:
            identity = _instance_pack_read_fd(
                audit_fd, "audit", key, "IDENTITY")
            start = _instance_pack_read_fd(audit_fd, "audit", key, "START")
            ambiguous = _instance_pack_read_fd(
                audit_fd, "audit", key, "AMBIGUOUS")
            done = _instance_pack_read_fd(audit_fd, "audit", key, "DONE")
            finalized = _instance_pack_read_fd(
                audit_fd, "audit", key, "FINALIZED")
            latch = _instance_pack_read_fd(
                work_fd, "work", key, "TERMINAL_HANDOFF")
            if (not isinstance(identity, dict) or
                    identity.get("instance_key") != key or
                    identity.get("agent_id_sha256") != digest or
                    identity.get("canonical_role") != role):
                raise StateError("identity-conflict",
                                 "fixed-pack instance identity conflicts", 3)
            if ambiguous is not None:
                raise StateError("ambiguous", "instance namespace is ambiguous")
            if done is not None or finalized is not None or latch is not None:
                raise StateError("terminal", "instance is terminal")
            if start is None:
                raise StateError("missing-start", "active START is missing", 3)
            threshold = env_uint("ZYZ_RECONNECT_ACK_SEC", 600, 1, 86400, True)
            if threshold == 0:
                env.update(state="disabled", trusted=True,
                           tracking_capability="armed", creation_enabled=False)
                return env
            old = _instance_pack_read_fd(
                audit_fd, "audit", key, "PROBE_STATE")
            history = []
            hashes = set()
            if old:
                validate_probe(old, key)
                if old.get("state") == "pending":
                    raise StateError("probe-pending", "a probe is already pending")
                history = rotate_probe(
                    old, old.get("state", "unknown"), int(time.time()),
                    sha(b"new probe"))
                hashes = {x["probe_id_sha256"] for x in history}
            sequence = os.environ.get("ZYZ_TEST_RANDOM_HEX_SEQUENCE", "").split(",")
            pid, _, _ = select_probe_candidate(sequence, hashes)
            if pid is None:
                raise StateError("probe-id-collision",
                                 "probe id collision retry limit exhausted")
            now = int(time.time())
            data = {"schema_version": 2, "instance_key": key,
                    "instance_digest": digest, "display_prefix": display,
                    "canonical_role": role, "state": "pending",
                    "probe_id": pid, "probe_id_sha256": sha(pid.encode()),
                    "created_epoch": now, "deadline_epoch": now + threshold,
                    "history": history, "inflight_state": "unknown",
                    "inflight_count": 0}
            _instance_pack_write_fd(
                audit_fd, "audit", key, "PROBE_STATE", data)
        finally:
            os.close(work_fd)
            os.close(audit_fd)
    env.update(state="pending", trusted=True, tracking_capability="armed",
               probe_id=pid, probe_id_sha256=data["probe_id_sha256"],
               deadline_epoch=data["deadline_epoch"], creation_enabled=True,
               human_message=f"Please acknowledge runtime probe {pid} after observing this exact id.",
               shell_command=f"hooks/scripts/agent-runtime-state.sh probe-ack {json.dumps(task)} {json.dumps(raw_id)} {pid}")
    return env


def probe_update(command, task, raw_id, probe_id, reason, env):
    if not PROBE_RE.fullmatch(probe_id):
        raise StateError("invalid-probe-id", "probe id must match probe1- followed by 32 lowercase hex characters", 2)
    key, _, digest = instance(raw_id)
    env["instance_key"] = key
    container, _ = ensure_catalog_genesis(task)
    if _terminal_lookup(container, key) is not None:
        raise StateError("terminal", "instance is terminal or handoff-pending")
    with InstanceFlock(container, key):
        audit_fd = _instance_open_pack(container, key, "audit", True)
        work_fd = _instance_open_pack(container, key, "work", False)
        try:
            identity = _instance_pack_read_fd(
                audit_fd, "audit", key, "IDENTITY")
            ambiguous = _instance_pack_read_fd(
                audit_fd, "audit", key, "AMBIGUOUS")
            done = _instance_pack_read_fd(audit_fd, "audit", key, "DONE")
            finalized = _instance_pack_read_fd(
                audit_fd, "audit", key, "FINALIZED")
            latch = _instance_pack_read_fd(
                work_fd, "work", key, "TERMINAL_HANDOFF")
            if (not isinstance(identity, dict) or
                    identity.get("agent_id_sha256") != digest):
                raise StateError("identity-conflict",
                                 "fixed-pack instance identity conflicts", 3)
            if ambiguous is not None:
                raise StateError("ambiguous", "instance namespace is ambiguous")
            if done is not None or finalized is not None or latch is not None:
                raise StateError("terminal", "instance is terminal")
            data = _instance_pack_read_fd(
                audit_fd, "audit", key, "PROBE_STATE")
            if not data:
                raise StateError("missing-probe", "probe state is missing")
            validate_probe(data, key)
            if data.get("state") != "pending" or data.get("probe_id") != probe_id:
                raise StateError("probe-mismatch",
                                 "probe id is not the current pending challenge")
            now = int(time.time())
            rb64, rh = normalize_reason(reason)
            data["history"] = rotate_probe(
                data, "acked" if command == "probe-ack" else "cancelled",
                now, rh)
            data.update(state="acked" if command == "probe-ack" else "cancelled",
                        terminal_kind=None, completed_epoch=now,
                        reason_b64=rb64, reason_sha256=rh)
            _instance_pack_write_fd(
                audit_fd, "audit", key, "PROBE_STATE", data)
        finally:
            os.close(work_fd)
            os.close(audit_fd)
    env.update(state=data["state"], trusted=True,
               tracking_capability="armed", probe_id=probe_id,
               probe_id_sha256=data["probe_id_sha256"],
               deadline_epoch=data["deadline_epoch"],
               creation_enabled=env_uint(
                   "ZYZ_RECONNECT_ACK_SEC", 600, 1, 86400, True) != 0)
    return env


def _fixed_find_owned_event(entries: list[dict], kind: str, key: str,
                            digest: str, role: str, token: str) -> dict | None:
    matches = [item for item in entries
               if item.get("kind") == kind and item.get("event_token") == token]
    if len(matches) > 1:
        raise StateError("event-inventory-invalid",
                         "event token is duplicated in diagnostics", 4)
    if not matches:
        return None
    item = matches[0]
    if (item.get("instance_key") != key or
            item.get("raw_id_sha256") != digest or
            item.get("canonical_role") != role):
        raise StateError("event-conflict",
                         "persisted diagnostic does not match this request", 4)
    return item


def _fixed_find_receipt(receipts: list[dict], key: str, digest: str,
                        role: str, token: str) -> dict | None:
    matches = [item for item in receipts if item.get("event_token") == token]
    if len(matches) > 1:
        raise StateError("event-inventory-invalid",
                         "event token is duplicated in resolved receipts", 4)
    if not matches:
        return None
    receipt = matches[0]
    if (receipt.get("raw_id_sha256") != digest or
            receipt.get("canonical_role") != role):
        raise StateError("event-conflict",
                         "resolved receipt does not match this request", 4)
    return receipt


def _fixed_receipt_targets_match(fd: int, kind: str, key: str,
                                 receipt: dict) -> bool:
    slots = tuple(receipt["target_slot_generation"])
    generations, digests = _fixed_record_refs(fd, kind, key, slots)
    return (generations == receipt["target_slot_generation"] and
            digests == receipt["target_slot_digest"])


def _fixed_committed_reconcile_journal(journal: dict, generations: dict,
                                       digests: dict) -> dict:
    return {
        **{name: value for name, value in journal.items()
           if name not in ("phase", "committed_epoch",
                           "target_slot_generation", "target_slot_digest")},
        "phase": "committed",
        "committed_epoch": journal["resolved_epoch"],
        "target_slot_generation": generations,
        "target_slot_digest": digests,
    }


def _fixed_reconcile_receipt(kind: str, journal: dict, diagnostic: dict,
                             generations: dict, digests: dict,
                             committed_digest: str,
                             cleanup_state: str,
                             cleanup_txn_digest: str | None) -> dict:
    return {
        "schema_version": 1, "receipt_type": kind,
        "txn_id": journal["txn_id"],
        "event_token": diagnostic["event_token"],
        "nonce_sha256": diagnostic["nonce_sha256"],
        "event_record_digest": diagnostic["event_record_digest"],
        "raw_id_sha256": diagnostic["raw_id_sha256"],
        "canonical_role": diagnostic["canonical_role"],
        "owner_diagnostic_digest": journal["owner_diagnostic_digest"],
        "committed_journal_digest": committed_digest,
        "target_slot_generation": generations,
        "target_slot_digest": digests,
        "resolved_epoch": journal["resolved_epoch"],
        "outcome": f"reconciled-{kind}",
        "cleanup_state": cleanup_state,
        "cleanup_txn_digest": cleanup_txn_digest,
    }


def _fixed_resolve_diagnostic_fd(audit_fd: int, key: str, token: str,
                                 receipt_digest: str) -> None:
    entries = _fixed_diagnostics_fd(audit_fd, key)
    changed = False
    updated = []
    for item in entries:
        if item["event_token"] == token:
            if (item["needs_reconcile"] is False and
                    item["resolved_receipt_digest"] == receipt_digest):
                updated.append(item)
                continue
            if (item["needs_reconcile"] is not True or
                    item["resolved_receipt_digest"] is not None):
                raise StateError("receipt-mismatch",
                                 "diagnostic resolution conflicts", 4)
            item = dict(item, needs_reconcile=False,
                        resolved_receipt_digest=receipt_digest)
            changed = True
        updated.append(item)
    if not any(item["event_token"] == token for item in entries):
        raise StateError("reconcile-unavailable",
                         "matching diagnostic is unavailable", 4)
    if changed:
        _instance_pack_write_fd(
            audit_fd, "audit", key, "DIAGNOSTICS",
            {"schema_version": 1, "entries": updated},
            "reconcile-event")


def _fixed_append_receipt_fd(audit_fd: int, key: str, kind: str,
                             receipt: dict) -> str:
    entries = _fixed_resolved_fd(audit_fd, key, kind)
    for item in entries:
        if item["event_token"] == receipt["event_token"]:
            if item != receipt:
                raise StateError("receipt-mismatch",
                                 "resolved receipt conflicts", 4)
            return json_digest(item)
    if len(entries) >= EVENT_INVENTORY_LIMITS["resolved"]:
        raise StateError("event-inventory-invalid",
                         "resolved receipt ring is full", 4)
    slot = "RESOLVED_START" if kind == "start" else "RESOLVED_STOP"
    payload = {"schema_version": 1, "receipt_type": kind,
               "entries": entries + [receipt]}
    _instance_pack_write_fd(
        audit_fd, "audit", key, slot, payload, "reconcile-event")
    return json_digest(receipt)


def _fixed_reconcile_receipt_replay(
        audit_fd: int, key: str, kind: str, digest: str, role: str,
        token: str, diagnostic: dict | None, receipt: dict,
        journal: dict | None, cleanup_state: str,
        cleanup_txn_digest: str | None) -> tuple[str, dict]:
    """Validate a selected receipt and classify terminal versus WAL replay."""
    phase = journal.get("phase") if isinstance(journal, dict) else None
    receipt_digest = json_digest(receipt)
    if diagnostic is None:
        raise StateError("receipt-mismatch",
                         f"resolved {kind} receipt lost its diagnostic", 4)
    owner = dict(diagnostic, needs_reconcile=True,
                 resolved_receipt_digest=None)
    unresolved = (diagnostic.get("needs_reconcile") is True and
                  diagnostic.get("resolved_receipt_digest") is None)
    resolved = (diagnostic.get("needs_reconcile") is False and
                diagnostic.get("resolved_receipt_digest") == receipt_digest)
    if (not isinstance(journal, dict) or
            journal.get("schema_version") != 1 or
            journal.get("txn_type") != f"reconcile-{kind}" or
            journal.get("instance_key") != key or
            journal.get("agent_id_sha256") != digest or
            journal.get("canonical_role") != role or
            journal.get("event_token") != token or
            journal.get("owner_diagnostic_digest") != json_digest(owner) or
            receipt.get("owner_diagnostic_digest") != json_digest(owner) or
            phase not in ("will-diagnostic-resolved",
                          "did-diagnostic-resolved", "committed") or
            (phase == "will-diagnostic-resolved" and
             not (unresolved or resolved)) or
            (phase != "will-diagnostic-resolved" and not resolved) or
            not _fixed_receipt_targets_match(
                audit_fd, "audit", key, receipt)):
        raise StateError(
            "receipt-mismatch",
            f"resolved {kind} receipt no longer matches its owner", 4)
    generations = receipt["target_slot_generation"]
    digests = receipt["target_slot_digest"]
    committed = _fixed_committed_reconcile_journal(
        journal, generations, digests)
    expected = _fixed_reconcile_receipt(
        kind, journal, owner, generations, digests,
        json_digest(committed), cleanup_state, cleanup_txn_digest)
    if receipt != expected or (phase == "committed" and journal != committed):
        raise StateError(
            "receipt-mismatch",
            f"resolved {kind} receipt no longer matches its journal", 4)
    return phase, committed


def reconcile_start(task: str, raw_id: str, role_arg: str, token: str,
                    confirmed: str, env: dict) -> dict:
    if confirmed != "confirmed":
        raise StateError("confirmation-required",
                         "reconciliation requires literal confirmed", 2)
    if not EVENT_RE.fullmatch(token):
        raise StateError("invalid-event-token",
                         "event token must match evt1- followed by 64 lowercase hex", 2)
    role = canonical_role(role_arg)
    key, display, digest = instance(raw_id)
    env["instance_key"] = key
    container, _ = ensure_catalog_genesis(task)
    if _terminal_lookup(container, key) is not None:
        raise StateError("event-conflict",
                         "terminal namespace cannot accept reconciled start", 4)
    idempotent = False
    with InstanceFlock(container, key):
        audit_fd = _instance_open_pack(container, key, "audit", True)
        work_fd = _instance_open_pack(container, key, "work", True)
        try:
            diagnostics = _fixed_diagnostics_fd(audit_fd, key)
            receipts = _fixed_resolved_fd(audit_fd, key, "start")
            diagnostic = _fixed_find_owned_event(
                diagnostics, "start", key, digest, role, token)
            receipt = _fixed_find_receipt(receipts, key, digest, role, token)
            ambiguous = _instance_pack_read_fd(
                audit_fd, "audit", key, "AMBIGUOUS")
            done = _instance_pack_read_fd(audit_fd, "audit", key, "DONE")
            finalized = _instance_pack_read_fd(
                audit_fd, "audit", key, "FINALIZED")
            if ambiguous is not None or done is not None or finalized is not None:
                raise StateError("event-conflict",
                                 "namespace cannot accept reconciled start", 4)
            journal = _instance_pack_read_fd(
                work_fd, "work", key, "TRANSITION_JOURNAL")
            if receipt is not None:
                phase, committed = _fixed_reconcile_receipt_replay(
                    audit_fd, key, "start", digest, role, token,
                    diagnostic, receipt, journal, "not-applicable", None)
                if phase == "committed":
                    idempotent = True
                else:
                    receipt = None
                    diagnostic = dict(
                        diagnostic, needs_reconcile=True,
                        resolved_receipt_digest=None)
            if not idempotent:
                if diagnostic is None or diagnostic["needs_reconcile"] is not True:
                    raise StateError("reconcile-unavailable",
                                     "matching start diagnostic is unavailable", 4)
                owner_digest = json_digest(diagnostic)
                identity_record = {
                    "schema_version": 1, "instance_key": key,
                    "agent_id_sha256": digest, "display_prefix": display,
                    "canonical_role": role,
                }
                if journal is None:
                    start_record = {
                        "schema_version": 1, "instance_key": key,
                        "agent_id_sha256": digest, "canonical_role": role,
                        "start_epoch": diagnostic["event_epoch"],
                        "start_iso": time.strftime(
                            "%Y-%m-%dT%H:%M:%SZ",
                            time.gmtime(diagnostic["event_epoch"])),
                        "event_token": diagnostic["event_token"],
                        "nonce_sha256": diagnostic["nonce_sha256"],
                        "event_record_digest": diagnostic["event_record_digest"],
                        "identity_generation": 1,
                        "identity_digest": "pending",
                    }
                    journal = {
                        "schema_version": 1, "txn_type": "reconcile-start",
                        "phase": "prepared", "txn_id": sha(
                            b"zyz-reconcile-start-v1" + bytes.fromhex(
                                token.removeprefix("evt1-"))),
                        "instance_key": key, "agent_id_sha256": digest,
                        "canonical_role": role,
                        "owner_diagnostic_digest": owner_digest,
                        "event_token": diagnostic["event_token"],
                        "nonce_sha256": diagnostic["nonce_sha256"],
                        "event_record_digest": diagnostic["event_record_digest"],
                        "event_epoch": diagnostic["event_epoch"],
                        "resolved_epoch": int(time.time()),
                        "identity_record": identity_record,
                        "start_record": start_record,
                    }
                    _instance_pack_write_fd(
                        work_fd, "work", key, "TRANSITION_JOURNAL", journal,
                        "reconcile-start")
                if (journal.get("schema_version") != 1 or
                        journal.get("txn_type") != "reconcile-start" or
                        journal.get("instance_key") != key or
                        journal.get("agent_id_sha256") != digest or
                        journal.get("canonical_role") != role or
                        journal.get("owner_diagnostic_digest") != owner_digest or
                        journal.get("event_token") != token):
                    raise StateError("event-conflict",
                                     "a different event owns the start journal", 4)
                phase = journal.get("phase")
                if phase == "prepared":
                    journal = dict(journal, phase="will-identity")
                    _instance_pack_write_fd(work_fd, "work", key,
                                            "TRANSITION_JOURNAL", journal,
                                            "reconcile-start")
                    phase = "will-identity"
                if phase == "will-identity":
                    observed = _instance_pack_read_fd(
                        audit_fd, "audit", key, "IDENTITY")
                    if observed is None:
                        _instance_pack_write_fd(
                            audit_fd, "audit", key, "IDENTITY",
                            journal["identity_record"], "reconcile-start")
                    elif observed != journal["identity_record"]:
                        raise StateError("event-conflict",
                                         "IDENTITY target conflicts", 4)
                    identity_generations, identity_digests = _fixed_record_refs(
                        audit_fd, "audit", key, ("IDENTITY",))
                    start_record = dict(
                        journal["start_record"],
                        identity_generation=identity_generations["IDENTITY"],
                        identity_digest=identity_digests["IDENTITY"])
                    journal = dict(journal, phase="did-identity",
                                   start_record=start_record)
                    _instance_pack_write_fd(work_fd, "work", key,
                                            "TRANSITION_JOURNAL", journal,
                                            "reconcile-start")
                    phase = "did-identity"
                if phase == "did-identity":
                    journal = dict(journal, phase="will-start")
                    _instance_pack_write_fd(work_fd, "work", key,
                                            "TRANSITION_JOURNAL", journal,
                                            "reconcile-start")
                    phase = "will-start"
                if phase == "will-start":
                    observed = _instance_pack_read_fd(
                        audit_fd, "audit", key, "START")
                    if observed is None:
                        _instance_pack_write_fd(
                            audit_fd, "audit", key, "START",
                            journal["start_record"], "reconcile-start")
                    elif observed != journal["start_record"]:
                        raise StateError("event-conflict", "START target conflicts", 4)
                    journal = dict(journal, phase="did-start")
                    _instance_pack_write_fd(work_fd, "work", key,
                                            "TRANSITION_JOURNAL", journal,
                                            "reconcile-start")
                    phase = "did-start"
                generations, digests = _fixed_record_refs(
                    audit_fd, "audit", key, ("IDENTITY", "START"))
                committed = _fixed_committed_reconcile_journal(
                    journal, generations, digests)
                committed_digest = json_digest(committed)
                receipt = _fixed_reconcile_receipt(
                    "start", journal, diagnostic, generations, digests,
                    committed_digest, "not-applicable", None)
                if phase == "did-start":
                    journal = dict(journal, phase="will-diagnostic-resolved")
                    _instance_pack_write_fd(work_fd, "work", key,
                                            "TRANSITION_JOURNAL", journal,
                                            "reconcile-start")
                    _catalog_barrier(
                        "reconcile-start", "will-diagnostic-resolved")
                    phase = "will-diagnostic-resolved"
                if phase == "will-diagnostic-resolved":
                    receipt_digest = _fixed_append_receipt_fd(
                        audit_fd, key, "start", receipt)
                    _fixed_resolve_diagnostic_fd(
                        audit_fd, key, token, receipt_digest)
                    journal = dict(journal, phase="did-diagnostic-resolved")
                    _instance_pack_write_fd(work_fd, "work", key,
                                            "TRANSITION_JOURNAL", journal,
                                            "reconcile-start")
                    _catalog_barrier(
                        "reconcile-start", "did-diagnostic-resolved")
                    phase = "did-diagnostic-resolved"
                if phase == "did-diagnostic-resolved":
                    _instance_pack_write_fd(
                        work_fd, "work", key, "TRANSITION_JOURNAL",
                        committed, "reconcile-start")
                elif phase != "committed":
                    raise StateError("transition-corrupt",
                                     "reconcile-start journal phase is invalid", 4)
                journal = committed
        finally:
            os.close(work_fd); os.close(audit_fd)
    env.update(state="reconciled-start", trusted=True,
               tracking_capability="armed", idempotent=idempotent,
               event_token=token, reconciled_epoch=(
                   receipt["resolved_epoch"] if receipt is not None else
                   journal["resolved_epoch"]),
               no_output_capability="unavailable")
    return env


def reconcile_stop(task: str, raw_id: str, role_arg: str, token: str,
                   confirmed: str, env: dict) -> dict:
    if confirmed != "confirmed":
        raise StateError("confirmation-required",
                         "reconciliation requires literal confirmed", 2)
    if not EVENT_RE.fullmatch(token):
        raise StateError("invalid-event-token",
                         "event token must match evt1- followed by 64 lowercase hex", 2)
    role = canonical_role(role_arg)
    key, display, digest = instance(raw_id)
    env["instance_key"] = key
    container, _ = ensure_catalog_genesis(task)
    terminal_cell = _terminal_lookup(container, key)
    if terminal_cell is not None and terminal_cell.get("state") == "handoff-accepted":
        marker = terminal_cell["terminal_record"]
        receipts = terminal_cell.get("event_receipts", {})
        late = terminal_cell.get("late_clean")
        terminal_token = (((late or {}).get("done_record") or {}).get("event_token")
                          if late is not None else marker.get("event_token"))
        if (receipts.get("latest_stop_event_token") != token or
                terminal_token != token or marker.get("agent_id_sha256") != digest or
                marker.get("canonical_role") != role):
            raise StateError("already-terminal",
                             "terminal cell is owned by another event", 4)
        env.update(state="reconciled-stop", trusted=True,
                   tracking_capability="armed", idempotent=True,
                   event_token=token,
                   reconciled_epoch=(late or {}).get(
                       "done_record", {}).get("terminal_epoch"),
                   terminal_kind="done",
                   terminal_epoch=(late or {}).get(
                       "done_record", {}).get("terminal_epoch"),
                   late_clean=late is not None,
                   preserved_terminal_kind=(marker.get("terminal_kind")
                                              if late is not None else None),
                   cleanup_state=marker.get("cleanup_state", "compacted"),
                   cleanup_pending=marker.get("cleanup_pending", False))
        return env
    idempotent = False
    marker = None
    with InstanceFlock(container, key):
        audit_fd = _instance_open_pack(container, key, "audit", True)
        work_fd = _instance_open_pack(container, key, "work", True)
        try:
            identity = _instance_pack_read_fd(
                audit_fd, "audit", key, "IDENTITY")
            start = _instance_pack_read_fd(audit_fd, "audit", key, "START")
            ambiguous = _instance_pack_read_fd(
                audit_fd, "audit", key, "AMBIGUOUS")
            done = _instance_pack_read_fd(audit_fd, "audit", key, "DONE")
            finalized = _instance_pack_read_fd(
                audit_fd, "audit", key, "FINALIZED")
            if (not isinstance(identity, dict) or
                    identity.get("agent_id_sha256") != digest or
                    identity.get("canonical_role") != role):
                raise StateError("identity-conflict",
                                 "fixed-pack identity conflicts", 4)
            if ambiguous is not None:
                raise StateError("ambiguous", "instance namespace is ambiguous", 4)
            diagnostics = _fixed_diagnostics_fd(audit_fd, key)
            receipts = _fixed_resolved_fd(audit_fd, key, "stop")
            diagnostic = _fixed_find_owned_event(
                diagnostics, "stop", key, digest, role, token)
            receipt = _fixed_find_receipt(receipts, key, digest, role, token)
            journal = _instance_pack_read_fd(
                work_fd, "work", key, "TRANSITION_JOURNAL")
            receipt_replay = False
            if receipt is not None:
                receipt_marker = (journal.get("done_record")
                                  if isinstance(journal, dict) else None)
                if not isinstance(receipt_marker, dict) or done != receipt_marker:
                    raise StateError("receipt-mismatch",
                                     "resolved stop receipt lost its DONE target", 4)
                phase, committed = _fixed_reconcile_receipt_replay(
                    audit_fd, key, "stop", digest, role, token,
                    diagnostic, receipt, journal,
                    receipt_marker.get("cleanup_state", "pending"),
                    receipt_marker.get("cleanup_intent_digest"))
                marker = receipt_marker
                if phase == "committed":
                    idempotent = True
                else:
                    receipt_replay = True
                    receipt = None
                    diagnostic = dict(
                        diagnostic, needs_reconcile=True,
                        resolved_receipt_digest=None)
            if not idempotent:
                if diagnostic is None or diagnostic["needs_reconcile"] is not True:
                    raise StateError("reconcile-unavailable",
                                     "matching stop diagnostic is unavailable", 4)
                owner_digest = json_digest(diagnostic)
                owned_stop_replay = (
                    isinstance(journal, dict) and
                    journal.get("schema_version") == 1 and
                    journal.get("txn_type") == "reconcile-stop" and
                    journal.get("phase") in (
                        "will-done", "did-done",
                        "will-diagnostic-resolved") and
                    journal.get("instance_key") == key and
                    journal.get("agent_id_sha256") == digest and
                    journal.get("canonical_role") == role and
                    journal.get("owner_diagnostic_digest") == owner_digest and
                    journal.get("event_token") == token and
                    isinstance(journal.get("done_record"), dict) and
                    done == journal["done_record"])
                if (done is not None and
                        not (receipt_replay or owned_stop_replay)):
                    raise StateError("already-terminal",
                                     "natural DONE is owned by another event", 4)
                if (start is None and
                        not (receipt_replay or owned_stop_replay)):
                    raise StateError("missing-start", "active START is missing", 4)
                if journal is None or journal.get("txn_type") in (
                        "start", "reconcile-start", "finalize"):
                    if (journal is not None and journal.get("txn_type") == "finalize" and
                            journal.get("phase") != "committed-terminal"):
                        raise StateError("transition-incomplete",
                                         "FINALIZED journal is incomplete", 4, True)
                    late_clean = finalized is not None
                    marker = {
                        "schema_version": 1, "instance_key": key,
                        "agent_id_sha256": digest, "display_prefix": display,
                        "canonical_role": role, "terminal_kind": "done",
                        "terminal_epoch": diagnostic["event_epoch"],
                        "terminal_iso": time.strftime(
                            "%Y-%m-%dT%H:%M:%SZ",
                            time.gmtime(diagnostic["event_epoch"])),
                        "late_clean": late_clean,
                        "preserved_terminal_kind": (
                            "finalized" if late_clean else None),
                        "cleanup_state": "pending", "cleanup_pending": True,
                        "cleanup_error": None, "cleanup_intent_digest": None,
                        "cleanup_receipt_digest": None,
                        "free_receipt_record_digest": None,
                        "event_token": diagnostic["event_token"],
                        "nonce_sha256": diagnostic["nonce_sha256"],
                        "event_record_digest": diagnostic["event_record_digest"],
                    }
                    journal = {
                        "schema_version": 1, "txn_type": "reconcile-stop",
                        "phase": "prepared", "txn_id": sha(
                            b"zyz-reconcile-stop-v1" + bytes.fromhex(
                                token.removeprefix("evt1-"))),
                        "instance_key": key, "agent_id_sha256": digest,
                        "canonical_role": role,
                        "owner_diagnostic_digest": owner_digest,
                        "event_token": diagnostic["event_token"],
                        "nonce_sha256": diagnostic["nonce_sha256"],
                        "event_record_digest": diagnostic["event_record_digest"],
                        "event_epoch": diagnostic["event_epoch"],
                        "resolved_epoch": int(time.time()),
                        "done_record": marker,
                    }
                    _instance_pack_write_fd(
                        work_fd, "work", key, "TRANSITION_JOURNAL", journal,
                        "reconcile-stop")
                if (journal.get("schema_version") != 1 or
                        journal.get("txn_type") != "reconcile-stop" or
                        journal.get("instance_key") != key or
                        journal.get("agent_id_sha256") != digest or
                        journal.get("canonical_role") != role or
                        journal.get("owner_diagnostic_digest") != owner_digest or
                        journal.get("event_token") != token):
                    raise StateError("event-conflict",
                                     "a different event owns the stop journal", 4)
                marker = journal.get("done_record")
                phase = journal.get("phase")
                if phase == "prepared":
                    journal = dict(journal, phase="will-done")
                    _instance_pack_write_fd(work_fd, "work", key,
                                            "TRANSITION_JOURNAL", journal,
                                            "reconcile-stop")
                    phase = "will-done"
                if phase == "will-done":
                    observed = _instance_pack_read_fd(
                        audit_fd, "audit", key, "DONE")
                    if observed is None:
                        _instance_pack_write_fd(
                            audit_fd, "audit", key, "DONE", marker,
                            "reconcile-stop")
                    elif observed != marker:
                        raise StateError("event-conflict", "DONE target conflicts", 4)
                    _instance_pack_retire_slots_fd(
                        audit_fd, "audit", key,
                        ("START", "HEARTBEAT", "PROBE_STATE"))
                    _instance_pack_retire_slots_fd(
                        work_fd, "work", key, ("INFLIGHT",))
                    journal = dict(journal, phase="did-done")
                    _instance_pack_write_fd(work_fd, "work", key,
                                            "TRANSITION_JOURNAL", journal,
                                            "reconcile-stop")
                    phase = "did-done"
                generations, digests = _fixed_record_refs(
                    audit_fd, "audit", key, ("DONE",))
                committed = _fixed_committed_reconcile_journal(
                    journal, generations, digests)
                committed_digest = json_digest(committed)
                receipt = _fixed_reconcile_receipt(
                    "stop", journal, diagnostic, generations, digests,
                    committed_digest, marker.get("cleanup_state", "pending"),
                    marker.get("cleanup_intent_digest"))
                if phase == "did-done":
                    journal = dict(journal, phase="will-diagnostic-resolved")
                    _instance_pack_write_fd(work_fd, "work", key,
                                            "TRANSITION_JOURNAL", journal,
                                            "reconcile-stop")
                    _catalog_barrier(
                        "reconcile-stop", "will-diagnostic-resolved")
                    phase = "will-diagnostic-resolved"
                if phase == "will-diagnostic-resolved":
                    receipt_digest = _fixed_append_receipt_fd(
                        audit_fd, key, "stop", receipt)
                    _fixed_resolve_diagnostic_fd(
                        audit_fd, key, token, receipt_digest)
                    journal = dict(journal, phase="did-diagnostic-resolved")
                    _instance_pack_write_fd(work_fd, "work", key,
                                            "TRANSITION_JOURNAL", journal,
                                            "reconcile-stop")
                    _catalog_barrier(
                        "reconcile-stop", "did-diagnostic-resolved")
                    phase = "did-diagnostic-resolved"
                if phase == "did-diagnostic-resolved":
                    _instance_pack_write_fd(
                        work_fd, "work", key, "TRANSITION_JOURNAL",
                        committed, "reconcile-stop")
                elif phase != "committed":
                    raise StateError("transition-corrupt",
                                     "reconcile-stop journal phase is invalid", 4)
        finally:
            os.close(work_fd); os.close(audit_fd)
    block = max(4096, os.statvfs(os.fsencode(container)).f_frsize)
    request = INSTANCE_AUDIT_SIZE + INSTANCE_WORK_SIZE + block
    config = _gc_config()
    cell = _terminal_lookup(container, key)
    if cell is None or cell.get("state") != "handoff-accepted":
        cell = _terminal_handoff_instance(container, key, request)
    cell = _terminal_release_instance_objects(container, key, config)
    terminal_marker = cell["terminal_record"]
    late = cell.get("late_clean")
    done_record = ((late or {}).get("done_record")
                   if late is not None else terminal_marker)
    env.update(state="reconciled-stop", trusted=True,
               tracking_capability="armed", idempotent=idempotent,
               event_token=token, reconciled_epoch=receipt["resolved_epoch"],
               terminal_kind="done",
               terminal_epoch=done_record.get("terminal_epoch"),
               late_clean=late is not None,
               preserved_terminal_kind=(terminal_marker.get("terminal_kind")
                                          if late is not None else None),
               cleanup_state=terminal_marker.get("cleanup_state", "compacted"),
               cleanup_pending=terminal_marker.get("cleanup_pending", False))
    return env


def legacy_start_evidence(path: Path, role: str) -> tuple[bytes, int]:
    try:
        observed = read_regular_bytes(path, 4096)
    except FileNotFoundError:
        raise StateError("missing-legacy", "legacy start marker is missing", 3)
    if observed is None:
        raise StateError("missing-legacy", "legacy start marker is missing", 3)
    raw = observed[0]
    if not raw:
        raise StateError("invalid-legacy", "legacy start evidence is empty or oversized", 3)
    try:
        line = raw.decode("utf-8").splitlines()[0]
        fields = line.split()
        if len(fields) < 2 or canonical_role(fields[-1]) != role:
            raise StateError("role-conflict", "legacy role does not match", 3)
        parsed = time.strptime(fields[0], "%Y-%m-%dT%H:%M:%SZ")
        epoch = int(__import__("calendar").timegm(parsed))
    except StateError:
        raise
    except Exception:
        raise StateError("invalid-legacy", "legacy start timestamp is not canonical UTC", 3)
    return raw, epoch


def adopt_legacy(task, raw_id, role_arg, confirmed, env):
    if confirmed != "confirmed":
        raise StateError("confirmation-required",
                         "adoption requires literal confirmed", 2)
    role = canonical_role(role_arg)
    agents = agents_dir(task)
    key, display, digest = instance(raw_id)
    env["instance_key"] = key
    legacy = re.sub(r"[^A-Za-z0-9._-]", "_", raw_id)
    old_start = agents / f"{legacy}.start"
    container, _ = ensure_catalog_genesis(task)
    if _terminal_lookup(container, key) is not None:
        raise StateError("already-terminal",
                         "legacy target already has terminal authority", 4)

    # A committed fixed receipt is sufficient after the legacy triggers have
    # been retired; retries must not recreate pathname control authority.
    resume_journal = None
    with ExitStack() as existing_namespace:
        try:
            existing_namespace.enter_context(
                InstanceFlock(container, key, missing_is_absent=True))
        except FileNotFoundError:
            pass
        else:
            audit_fd = _instance_open_pack(container, key, "audit", False)
            work_fd = _instance_open_pack(container, key, "work", False)
            try:
                identity = _instance_pack_read_fd(
                    audit_fd, "audit", key, "IDENTITY")
                start = _instance_pack_read_fd(
                    audit_fd, "audit", key, "START")
                migrated = _instance_pack_read_fd(
                    audit_fd, "audit", key, "SUCCESSOR_RECEIPTS")
                existing_journal = _instance_pack_read_fd(
                    work_fd, "work", key, "TRANSITION_JOURNAL")
            finally:
                os.close(work_fd)
                os.close(audit_fd)
            if (isinstance(identity, dict) and isinstance(start, dict) and
                    isinstance(migrated, dict) and
                    isinstance(existing_journal, dict) and
                    migrated.get("schema_version") == 1 and
                    migrated.get("receipt_type") == "legacy-migrated" and
                    migrated.get("instance_key") == key and
                    migrated.get("legacy_key") == legacy and
                    migrated.get("canonical_role") == role and
                    migrated.get("identity_digest") == json_digest(identity) and
                    migrated.get("start_digest") == json_digest(start) and
                    identity.get("agent_id_sha256") == digest and
                    identity.get("canonical_role") == role and
                    existing_journal.get("txn_type") == "start" and
                    existing_journal.get("phase") == "committed" and
                    existing_journal.get("migrated_digest") ==
                        json_digest(migrated)):
                env.update(state="adopted-legacy", trusted=True,
                           tracking_capability="armed", idempotent=True)
                return env
            if (not isinstance(existing_journal, dict) or
                    existing_journal.get("txn_type") not in
                        ("adopt-legacy", "start") or
                    existing_journal.get("instance_key") != key or
                    existing_journal.get("legacy_key") != legacy or
                    existing_journal.get("canonical_role") != role):
                raise StateError("state-conflict",
                                 "existing fixed namespace is not this adoption", 4)
            resume_journal = existing_journal

    if resume_journal is None:
        legacy_raw, legacy_epoch = legacy_start_evidence(old_start, role)
    else:
        try:
            legacy_raw = base64.b64decode(
                resume_journal["legacy_start_b64"], validate=True)
            legacy_epoch = resume_journal["start_record"]["start_epoch"]
        except Exception:
            raise StateError("invalid-schema",
                             "legacy adoption replay evidence is invalid", 4)
        if (not legacy_raw or len(legacy_raw) > 4096 or
                not isinstance(legacy_epoch, int) or legacy_epoch < 0):
            raise StateError("invalid-schema",
                             "legacy adoption replay evidence is invalid", 4)
    legacy_digest = sha(legacy_raw)
    deterministic_nonce = hashlib.sha256(
        b"zyz-legacy-adoption-event-v1" + bytes.fromhex(digest) +
        bytes.fromhex(legacy_digest) + role.encode()).hexdigest()[:32]
    event = event_identity("start", role, digest, deterministic_nonce)
    block = max(4096, os.statvfs(os.fsencode(container)).f_frsize)
    request = INSTANCE_AUDIT_SIZE + INSTANCE_WORK_SIZE + block
    reservation = _catalog_reserve_instance(
        container, key, request, _gc_config(), event)
    if not reservation["event_matches"]:
        raise StateError("identity-conflict",
                         "legacy adoption reservation conflicts", 4)
    if reservation["resume_state"] == "reserved":
        identities = _instance_create_reserved_objects(container, key, reservation)
        reservation = _catalog_instance_cell_transition(
            container, key, reservation, "owner-active", identities, True)
    else:
        expected = reservation.get("object_identities_digest")
        if not isinstance(expected, str) or not HEX64.fullmatch(expected):
            raise StateError("catalog-root-invalid",
                             "legacy target object identity is invalid", 4)
        _instance_validate_reserved_objects(container, reservation, expected)
    if reservation["resume_state"] == "owner-active":
        reservation = _catalog_instance_cell_transition(
            container, key, reservation, "cell-active-ack")

    with CatalogFlock(container, ".catalog-shared-source-lock.v1"):
        with InstanceFlock(container, key):
            audit_fd = _instance_open_pack(container, key, "audit", True)
            work_fd = _instance_open_pack(container, key, "work", True)
            try:
                journal = _instance_pack_read_fd(
                    work_fd, "work", key, "TRANSITION_JOURNAL")
                if journal is None:
                    heartbeat_path = agents / f"{legacy}.heartbeat"
                    heartbeat_observed = read_regular_bytes(
                        heartbeat_path, 16384, True)
                    legacy_heartbeat_raw = (None if heartbeat_observed is None
                                            else heartbeat_observed[0])
                    identity = {
                        "schema_version": 1, "instance_key": key,
                        "agent_id_sha256": digest, "display_prefix": display,
                        "canonical_role": role, "legacy_key": legacy,
                        "legacy_start_sha256": legacy_digest,
                    }
                    start = {
                        "schema_version": 1, "instance_key": key,
                        "agent_id_sha256": digest, "canonical_role": role,
                        "start_epoch": legacy_epoch,
                        "start_iso": time.strftime(
                            "%Y-%m-%dT%H:%M:%SZ", time.gmtime(legacy_epoch)),
                        "legacy_key": legacy,
                        "legacy_start_sha256": legacy_digest, **event,
                    }
                    journal = {
                        "schema_version": 1, "txn_type": "adopt-legacy",
                        "phase": "prepared", "instance_key": key,
                        "agent_id_sha256": digest, "canonical_role": role,
                        "legacy_key": legacy,
                        "legacy_start_sha256": legacy_digest,
                        "legacy_start_b64": base64.b64encode(legacy_raw).decode(),
                        "legacy_heartbeat_sha256": (
                            None if legacy_heartbeat_raw is None
                            else sha(legacy_heartbeat_raw)),
                        "legacy_heartbeat_b64": (
                            None if legacy_heartbeat_raw is None else
                            base64.b64encode(legacy_heartbeat_raw).decode()),
                        "identity_record": identity,
                        "identity_digest": json_digest(identity),
                        "start_record": start,
                        "start_digest": json_digest(start),
                        "created_epoch": int(time.time()), **event,
                    }
                    _instance_pack_write_fd(
                        work_fd, "work", key, "TRANSITION_JOURNAL", journal)
                    _catalog_barrier("legacy-adopt", "prepared")
                try:
                    frozen_start = base64.b64decode(
                        journal.get("legacy_start_b64"), validate=True)
                    heartbeat_b64 = journal.get("legacy_heartbeat_b64")
                    heartbeat_digest = journal.get("legacy_heartbeat_sha256")
                    if heartbeat_b64 is None and heartbeat_digest is None:
                        frozen_heartbeat = None
                    elif (isinstance(heartbeat_b64, str) and
                          isinstance(heartbeat_digest, str) and
                          HEX64.fullmatch(heartbeat_digest)):
                        frozen_heartbeat = base64.b64decode(
                            heartbeat_b64, validate=True)
                    else:
                        raise ValueError
                except Exception:
                    raise StateError(
                        "invalid-schema",
                        "fixed legacy adoption source evidence is invalid", 4)
                if (journal.get("schema_version") != 1 or
                        journal.get("txn_type") not in ("adopt-legacy", "start") or
                        journal.get("instance_key") != key or
                        journal.get("agent_id_sha256") != digest or
                        journal.get("canonical_role") != role or
                        journal.get("legacy_key") != legacy or
                        journal.get("legacy_start_sha256") != legacy_digest or
                        frozen_start != legacy_raw or
                        (frozen_heartbeat is not None and
                         (len(frozen_heartbeat) > 16384 or
                          sha(frozen_heartbeat) != heartbeat_digest)) or
                        journal.get("identity_digest") !=
                            json_digest(journal.get("identity_record")) or
                        journal.get("start_digest") !=
                            json_digest(journal.get("start_record"))):
                    raise StateError("invalid-schema",
                                     "fixed legacy adoption journal is invalid", 4)
                phases = ("prepared", "will-identity", "did-identity",
                          "will-start", "did-start", "will-migrated",
                          "did-migrated", "will-source-retire",
                          "did-source-retire", "committed")
                phase = journal.get("phase")
                if phase not in phases:
                    raise StateError("invalid-schema",
                                     "fixed legacy adoption phase is invalid", 4)

                def advance(name: str, **extra) -> None:
                    nonlocal journal, phase
                    journal = {**journal, **extra, "phase": name}
                    _instance_pack_write_fd(
                        work_fd, "work", key, "TRANSITION_JOURNAL", journal)
                    _catalog_barrier("legacy-adopt", name)
                    phase = name

                source_now = read_regular_bytes(old_start, 4096, True)
                if (phase not in ("will-source-retire", "did-source-retire",
                                  "committed") and
                        (source_now is None or source_now[0] != legacy_raw)):
                    raise StateError("transition-corrupt",
                                     "legacy source changed during adoption", 4)
                if phase == "prepared":
                    advance("will-identity")
                if phase == "will-identity":
                    observed = _instance_pack_read_fd(
                        audit_fd, "audit", key, "IDENTITY")
                    if observed is None:
                        _instance_pack_write_fd(
                            audit_fd, "audit", key, "IDENTITY",
                            journal["identity_record"])
                    elif observed != journal["identity_record"]:
                        raise StateError("identity-conflict",
                                         "legacy target IDENTITY conflicts", 4)
                    advance("did-identity")
                if phase == "did-identity":
                    advance("will-start")
                if phase == "will-start":
                    observed = _instance_pack_read_fd(
                        audit_fd, "audit", key, "START")
                    if observed is None:
                        _instance_pack_write_fd(
                            audit_fd, "audit", key, "START",
                            journal["start_record"])
                    elif observed != journal["start_record"]:
                        raise StateError("identity-conflict",
                                         "legacy target START conflicts", 4)
                    advance("did-start")
                if phase == "did-start":
                    advance("will-migrated")
                if phase == "will-migrated":
                    identity = _instance_pack_read_fd(
                        audit_fd, "audit", key, "IDENTITY")
                    start = _instance_pack_read_fd(
                        audit_fd, "audit", key, "START")
                    migrated = {
                        "schema_version": 1,
                        "receipt_type": "legacy-migrated",
                        "legacy_key": legacy, "instance_key": key,
                        "canonical_role": role,
                        "legacy_start_sha256": legacy_digest,
                        "identity_digest": json_digest(identity),
                        "start_digest": json_digest(start),
                        "migrated_epoch": journal["created_epoch"],
                    }
                    observed = _instance_pack_read_fd(
                        audit_fd, "audit", key, "SUCCESSOR_RECEIPTS")
                    if observed is None:
                        _instance_pack_write_fd(
                            audit_fd, "audit", key,
                            "SUCCESSOR_RECEIPTS", migrated)
                    elif observed != migrated:
                        raise StateError("identity-conflict",
                                         "legacy migration receipt conflicts", 4)
                    advance("did-migrated",
                            migrated_record=migrated,
                            migrated_digest=json_digest(migrated))
                if phase == "did-migrated":
                    advance("will-source-retire")
                if phase == "will-source-retire":
                    sources = ((old_start, legacy_raw),
                               (agents / f"{legacy}.heartbeat",
                                frozen_heartbeat))
                    observed_sources = []
                    for path, expected_raw in sources:
                        observed = read_regular_bytes(path, 16384, True)
                        if (observed is not None and
                                (expected_raw is None or
                                 observed[0] != expected_raw)):
                            raise StateError(
                                "transition-corrupt",
                                "legacy source changed before retirement", 4)
                        observed_sources.append((path, observed))
                    start_path, start_observed = observed_sources[0]
                    if start_observed is not None:
                        os.unlink(os.fsencode(start_path))
                        fsync_dir(agents)
                        _catalog_barrier(
                            "legacy-adopt", "post-first-source-delete")
                    heartbeat_path, heartbeat_observed = observed_sources[1]
                    if heartbeat_observed is not None:
                        os.unlink(os.fsencode(heartbeat_path))
                        fsync_dir(agents)
                    advance("did-source-retire")
                if phase == "did-source-retire":
                    advance("committed", txn_type="start",
                            committed_epoch=int(time.time()))
            finally:
                os.close(work_fd)
                os.close(audit_fd)
    env.update(state="adopted-legacy", trusted=True,
               tracking_capability="armed", idempotent=False)
    return env


def emit(value, code=0):
    print(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True))
    return code


PUBLIC_CONFIG = (
    ("ZYZ_WAIT_MAX_SEC",3600,1,86400,False),
    ("ZYZ_RECONNECT_ACK_SEC",600,1,86400,True),
    ("ZYZ_INFLIGHT_GRACE_SEC",1800,1,86400,False),
    ("ZYZ_RUNNING_NO_ACK_GRACE_SEC",600,1,86400,False),
    ("ZYZ_AGENT_LOCK_ACQUIRE_SEC",2,1,30,False),
    ("ZYZ_AGENT_LOCK_STALE_SEC",120,1,86400,False),
    ("ZYZ_WATCHDOG_NO_OUTPUT_SEC",1800,1,604800,True),
    ("ZYZ_NO_OUTPUT_MAX_PATHS",10000,1,1000000,False),
    ("ZYZ_NO_OUTPUT_MAX_FILE_BYTES",16777216,1,1073741824,False),
    ("ZYZ_NO_OUTPUT_MAX_TOTAL_BYTES",67108864,1,2147483647,False),
    ("ZYZ_NO_OUTPUT_MAX_INVENTORY_BYTES",33554432,1,2147483647,False),
    ("ZYZ_NO_OUTPUT_MAX_MANIFEST_BYTES",33554432,1,2147483647,False),
    ("ZYZ_NO_OUTPUT_MAX_RSS_BYTES",134217728,16777216,1073741824,False),
    ("ZYZ_NO_OUTPUT_MAX_TEMP_BYTES",134217728,1,2147483647,False),
    ("ZYZ_NO_OUTPUT_TEMP_STALE_SEC",120,1,86400,False),
    ("ZYZ_NO_OUTPUT_SNAPSHOT_TIMEOUT_SEC",8,1,8,False),
    ("ZYZ_SNAPSHOT_GC_INTERVAL_SEC",300,1,86400,True),
    ("ZYZ_SNAPSHOT_GC_MAX_ENTRIES_PER_PASS",10000,1,1000000,False),
    ("ZYZ_SNAPSHOT_GC_MAX_VERIFY_BYTES_PER_PASS",134217728,1,2147483647,False),
    ("ZYZ_SNAPSHOT_GC_MAX_SEC",2,1,30,False),
    ("ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES",536870912,33554432,2147483647,False),
    ("ZYZ_SNAPSHOT_GC_HARD_WATER_BYTES",1073741824,67108864,2147483647,False),
)


def _gc_config() -> dict:
    pair_names = {"ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES", "ZYZ_SNAPSHOT_GC_HARD_WATER_BYTES"}
    values = {name: env_uint(name, default, low, high, zero)
              for name, default, low, high, zero in PUBLIC_CONFIG
              if ((name.startswith("ZYZ_SNAPSHOT_GC_") or
                   name == "ZYZ_NO_OUTPUT_TEMP_STALE_SEC") and
                  name not in pair_names)}
    def pair_member(name: str, default: int, minimum: int) -> tuple[int, bool]:
        raw = os.environ.get(name)
        if raw is None:
            return default, True
        if not re.fullmatch(r"0|[1-9][0-9]*", raw):
            return default, False
        parsed = int(raw)
        return (parsed, True) if minimum <= parsed <= 2147483647 else (default, False)
    high, high_valid = pair_member("ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES", 536870912,
                                   max(33554432, CATALOG_GENESIS_FLOOR))
    hard, hard_valid = pair_member("ZYZ_SNAPSHOT_GC_HARD_WATER_BYTES", 1073741824, 67108864)
    if not high_valid or not hard_valid or high >= hard:
        print("zyz-worker: invalid snapshot GC watermark pair; using defaults", file=sys.stderr)
        high, hard = 536870912, 1073741824
    values["ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES"] = high
    values["ZYZ_SNAPSHOT_GC_HARD_WATER_BYTES"] = hard
    return values


def _gc_output(trigger=None, due=None, lock_acquired=False) -> dict:
    return {
        "ok": True, "state": "idle", "error": None, "trigger": trigger,
        "due": due, "lock_acquired": lock_acquired,
        "claims_scanned": 0, "claims_skipped": 0,
        "blocked_claims_known": None, "transactions_advanced": 0,
        "entries_verified": 0, "verification_bytes": 0,
        "entries_deleted": 0, "bytes_reclaimed": 0,
        "owned_bytes_before": None, "owned_bytes_after": None,
        "high_water": None, "hard_water": None,
        "receipts_anchored": 0, "next_gc_epoch": None,
    }


def _gc_now_epoch() -> int:
    raw = os.environ.get("ZYZ_TEST_GC_NOW_EPOCH")
    if raw is None:
        return int(time.time())
    if not re.fullmatch(r"0|[1-9][0-9]{0,9}", raw):
        raise StateError("invalid-request", "ZYZ_TEST_GC_NOW_EPOCH is invalid", 2)
    value = int(raw)
    if value > 2147483647:
        raise StateError("invalid-request", "ZYZ_TEST_GC_NOW_EPOCH is out of range", 2)
    return value


_GC_TEST_CLOCK_RAW = None
_GC_TEST_CLOCK_VALUES: list[float] = []
_GC_TEST_CLOCK_INDEX = 0


def _gc_test_monotonic_validate() -> tuple[str, list[int]] | None:
    """Validate the test-only monotonic sequence without consuming a value.

    Returns (raw, integers) for a present valid sequence, None when the env
    is absent, and raises the exact invalid-request StateError otherwise.
    Called eagerly at gc_step entry (before any catalog access) and reused
    by _gc_data_monotonic for the value-consumption path.
    """
    raw = os.environ.get("ZYZ_TEST_GC_MONOTONIC_NS_SEQUENCE")
    if raw is None:
        return None
    if len(raw) > MAX_ARG or not re.fullmatch(
            r"(?:0|[1-9][0-9]{0,18})(?:,(?:0|[1-9][0-9]{0,18}))*", raw):
        raise StateError("invalid-request",
                         "ZYZ_TEST_GC_MONOTONIC_NS_SEQUENCE is invalid", 2)
    integers = [int(value) for value in raw.split(",")]
    if (any(value > 9223372036854775807 for value in integers) or
            any(after < before for before, after in
                zip(integers, integers[1:]))):
        raise StateError("invalid-request",
                         "GC monotonic test sequence is not ordered", 2)
    return raw, integers


def _gc_data_monotonic() -> float:
    """Real monotonic clock, or an exact test-only dirty-data sequence."""
    global _GC_TEST_CLOCK_RAW, _GC_TEST_CLOCK_VALUES, _GC_TEST_CLOCK_INDEX
    validated = _gc_test_monotonic_validate()
    if validated is None:
        return time.monotonic()
    raw, integers = validated
    if raw != _GC_TEST_CLOCK_RAW:
        _GC_TEST_CLOCK_RAW = raw
        _GC_TEST_CLOCK_VALUES = [value / 1_000_000_000 for value in integers]
        _GC_TEST_CLOCK_INDEX = 0
    index = min(_GC_TEST_CLOCK_INDEX, len(_GC_TEST_CLOCK_VALUES) - 1)
    value = _GC_TEST_CLOCK_VALUES[index]
    _GC_TEST_CLOCK_INDEX += 1
    return value


def _gc_error(out: dict, state: str, code: str, message: str,
              retryable: bool, exit_code: int, ok: bool = False) -> tuple[dict, int]:
    out.update(ok=ok, state=state,
               error={"code": code, "message": message[:512], "retryable": retryable})
    return out, exit_code


def _gc_schedule_due(trigger: str, schedule: dict, root: dict, config: dict,
                     now: int, ordinary_work_known: bool = False) -> bool:
    if trigger in ("manual", "system-timer"):
        return True
    if config["ZYZ_SNAPSHOT_GC_INTERVAL_SEC"] == 0:
        return False
    ordinary_work = (ordinary_work_known or
                     root.get("claim_scan_due") is True or
                     root["blocked_claims_known"] > 0 or
                     root.get("pending_anchor_claim_sha256") is not None or
                     root.get("state") in
                        ("will-migration-quiesce", "migration-quiescing",
                         "migration-active", "will-migration-finish",
                         "migration-committed"))
    if _catalog_dense_signature_matches(root) and not ordinary_work:
        return False
    if ordinary_work:
        return True
    if root["owned_bytes"] >= config["ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES"]:
        return True
    if schedule.get("state") == "UNINITIALIZED":
        return True
    next_epoch = schedule.get("next_gc_epoch")
    return isinstance(next_epoch, int) and next_epoch <= now


def _gc_claim_sweep(container: Path, proof: dict, global_fd: int,
                    recovery_fd: int, limit: int = 64) -> dict:
    """Advance one frozen immutable claim-frame sweep by at most 64 claims."""
    root = proof["root_meta"]
    cutoff = root.get("sweep_cutoff_sequence", 0)
    first_generation = root.get("first_active_segment_generation", 1)
    generation = root.get("sweep_segment_generation", first_generation)
    start_generation = root.get("sweep_start_segment_generation", first_generation)
    sweep_generation = root.get("sweep_generation", 0)
    active_generation = root.get("active_segment_generation", 1)
    offset = root.get("sweep_offset", 0)
    if (not isinstance(cutoff, int) or cutoff < 0 or
            not isinstance(first_generation, int) or first_generation < 1 or
            not isinstance(generation, int) or generation < first_generation or
            not isinstance(start_generation, int) or start_generation < first_generation or
            not isinstance(sweep_generation, int) or sweep_generation < 0 or
            not isinstance(active_generation, int) or active_generation < generation or
            not isinstance(offset, int) or offset < 0):
        raise StateError("catalog-root-invalid", "claim sweep cursor is invalid", 4)
    new_sweep = cutoff == 0
    prior_next_gc_epoch = None if new_sweep else root.get("sweep_next_gc_epoch")
    if (prior_next_gc_epoch is not None and
            (not isinstance(prior_next_gc_epoch, int) or prior_next_gc_epoch < 0)):
        raise StateError("catalog-root-invalid",
                         "claim sweep future epoch is invalid", 4)
    if cutoff == 0:
        next_sequence = root.get("next_sequence")
        if not isinstance(next_sequence, int) or next_sequence < 1:
            raise StateError("catalog-root-invalid", "claim sweep cutoff source is invalid", 4)
        cutoff = next_sequence - 1
        if sweep_generation >= 2147483647:
            raise StateError("catalog-root-invalid", "claim sweep generation overflows", 4)
        sweep_generation += 1
        generation = first_generation
        start_generation = first_generation
        offset = 0
    candidates = []
    scanned = 0
    cursor = offset
    reached_cutoff = cutoff == 0
    members = proof.get("chain", {}).get("members", [])
    member_positions = {member["generation"]: position
                        for position, member in enumerate(members)}
    if (not members or len(member_positions) != len(members) or
            first_generation not in member_positions or
            active_generation not in member_positions or
            generation not in member_positions):
        raise StateError("catalog-root-invalid",
                         "claim sweep hybrid cursor is invalid", 4)
    while not reached_cutoff and scanned < limit:
        member_position = member_positions[generation]
        member = members[member_position]
        path = container / member["basename"]
        fd = os.open(os.fsencode(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            descriptor = _catalog_segment_descriptor(fd)[3][2]
            used = descriptor.get("committed_used_length")
            physical_generation = (0 if member.get("anchor_kind") ==
                                   "scratch-object" else generation)
            if (descriptor.get("segment_generation") != physical_generation or
                    descriptor.get("deterministic_basename") != path.name or
                    not isinstance(used, int) or used != member["used_length"] or
                    not 0 <= cursor <= used):
                raise StateError("catalog-root-invalid",
                                 "claim sweep segment cursor conflicts", 4)
            while cursor < used and scanned < limit:
                header = _catalog_pread_exact(fd, 20, cursor)
                if header[0:8] != b"ZYZFRM1\0":
                    raise StateError("catalog-root-invalid",
                                     "claim sweep frame magic is invalid", 4)
                total = struct.unpack_from(">I", header, 16)[0]
                if total < 64 or total % 8 or cursor + total > used:
                    raise StateError("catalog-root-invalid",
                                     "claim sweep frame length is invalid", 4)
                frame = _catalog_parse_frame(_catalog_pread_exact(fd, total, cursor))
                cursor += total
                if frame["kind"] != "claim":
                    continue
                payload = frame["payload"]
                sequence = payload.get("sequence")
                digest = payload.get("logical_key_sha256")
                pack_name = f"{digest}.claim-pack.v1"
                if (not isinstance(sequence, int) or sequence < 1 or
                        not isinstance(digest, str) or not HEX64.fullmatch(digest) or
                        payload.get("claim_pack_basename") != pack_name):
                    raise StateError("catalog-root-invalid",
                                     "claim sweep payload is invalid", 4)
                if sequence > cutoff:
                    cursor -= total
                    reached_cutoff = True
                    break
                scanned += 1
                # The deterministic pack basename is the immutable duplicate
                # and cancellation index. Absence suppresses a historical frame
                # in O(1); presence must authenticate its exact recovery cell.
                try:
                    pack_identity = _catalog_object_identity(
                        container, pack_name, CLAIM_PACK_SIZE)
                except FileNotFoundError:
                    continue
                immutable = _instance_pack_read(
                    container, digest, "claim", "IMMUTABLE_KEY")
                owner = _instance_pack_read(container, digest, "claim", "OWNER")
                observation = _instance_pack_read(
                    container, digest, "claim", "OBSERVATION")
                index = immutable.get("recovery_cell_index") \
                    if isinstance(immutable, dict) else None
                if not isinstance(index, int) or not 0 <= index < CATALOG_CELL_COUNT:
                    raise StateError("catalog-root-invalid",
                                     "claim immutable cell index is invalid", 4)
                selector = proof["root"][2][4096:5120]
                _, _, entry = _catalog_selected_entry(global_fd, selector, index)
                _, _, recovery = _catalog_selected_recovery(recovery_fd, entry, index)
                identities = {pack_name: pack_identity}
                identities_digest = _catalog_digest(
                    b"zyz-instance-object-identities-v1",
                    _catalog_json(identities)).hex()
                if (entry["state"] != 2 or recovery["state"] not in (3, 4, 5, 6) or
                        recovery["payload"].get("state") not in
                            ("ACTIVE_ACK", "DELTA_WILL", "DELTA_APPLIED", "FLUSH_ACKED") or
                        entry["fields"][0] != _catalog_instance_subject(f"claim.{digest}") or
                        recovery["payload"].get("subject_digest") !=
                            entry["fields"][0].hex() or
                        recovery["payload"].get("reservation_digest") !=
                            immutable.get("reservation_digest") or
                        recovery["payload"].get("object_identities_digest") !=
                            identities_digest or
                        immutable.get("logical_key_sha256") != digest or
                        immutable.get("pack_identity_digest") != pack_identity["digest"] or
                        payload.get("pack_identity_digest") != pack_identity["digest"] or
                        payload.get("reservation_digest") != immutable.get("reservation_digest") or
                        payload.get("recovery_cell_index") != index or
                        not isinstance(owner, dict) or not isinstance(observation, dict) or
                        observation.get("state") != "claimed" or
                        observation.get("sequence") != sequence or
                        observation.get("frame_digest") != frame["digest"].hex()):
                    raise StateError("catalog-root-invalid",
                                     "claim sweep pack binding conflicts", 4)
                candidates.append({"logical_key_sha256": digest, "sequence": sequence,
                                   "immutable": immutable, "owner": owner,
                                   "observation": observation})
            if reached_cutoff:
                pass
            elif cursor >= used and member_position + 1 < len(members):
                generation = members[member_position + 1]["generation"]
                cursor = 0
            elif cursor >= used:
                reached_cutoff = True
        finally:
            os.close(fd)
    updates = ({"sweep_cutoff_sequence": 0,
                "sweep_segment_generation": first_generation,
                "sweep_start_segment_generation": first_generation,
                "sweep_offset": 0, "sweep_next_gc_epoch": None,
                "sweep_generation": sweep_generation}
               if reached_cutoff else
               {"sweep_cutoff_sequence": cutoff,
                "sweep_segment_generation": generation,
                "sweep_start_segment_generation": start_generation,
                "sweep_offset": cursor,
                "sweep_next_gc_epoch": (None if new_sweep else
                                         root.get("sweep_next_gc_epoch")),
                "sweep_generation": sweep_generation})
    selector = proof["root"][2][4096:5120]
    successor = _catalog_root_successor(global_fd, recovery_fd, proof, selector,
                                        updates, "claim-sweep-cursor")
    return {"candidates": candidates, "claims_scanned": scanned,
            "more": not reached_cutoff, "root": successor["metadata"],
            "prior_next_gc_epoch": prior_next_gc_epoch}


def _gc_claim_classify(candidate: dict, now: int, ttl: int) -> tuple[str, int | None]:
    owner = candidate["owner"]
    created = owner.get("created_epoch")
    if not isinstance(created, int) or created < 0 or created > now:
        raise StateError("catalog-root-invalid", "claim owner epoch is invalid", 4)
    if owner.get("state") == "released-clean":
        return "eligible", None
    if owner.get("state") not in ("will-create", "did-create"):
        raise StateError("catalog-root-invalid", "claim owner state is invalid", 4)
    if (owner.get("hostname") != socket.gethostname() or
            not isinstance(owner.get("creator_pid"), int) or owner["creator_pid"] < 1 or
            not isinstance(owner.get("creator_boot_id"), str) or
            not isinstance(owner.get("creator_birth_token"), str)):
        raise StateError("catalog-root-invalid", "claim creator identity is invalid", 4)
    try:
        boot, birth = process_birth(owner["creator_pid"])
        live = (boot == owner["creator_boot_id"] and
                birth == owner["creator_birth_token"])
    except (OSError, ProcessLookupError):
        live = False
    eligible_epoch = created + ttl
    if eligible_epoch > 2147483647:
        raise StateError("catalog-root-invalid", "claim TTL epoch overflows", 4)
    if live:
        return "skip", max(now + 1, min(eligible_epoch, now + 300))
    if now < eligible_epoch:
        return "skip", eligible_epoch
    return "eligible", None


def _gc_claim_observe(container: Path, candidate: dict, now: int,
                      retry_epoch: int | None) -> None:
    """Persist bounded mutable observation state without appending a frame."""
    observation = candidate["observation"]
    successor = dict(observation, last_observed_epoch=now,
                     retry_epoch=retry_epoch, blocked=None)
    if successor != observation:
        _instance_pack_write(container, candidate["logical_key_sha256"],
                             "claim", "OBSERVATION", successor)


def _gc_claim_journal_phase(container: Path, digest: str, journal: dict,
                            phase: str) -> dict:
    journal = dict(journal, phase=phase)
    if len(_catalog_json(journal)) > 8192:
        raise StateError("catalog-root-invalid", "claim GC journal exceeds 8 KiB", 4)
    _instance_pack_write(container, digest, "claim", "GC_JOURNAL", journal)
    _catalog_barrier("catalog-claim-gc", phase)
    return journal


def _gc_snapshot_temp_plan(candidate: dict) -> dict | None:
    """Validate one private snapshot directory claim for bounded tree GC."""
    immutable=candidate["immutable"];owner=candidate["owner"]
    if (immutable.get("purpose") != "snapshot-temp" or
            owner.get("purpose") != "snapshot-temp" or
            owner.get("state") != "did-create"):
        return None
    instance_key=immutable.get("instance_key")
    targets=owner.get("target_identities")
    bounds=("max_paths","max_file_bytes","max_total_bytes","max_temp_bytes")
    limits={"max_paths":1000000,"max_file_bytes":1073741824,
            "max_total_bytes":2147483647,"max_temp_bytes":2147483647}
    if (not isinstance(instance_key,str) or not KEY_RE.fullmatch(instance_key) or
            owner.get("instance_key") != instance_key or
            owner.get("logical_key_sha256") !=
                candidate["logical_key_sha256"] or
            not isinstance(targets,list) or len(targets) != 1 or
            not isinstance(targets[0],dict) or
            set(targets[0]) != {"basename","type","dev","ino","nlink",
                                "mode","mount_id"} or
            targets[0].get("type") != "directory" or
            targets[0].get("basename") != owner.get("temp_basename") or
            not re.fullmatch(r"\.snapshot-tmp\.[0-9a-f]{64}",
                             str(owner.get("temp_basename"))) or
            type(targets[0].get("mode")) is not int or
            stat.S_IFMT(targets[0]["mode"]) not in (0,stat.S_IFDIR) or
            stat.S_IMODE(targets[0]["mode"]) != 0o700 or
            any(type(targets[0].get(name)) is not int or
                targets[0][name] < (1 if name == "nlink" else 0)
                for name in ("dev","ino","nlink")) or
            not isinstance(targets[0].get("mount_id"),str) or
            not targets[0]["mount_id"] or
            any(type(owner.get(name)) is not int or
                not 1 <= owner[name] <= limits[name]
                for name in bounds) or
            not (owner["max_file_bytes"] <= owner["max_total_bytes"] <=
                 owner["max_temp_bytes"]) or
            immutable.get("max_data_bytes") != owner["max_temp_bytes"]):
        raise StateError("catalog-root-invalid",
                         "snapshot temp claim bounds conflict",4)
    return {"claim_kind":"snapshot-temp","targets":targets,
            "target_set_digest":json_digest(targets),
            "tree_bounds":{name:owner[name] for name in bounds}}


def _gc_publication_staging_plan(container: Path,
                                 candidate: dict) -> dict | None:
    """Return an authenticated retired-publication target set, if complete.

    Publication OWNER records describe files that were once live.  They are
    not deletion authority by themselves: the instance work pack must first
    contain every matching retired intent.  A partially appended intent set is
    therefore healthy pending state, while malformed or conflicting fixed-slot
    data is corruption.
    """
    digest = candidate["logical_key_sha256"]
    immutable = candidate["immutable"]
    owner = candidate["owner"]
    instance_key = immutable.get("instance_key")
    if (immutable.get("purpose") != "snapshot-publication" or
            owner.get("purpose") != "snapshot-publication" or
            owner.get("state") != "did-create"):
        return None
    if (not isinstance(instance_key, str) or not KEY_RE.fullmatch(instance_key) or
            owner.get("instance_key") != instance_key or
            owner.get("logical_key_sha256") != digest):
        raise StateError("catalog-root-invalid",
                         "publication claim identity conflicts", 4)
    targets = owner.get("target_identities")
    target_fields = {"basename", "type", "size", "sha256", "dev", "ino",
                     "nlink", "mtime_ns", "mount_id"}
    if (not isinstance(targets, list) or not 1 <= len(targets) <= 16 or
            any(not isinstance(item, dict) or set(item) != target_fields
                for item in targets)):
        raise StateError("catalog-root-invalid",
                         "publication claim target identities are invalid", 4)
    target_by_digest = {json_digest(item): item for item in targets}
    if len(target_by_digest) != len(targets):
        raise StateError("catalog-root-invalid",
                         "publication claim target identities are duplicated", 4)
    if (sum(item["size"] for item in targets
            if isinstance(item.get("size"), int) and item["size"] >= 0) !=
            immutable.get("max_data_bytes") or
            any(item.get("type") != "regular" or
                not isinstance(item.get("size"), int) or item["size"] < 0 or
                not isinstance(item.get("sha256"), str) or
                not HEX64.fullmatch(item["sha256"]) or
                not isinstance(item.get("basename"), str) or
                not re.fullmatch(r"[A-Za-z0-9._-]{1,255}", item["basename"])
                for item in targets)):
        raise StateError("catalog-root-invalid",
                         "publication claim target bounds conflict", 4)
    terminal_source=False
    try:
        staging = _instance_pack_read(
            container, instance_key, "work", "TERMINAL_STAGING")
    except FileNotFoundError:
        terminal=_terminal_lookup_read_snapshot(container,instance_key)
        if (not isinstance(terminal,dict) or
                terminal.get("state") != "handoff-accepted"):
            return None
        staging=terminal.get("publication_staging")
        terminal_source=True
    if staging is None:
        return None
    if (not isinstance(staging, dict) or
            set(staging) != {"schema_version", "instance_key",
                             "publication_cleanup_intents"} or
            staging.get("schema_version") != 1 or
            staging.get("instance_key") != instance_key or
            not isinstance(staging.get("publication_cleanup_intents"), list) or
            len(staging["publication_cleanup_intents"]) > 16):
        raise StateError("catalog-root-invalid",
                         "publication terminal staging is invalid", 4)

    intent_fields = {"schema_version", "instance_key", "owner_generation",
                     "retired_index", "retired", "live_inventory_digest",
                     "created_epoch", "retired_claim_key_sha256",
                     "claim_state", "claim_receipt_digest"}
    retired_fields = {"purpose", "generation", "basename", "type", "size",
                      "sha256", "dev", "ino", "nlink", "mtime_ns",
                      "mount_id"}
    matching = []
    seen_intents = set()
    for intent in staging["publication_cleanup_intents"]:
        if (not isinstance(intent, dict) or set(intent) != intent_fields or
                intent.get("schema_version") != 1 or
                intent.get("instance_key") != instance_key or
                not isinstance(intent.get("owner_generation"), int) or
                not 1 <= intent["owner_generation"] <= 2147483647 or
                not isinstance(intent.get("retired_index"), int) or
                not 0 <= intent["retired_index"] < 16 or
                not isinstance(intent.get("created_epoch"), int) or
                not 0 <= intent["created_epoch"] <= 2147483647 or
                not isinstance(intent.get("live_inventory_digest"), str) or
                not HEX64.fullmatch(intent["live_inventory_digest"]) or
                intent.get("claim_state") not in ("pending","retired") or
                ((intent["claim_state"] == "pending" and
                  intent.get("claim_receipt_digest") is not None) or
                 (intent["claim_state"] == "retired" and
                  (not isinstance(intent.get("claim_receipt_digest"),str) or
                   not HEX64.fullmatch(intent["claim_receipt_digest"])))) or
                not isinstance(intent.get("retired"), dict) or
                set(intent["retired"]) != retired_fields):
            raise StateError("catalog-root-invalid",
                             "publication cleanup intent is invalid", 4)
        retired = intent["retired"]
        generation = retired.get("generation")
        if (not isinstance(generation, int) or
                not 1 <= generation < intent["owner_generation"] or
                retired.get("type") != "regular"):
            raise StateError("catalog-root-invalid",
                             "publication retired generation is invalid", 4)
        expected_digest, _ = _catalog_claim_key(
            "snapshot-publication", instance_key,
            f"publication-{generation}")
        if intent.get("retired_claim_key_sha256") != expected_digest:
            raise StateError("catalog-root-invalid",
                             "publication retired claim binding conflicts", 4)
        intent_digest = json_digest(intent)
        if intent_digest in seen_intents:
            raise StateError("catalog-root-invalid",
                             "publication cleanup intent is duplicated", 4)
        seen_intents.add(intent_digest)
        if expected_digest == digest and intent["claim_state"] == "pending":
            projected = {name: retired[name] for name in target_fields}
            matching.append((intent, intent_digest, projected))

    if not matching:
        return None
    projected_by_digest = {json_digest(row[2]): row for row in matching}
    # A subset is the normal crash set while publication_step is appending its
    # retired intents.  It is deliberately skipped rather than treated as
    # authorization to delete the subset.
    if set(projected_by_digest) != set(target_by_digest):
        if set(projected_by_digest).issubset(set(target_by_digest)):
            return None
        raise StateError("catalog-root-invalid",
                         "publication cleanup target set conflicts", 4)
    if len(projected_by_digest) != len(matching):
        raise StateError("catalog-root-invalid",
                         "publication cleanup target is duplicated", 4)
    owner_generations = {row[0]["owner_generation"] for row in matching}
    inventory_digests = {row[0]["live_inventory_digest"] for row in matching}
    if len(owner_generations) != 1 or len(inventory_digests) != 1:
        raise StateError("catalog-root-invalid",
                         "publication cleanup intent batch conflicts", 4)
    owner_generation = next(iter(owner_generations))
    if not terminal_source:
        live = _instance_pack_read(container, instance_key, "work", "LIVE_INVENTORY")
        if (not isinstance(live, dict) or
                set(live) != {"schema_version", "instance_key", "generation",
                              "active", "committed_epoch"} or
                live.get("schema_version") != 1 or
                live.get("instance_key") != instance_key or
                not isinstance(live.get("generation"), int) or
                live["generation"] < owner_generation or
                not isinstance(live.get("active"), list)):
            raise StateError("catalog-root-invalid",
                             "publication live inventory is invalid", 4)
        target_names = {item["basename"] for item in targets}
        if any(isinstance(item, dict) and item.get("basename") in target_names
               for item in live["active"]):
            return None
        if (live["generation"] == owner_generation and
                json_digest(live) != next(iter(inventory_digests))):
            raise StateError("catalog-root-invalid",
                             "publication cleanup inventory digest conflicts", 4)
    ordered = [projected_by_digest[json_digest(item)] for item in targets]
    return {"targets": targets,
            "intent_digests": [row[1] for row in ordered],
            "owner_generation": owner_generation,
            "live_inventory_digest": next(iter(inventory_digests)),
            "staging_digest": json_digest(staging)}


def _gc_claim_checkpoint_select(container: Path, digest: str,
                                key_bytes: bytes, initial: dict) -> dict:
    pointer=_instance_pack_read(container,digest,"claim","POINTER")
    slot=_instance_pack_read(container,digest,"claim","CHECKPOINT")
    if pointer is None and slot is None:
        return initial
    if (not isinstance(slot,dict) or slot.get("schema_version") != 1 or
            set(slot) != {"schema_version","current","previous"}):
        raise StateError("catalog-root-invalid","claim checkpoint pointer is invalid",4)
    def validate(value: dict | None) -> None:
        if value is None:
            return
        if (not isinstance(value,dict) or
                set(value) != {"schema_version","generation","cursor",
                               "hmac_sha256"} or
                value.get("schema_version") != 1 or
                not isinstance(value.get("generation"),int) or
                not 1 <= value["generation"] <= 2147483647):
            raise StateError("catalog-root-invalid",
                             "claim checkpoint record is invalid",4)
        body={name:item for name,item in value.items() if name != "hmac_sha256"}
        expected=hmac.new(
            key_bytes,_catalog_json(body),hashlib.sha256).hexdigest()
        if not hmac.compare_digest(str(value.get("hmac_sha256")),expected):
            raise StateError("catalog-root-invalid",
                             "claim checkpoint HMAC is invalid",4)
    validate(slot.get("current"));validate(slot.get("previous"))
    if pointer is None:
        # First-checkpoint crash after the inactive record write and before the
        # POINTER commit: the authenticated initial cursor is still selected.
        if (slot.get("previous") is not None or
                slot.get("current",{}).get("generation") != 1):
            raise StateError("catalog-root-invalid",
                             "claim unpointed checkpoint conflicts",4)
        return initial
    if (not isinstance(pointer,dict) or
            set(pointer) != {"schema_version","generation",
                             "checkpoint_digest"} or
            pointer.get("schema_version") != 1 or
            not isinstance(pointer.get("generation"),int) or
            pointer["generation"] < 1 or
            not isinstance(pointer.get("checkpoint_digest"),str) or
            not HEX64.fullmatch(pointer["checkpoint_digest"])):
        raise StateError("catalog-root-invalid","claim checkpoint pointer is invalid",4)
    selected=None
    for name in ("current","previous"):
        value=slot.get(name)
        if isinstance(value,dict) and value.get("generation") == pointer["generation"]:
            selected=value
            break
    if (selected is None or not hmac.compare_digest(
            json_digest(selected),pointer["checkpoint_digest"])):
        raise StateError("catalog-root-invalid","claim checkpoint selection conflicts",4)
    body={name:value for name,value in selected.items() if name != "hmac_sha256"}
    return body["cursor"]


def _gc_claim_checkpoint_advance(container: Path, digest: str, journal: dict,
                                 key_bytes: bytes, cursor: dict) -> dict:
    old_pointer=_instance_pack_read(container,digest,"claim","POINTER")
    old_slot=_instance_pack_read(container,digest,"claim","CHECKPOINT")
    old_generation=0 if old_pointer is None else old_pointer.get("generation")
    if not isinstance(old_generation,int) or old_generation < 0 or old_generation >= 2147483647:
        raise StateError("catalog-root-invalid","claim checkpoint generation is invalid",4)
    selected=_gc_claim_checkpoint_select(container,digest,key_bytes,{})
    if selected == cursor:
        if old_generation and journal.get("phase") in (
                f"will-pointer-{old_generation}",
                f"did-pointer-{old_generation}"):
            if journal.get("phase") == f"will-pointer-{old_generation}":
                journal=_gc_claim_journal_phase(
                    container,digest,journal,f"did-pointer-{old_generation}")
            journal=_gc_claim_journal_phase(
                container,digest,journal,f"did-checkpoint-{old_generation}")
        return journal
    previous=None
    if old_generation:
        if not isinstance(old_slot,dict):
            raise StateError("catalog-root-invalid","claim prior checkpoint is absent",4)
        previous=next((old_slot.get(name) for name in ("current","previous")
                       if isinstance(old_slot.get(name),dict) and
                       old_slot[name].get("generation") == old_generation),None)
        if previous is None:
            raise StateError("catalog-root-invalid","claim prior checkpoint conflicts",4)
    generation=old_generation+1
    body={"schema_version":1,"generation":generation,"cursor":cursor}
    current={**body,"hmac_sha256":hmac.new(
        key_bytes,_catalog_json(body),hashlib.sha256).hexdigest()}
    expected_slot={"schema_version":1,"current":current,
                   "previous":previous}
    if journal.get("phase") != f"will-checkpoint-{generation}":
        journal=_gc_claim_journal_phase(
            container,digest,journal,f"will-checkpoint-{generation}")
    if old_slot != expected_slot:
        _instance_pack_write(container,digest,"claim","CHECKPOINT",
                             expected_slot)
    _catalog_barrier("catalog-claim-gc",
                     f"CHECKPOINT-inactive-written-{generation}")
    journal=_gc_claim_journal_phase(
        container,digest,journal,f"will-pointer-{generation}")
    pointer={"schema_version":1,"generation":generation,
             "checkpoint_digest":json_digest(current)}
    if old_pointer != pointer:
        _instance_pack_write(container,digest,"claim","POINTER",pointer)
    _catalog_barrier("catalog-claim-gc",
                     f"POINTER-header-committed-{generation}")
    journal=_gc_claim_journal_phase(
        container,digest,journal,f"did-pointer-{generation}")
    return _gc_claim_journal_phase(
        container,digest,journal,f"did-checkpoint-{generation}")


def _gc_claim_process_publication_data(container: Path, candidate: dict,
                                       journal: dict, key_bytes: bytes,
                                       config: dict) -> tuple[dict,bool,dict]:
    digest=candidate["logical_key_sha256"]
    targets=journal.get("targets")
    if not isinstance(targets,list) or not 1 <= len(targets) <= 16:
        raise StateError("catalog-root-invalid","publication GC targets are invalid",4)
    initial={"target_index":0,"file_offset":0,
             "sha256_state":ResumableSHA256().export(),
             "verified_entries":0,"verified_bytes":0,
             "deleted_count":0,"bytes_reclaimed":0,
             "content_verified":False}
    cursor=_gc_claim_checkpoint_select(container,digest,key_bytes,initial)
    pointer=_instance_pack_read(container,digest,"claim","POINTER")
    pending_pointer=re.fullmatch(
        r"(?:will|did)-pointer-([1-9][0-9]*)",str(journal.get("phase")))
    if (pending_pointer and isinstance(pointer,dict) and
            pointer.get("generation") == int(pending_pointer.group(1))):
        journal=_gc_claim_checkpoint_advance(
            container,digest,journal,key_bytes,cursor)
    required={"target_index","file_offset","sha256_state","verified_entries",
              "verified_bytes","deleted_count","bytes_reclaimed",
              "content_verified"}
    integer_fields=("target_index","file_offset","verified_entries",
                    "verified_bytes","deleted_count","bytes_reclaimed")
    if (not isinstance(cursor,dict) or set(cursor) != required or
            any(not isinstance(cursor[name],int) or cursor[name] < 0
                for name in integer_fields) or
            not isinstance(cursor["content_verified"],bool) or
            not 0 <= cursor["target_index"] <= len(targets)):
        raise StateError("catalog-root-invalid","publication GC cursor is invalid",4)
    completed_sizes=sum(item["size"] for item in targets[:cursor["target_index"]])
    current_size=(targets[cursor["target_index"]]["size"]
                  if cursor["target_index"] < len(targets) else 0)
    if (cursor["deleted_count"] != cursor["target_index"] or
            cursor["bytes_reclaimed"] != completed_sizes or
            cursor["verified_entries"] != cursor["target_index"] +
                (1 if cursor["content_verified"] else 0) or
            cursor["verified_bytes"] != completed_sizes + cursor["file_offset"] or
            cursor["file_offset"] > current_size or
            (cursor["content_verified"] and cursor["file_offset"] != current_size) or
            (cursor["target_index"] == len(targets) and
             (cursor["file_offset"] != 0 or cursor["content_verified"]))):
        raise StateError("catalog-root-invalid",
                         "publication GC cursor accounting conflicts",4)
    ResumableSHA256.restore(cursor["sha256_state"],cursor["file_offset"])
    entries_budget=config["ZYZ_SNAPSHOT_GC_MAX_ENTRIES_PER_PASS"]
    bytes_budget=config["ZYZ_SNAPSHOT_GC_MAX_VERIFY_BYTES_PER_PASS"]
    deadline=_gc_data_monotonic()+config["ZYZ_SNAPSHOT_GC_MAX_SEC"]
    effects={"entries_verified":0,"verification_bytes":0,
             "entries_deleted":0,"bytes_reclaimed":0}
    agents=container.parent/"agents"
    agents_fd=os.open(os.fsencode(agents),os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|
                      getattr(os,"O_NOFOLLOW",0)|getattr(os,"O_CLOEXEC",0))
    try:
        while cursor["target_index"] < len(targets):
            if entries_budget <= 0 or _gc_data_monotonic() >= deadline:
                return journal,False,effects
            item=targets[cursor["target_index"]]
            if item.get("type") != "regular":
                raise StateError("catalog-root-invalid",
                                 "published GC target type is unsupported",4)
            name=os.fsencode(item["basename"]); fd=-1
            phase=journal.get("phase")
            index=cursor["target_index"]
            will_delete=f"will-delete-entry-{index}"
            did_delete=f"did-delete-entry-{index}"
            after_delete=phase in (will_delete,did_delete)
            try:
                fd=os.open(name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0)|
                           getattr(os,"O_CLOEXEC",0),dir_fd=agents_fd)
            except FileNotFoundError:
                if not after_delete:
                    raise StateError("catalog-root-invalid",
                                     "published GC target disappeared",4)
            if fd >= 0:
                st=os.fstat(fd);mount=runtime_native._mount_id_at(agents_fd,name,fd)
                if ((st.st_size,st.st_dev,st.st_ino,st.st_nlink,st.st_mtime_ns,mount) !=
                        (item["size"],item["dev"],item["ino"],item["nlink"],
                         item["mtime_ns"],item["mount_id"])):
                    raise StateError("catalog-root-invalid",
                                     "published GC target identity changed",4)
                if not cursor["content_verified"]:
                    if bytes_budget <= 0:
                        os.close(fd);fd=-1
                        return journal,False,effects
                    hasher=ResumableSHA256.restore(
                        cursor["sha256_state"],cursor["file_offset"])
                    os.lseek(fd,cursor["file_offset"],os.SEEK_SET)
                    consumed=0
                    while (cursor["file_offset"] < st.st_size and
                           consumed < bytes_budget and
                           _gc_data_monotonic() < deadline):
                        chunk=os.read(fd,min(131072,st.st_size-cursor["file_offset"],
                                             bytes_budget-consumed))
                        if not chunk:
                            raise StateError("catalog-root-invalid",
                                             "published GC target ended early",4)
                        hasher.update(chunk);cursor["file_offset"]+=len(chunk)
                        consumed+=len(chunk)
                    cursor["sha256_state"]=hasher.export()
                    cursor["verified_bytes"]+=consumed
                    effects["verification_bytes"]+=consumed
                    bytes_budget-=consumed
                    if cursor["file_offset"] < st.st_size:
                        journal=_gc_claim_checkpoint_advance(
                            container,digest,journal,key_bytes,cursor)
                        os.close(fd);fd=-1
                        return journal,False,effects
                    if hasher.hexdigest() != item["sha256"]:
                        raise StateError("catalog-root-invalid",
                                         "published GC content digest changed",4)
                    journal=_gc_claim_journal_phase(
                        container,digest,journal,
                        f"will-content-verified-{index}")
                    cursor["content_verified"]=True
                    cursor["verified_entries"]+=1
                    effects["entries_verified"]+=1
                    journal=_gc_claim_checkpoint_advance(
                        container,digest,journal,key_bytes,cursor)
                    _catalog_barrier(
                        "catalog-claim-gc",
                        f"content-verified-slot-committed-{index}")
                    journal=_gc_claim_journal_phase(
                        container,digest,journal,
                        f"did-content-verified-{index}")
                elif phase not in (will_delete,did_delete):
                    journal=_gc_claim_journal_phase(
                        container,digest,journal,
                        f"did-content-verified-{index}")
                if journal.get("phase") == did_delete:
                    raise StateError("catalog-root-invalid",
                                     "published GC deleted target reappeared",4)
                next_cursor=dict(
                    cursor,target_index=index+1,file_offset=0,
                    sha256_state=ResumableSHA256().export(),
                    deleted_count=cursor["deleted_count"]+1,
                    bytes_reclaimed=cursor["bytes_reclaimed"]+item["size"],
                    content_verified=False)
                if journal.get("phase") != will_delete:
                    journal=_gc_claim_journal_phase(
                        container,digest,
                        dict(journal,delete_after_cursor=next_cursor),
                        will_delete)
                elif journal.get("delete_after_cursor") != next_cursor:
                    raise StateError("catalog-root-invalid",
                                     "publication GC delete after-set conflicts",4)
                os.close(fd);fd=-1
                os.unlink(name,dir_fd=agents_fd);os.fsync(agents_fd)
                _catalog_barrier(
                    "catalog-claim-gc",f"physical-unlink-{index}")
                effects["entries_deleted"]+=1
                effects["bytes_reclaimed"]+=item["size"]
            else:
                next_cursor=journal.get("delete_after_cursor")
                expected_next=dict(
                    cursor,target_index=index+1,file_offset=0,
                    sha256_state=ResumableSHA256().export(),
                    deleted_count=cursor["deleted_count"]+1,
                    bytes_reclaimed=cursor["bytes_reclaimed"]+item["size"],
                    content_verified=False)
                if next_cursor != expected_next:
                    raise StateError("catalog-root-invalid",
                                     "publication GC missing delete after-set",4)
            journal=_gc_claim_journal_phase(
                container,digest,journal,did_delete)
            cursor=next_cursor
            entries_budget-=1
            journal=_gc_claim_checkpoint_advance(
                container,digest,journal,key_bytes,cursor)
        journal=dict(journal,deleted_count=cursor["deleted_count"],
                     bytes_reclaimed=cursor["bytes_reclaimed"],
                     verified_entries=cursor["verified_entries"],
                     verified_bytes=cursor["verified_bytes"])
        return journal,True,effects
    finally:
        os.close(agents_fd)


def _gc_snapshot_tree_next_leaf(agents_fd: int, target: dict) -> dict:
    """Find one descriptor-verified postorder leaf without retaining a tree."""
    root_name=os.fsencode(target["basename"])
    root_fd=os.open(root_name,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|
                    getattr(os,"O_NOFOLLOW",0)|getattr(os,"O_CLOEXEC",0),
                    dir_fd=agents_fd)
    stack=[(root_fd,b"")]
    try:
        root_st=os.fstat(root_fd)
        root_mount=runtime_native._mount_id_at(
            agents_fd,root_name,root_fd)
        if ((root_st.st_dev,root_st.st_ino,stat.S_IFMT(root_st.st_mode),
             stat.S_IMODE(root_st.st_mode),root_mount) !=
                (target["dev"],target["ino"],stat.S_IFDIR,
                 stat.S_IMODE(target["mode"]),target["mount_id"]) or
                root_st.st_nlink < 1):
            raise StateError("catalog-root-invalid",
                             "snapshot temp root identity changed",4)
        while stack:
            fd,rel=stack[-1]
            first=None
            with os.scandir(fd) as entries:
                for entry in entries:
                    name=os.fsencode(entry.name)
                    if name in (b".",b"..") or b"/" in name or b"\0" in name:
                        raise StateError("catalog-root-invalid",
                                         "snapshot temp child name is invalid",4)
                    first=name
                    break
            if first is None:
                if not rel:
                    return {"root_empty":True,"root_mount_id":root_mount,
                            "identity":{"type":"directory","mode":root_st.st_mode,
                                        "rdev":root_st.st_rdev,"dev":root_st.st_dev,
                                        "ino":root_st.st_ino,"nlink":root_st.st_nlink,
                                        "size":root_st.st_size,
                                        "allocated_bytes":max(
                                            root_st.st_size,
                                            getattr(root_st,"st_blocks",0)*512),
                                        "mtime_ns":root_st.st_mtime_ns,
                                        "ctime_ns":root_st.st_ctime_ns,
                                        "mount_id":root_mount}}
                st=os.fstat(fd)
                return {"root_empty":False,"path_b64":base64.b64encode(rel).decode(),
                        "identity":{"type":"directory","mode":st.st_mode,
                                    "rdev":st.st_rdev,"dev":st.st_dev,
                                    "ino":st.st_ino,"nlink":st.st_nlink,
                                    "size":st.st_size,
                                    "allocated_bytes":max(
                                        st.st_size,getattr(st,"st_blocks",0)*512),
                                    "mtime_ns":st.st_mtime_ns,
                                    "ctime_ns":st.st_ctime_ns,
                                    "mount_id":root_mount}}
            st=os.stat(first,dir_fd=fd,follow_symlinks=False)
            mount=runtime_native._mount_id_at(fd,first)
            if mount != root_mount or st.st_nlink < 1:
                raise StateError("catalog-root-invalid",
                                 "snapshot temp child crosses mount or is unlinked",4)
            child_rel=first if not rel else rel+b"/"+first
            if stat.S_ISDIR(st.st_mode):
                child=os.open(first,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|
                              getattr(os,"O_NOFOLLOW",0)|
                              getattr(os,"O_CLOEXEC",0),dir_fd=fd)
                rebound=os.fstat(child)
                if ((rebound.st_dev,rebound.st_ino,stat.S_IFMT(rebound.st_mode)) !=
                        (st.st_dev,st.st_ino,stat.S_IFDIR) or
                        runtime_native._mount_id_at(fd,first,child) != root_mount):
                    os.close(child)
                    raise StateError("catalog-root-invalid",
                                     "snapshot temp directory changed",4)
                stack.append((child,child_rel))
                continue
            kind=("regular" if stat.S_ISREG(st.st_mode) else
                  "symlink" if stat.S_ISLNK(st.st_mode) else
                  "fifo" if stat.S_ISFIFO(st.st_mode) else
                  "socket" if stat.S_ISSOCK(st.st_mode) else
                  "block" if stat.S_ISBLK(st.st_mode) else
                  "char" if stat.S_ISCHR(st.st_mode) else None)
            if kind is None:
                raise StateError("catalog-root-invalid",
                                 "snapshot temp child type is unsupported",4)
            return {"root_empty":False,
                    "path_b64":base64.b64encode(child_rel).decode(),
                    "identity":{"type":kind,"mode":st.st_mode,
                                "rdev":st.st_rdev,"dev":st.st_dev,
                                "ino":st.st_ino,"nlink":st.st_nlink,
                                "size":st.st_size,
                                "allocated_bytes":max(
                                    st.st_size,getattr(st,"st_blocks",0)*512),
                                "mtime_ns":st.st_mtime_ns,
                                "ctime_ns":st.st_ctime_ns,
                                "mount_id":mount}}
    finally:
        for fd,_ in reversed(stack):
            try:os.close(fd)
            except OSError:pass


def _gc_snapshot_tree_decode_path(value: str) -> bytes:
    try:
        raw=base64.b64decode(value,validate=True)
    except Exception:
        raise StateError("catalog-root-invalid",
                         "snapshot temp cursor path encoding is invalid",4)
    if (base64.b64encode(raw).decode() != value or raw.startswith(b"/") or
            b"\0" in raw or len(raw) > 4096 or
            (raw and any(part in (b"",b".",b"..")
                         for part in raw.split(b"/")))):
        raise StateError("catalog-root-invalid",
                         "snapshot temp cursor path is invalid",4)
    return raw


def _gc_snapshot_tree_root_fd(agents_fd: int, target: dict) -> tuple[int,str]:
    name=os.fsencode(target["basename"])
    fd=os.open(name,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|
               getattr(os,"O_NOFOLLOW",0)|getattr(os,"O_CLOEXEC",0),
               dir_fd=agents_fd)
    st=os.fstat(fd);mount=runtime_native._mount_id_at(agents_fd,name,fd)
    if ((st.st_dev,st.st_ino,stat.S_IFMT(st.st_mode),
         stat.S_IMODE(st.st_mode),mount) !=
            (target["dev"],target["ino"],stat.S_IFDIR,
             stat.S_IMODE(target["mode"]),target["mount_id"]) or
            st.st_nlink < 1):
        os.close(fd)
        raise StateError("catalog-root-invalid",
                         "snapshot temp root identity changed",4)
    return fd,mount


def _gc_snapshot_tree_open_parent(agents_fd: int, target: dict,
                                  path_b64: str) -> tuple[int,bytes,str]:
    """Open the exact raw-path parent without following a descendant symlink."""
    raw=_gc_snapshot_tree_decode_path(path_b64)
    if not raw:
        return os.dup(agents_fd),os.fsencode(target["basename"]),target["mount_id"]
    fd,mount=_gc_snapshot_tree_root_fd(agents_fd,target)
    try:
        components=raw.split(b"/")
        for component in components[:-1]:
            child=os.open(component,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|
                          getattr(os,"O_NOFOLLOW",0)|
                          getattr(os,"O_CLOEXEC",0),dir_fd=fd)
            observed=os.fstat(child)
            if (not stat.S_ISDIR(observed.st_mode) or observed.st_nlink < 1 or
                    runtime_native._mount_id_at(fd,component,child) != mount):
                os.close(child)
                raise StateError("catalog-root-invalid",
                                 "snapshot temp cursor ancestor changed",4)
            os.close(fd);fd=child
        return fd,components[-1],mount
    except Exception:
        os.close(fd)
        raise


def _gc_snapshot_tree_identity_matches(st: os.stat_result, mount: str,
                                       expected: dict) -> bool:
    fields={"type","mode","rdev","dev","ino","nlink","size",
            "allocated_bytes","mtime_ns","ctime_ns","mount_id"}
    kind=("directory" if stat.S_ISDIR(st.st_mode) else
          "regular" if stat.S_ISREG(st.st_mode) else
          "symlink" if stat.S_ISLNK(st.st_mode) else
          "fifo" if stat.S_ISFIFO(st.st_mode) else
          "socket" if stat.S_ISSOCK(st.st_mode) else
          "block" if stat.S_ISBLK(st.st_mode) else
          "char" if stat.S_ISCHR(st.st_mode) else None)
    allocated=max(st.st_size,getattr(st,"st_blocks",0)*512)
    return (isinstance(expected,dict) and set(expected) == fields and
            kind is not None and
            (kind,st.st_mode,st.st_rdev,st.st_dev,st.st_ino,st.st_nlink,
             st.st_size,allocated,st.st_mtime_ns,st.st_ctime_ns,mount) ==
            (expected["type"],expected["mode"],expected["rdev"],
             expected["dev"],expected["ino"],expected["nlink"],
             expected["size"],expected["allocated_bytes"],
             expected["mtime_ns"],expected["ctime_ns"],
             expected["mount_id"]))


def _gc_snapshot_tree_hash_leaf(agents_fd: int, target: dict, path_b64: str,
                                expected: dict, offset: int,
                                hasher: ResumableSHA256, budget: int,
                                deadline: float) -> tuple[int,int]:
    if expected.get("type") != "regular":
        raise StateError("catalog-root-invalid",
                         "snapshot temp non-regular leaf entered hashing",4)
    parent,name,mount=_gc_snapshot_tree_open_parent(agents_fd,target,path_b64)
    leaf=-1
    try:
        leaf=os.open(name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0)|
                     getattr(os,"O_NONBLOCK",0)|getattr(os,"O_CLOEXEC",0),
                     dir_fd=parent)
        before=os.fstat(leaf)
        if not _gc_snapshot_tree_identity_matches(
                before,runtime_native._mount_id_at(parent,name,leaf),expected):
            raise StateError("catalog-root-invalid",
                             "snapshot temp regular leaf identity changed",4)
        if not isinstance(offset,int) or not 0 <= offset <= before.st_size:
            raise StateError("catalog-root-invalid",
                             "snapshot temp file offset is invalid",4)
        os.lseek(leaf,offset,os.SEEK_SET);consumed=0
        while (offset < before.st_size and consumed < budget and
               _gc_data_monotonic() < deadline):
            chunk=os.read(leaf,min(131072,before.st_size-offset,budget-consumed))
            if not chunk:
                raise StateError("catalog-root-invalid",
                                 "snapshot temp regular leaf ended early",4)
            hasher.update(chunk);offset+=len(chunk);consumed+=len(chunk)
        after=os.fstat(leaf)
        if not _gc_snapshot_tree_identity_matches(after,mount,expected):
            raise StateError("catalog-root-invalid",
                             "snapshot temp regular leaf changed during hashing",4)
        return offset,consumed
    finally:
        if leaf >= 0:os.close(leaf)
        os.close(parent)


def _gc_snapshot_tree_delete_evidence(agents_fd: int, target: dict,
                                      path_b64: str, expected: dict) -> dict:
    parent,name,mount=_gc_snapshot_tree_open_parent(agents_fd,target,path_b64)
    try:
        st=os.stat(name,dir_fd=parent,follow_symlinks=False)
        leaf_mount=runtime_native._mount_id_at(parent,name)
        if leaf_mount != mount or not _gc_snapshot_tree_identity_matches(
                st,leaf_mount,expected):
            raise StateError("catalog-root-invalid",
                             "snapshot temp delete leaf identity changed",4)
        pst=os.fstat(parent)
        prior={"mode":pst.st_mode,"dev":pst.st_dev,"ino":pst.st_ino,
               "nlink":pst.st_nlink,
               "mount_id":runtime_native._mount_id_at(parent,b".",parent)}
        # Linux directory link counts track child directories; APFS reports a
        # directory-entry count and therefore decrements for every child kind.
        decrement=(expected["type"] == "directory" or sys.platform == "darwin")
        after=dict(prior,nlink=prior["nlink"]-(1 if decrement else 0))
        if after["nlink"] < 1:
            raise StateError("catalog-root-invalid",
                             "snapshot temp delete parent link count is invalid",4)
        return {"path_b64":path_b64,
                "leaf_identity_digest":json_digest(expected),
                "parent_prior":prior,"parent_after":after}
    finally:
        os.close(parent)


def _gc_snapshot_tree_delete_leaf(agents_fd: int, target: dict,
                                  path_b64: str, expected: dict,
                                  evidence: dict) -> tuple[bool,int]:
    expected_evidence_fields={"path_b64","leaf_identity_digest",
                              "parent_prior","parent_after"}
    if (not isinstance(evidence,dict) or
            set(evidence) != expected_evidence_fields or
            evidence.get("path_b64") != path_b64 or
            evidence.get("leaf_identity_digest") != json_digest(expected)):
        raise StateError("catalog-root-invalid",
                         "snapshot temp delete evidence conflicts",4)
    parent,name,mount=_gc_snapshot_tree_open_parent(agents_fd,target,path_b64)
    try:
        pst=os.fstat(parent)
        observed_parent={"mode":pst.st_mode,"dev":pst.st_dev,"ino":pst.st_ino,
                         "nlink":pst.st_nlink,
                         "mount_id":runtime_native._mount_id_at(parent,b".",parent)}
        try:
            st=os.stat(name,dir_fd=parent,follow_symlinks=False)
        except FileNotFoundError:
            if observed_parent != evidence["parent_after"]:
                raise StateError("catalog-root-invalid",
                                 "snapshot temp delete after-set conflicts",4)
            return False,0
        if observed_parent != evidence["parent_prior"]:
            raise StateError("catalog-root-invalid",
                             "snapshot temp delete parent prior changed",4)
        leaf_mount=runtime_native._mount_id_at(parent,name)
        if leaf_mount != mount or not _gc_snapshot_tree_identity_matches(
                st,leaf_mount,expected):
            raise StateError("catalog-root-invalid",
                             "snapshot temp delete leaf prior changed",4)
        if expected["type"] == "directory":
            os.rmdir(name,dir_fd=parent)
        else:
            os.unlink(name,dir_fd=parent)
        os.fsync(parent)
        try:
            os.stat(name,dir_fd=parent,follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise StateError("catalog-root-invalid",
                             "snapshot temp leaf remained after deletion",4)
        pst=os.fstat(parent)
        after={"mode":pst.st_mode,"dev":pst.st_dev,"ino":pst.st_ino,
               "nlink":pst.st_nlink,
               "mount_id":runtime_native._mount_id_at(parent,b".",parent)}
        if after != evidence["parent_after"]:
            raise StateError("catalog-root-invalid",
                             "snapshot temp delete parent after-set conflicts",4)
        reclaimed=(expected["allocated_bytes"]
                   if expected["type"] == "regular" else 0)
        return True,reclaimed
    finally:
        os.close(parent)


def _gc_claim_process_snapshot_temp_data(container: Path, candidate: dict,
                                         journal: dict, key_bytes: bytes,
                                         config: dict) -> tuple[dict,bool,dict]:
    """Delete one claimed private tree with a bounded authenticated cursor."""
    digest=candidate["logical_key_sha256"]
    targets=journal.get("targets");bounds=journal.get("tree_bounds")
    if (not isinstance(targets,list) or len(targets) != 1 or
            not isinstance(bounds,dict) or
            set(bounds) != {"max_paths","max_file_bytes",
                            "max_total_bytes","max_temp_bytes"}):
        raise StateError("catalog-root-invalid",
                         "snapshot temp GC plan is invalid",4)
    target=targets[0]
    initial={"active_path_b64":None,"active_identity":None,
             "file_offset":0,"sha256_state":ResumableSHA256().export(),
             "verification_pass":0,"first_sha256":None,
             "content_verified":False,"verified_entries":0,
             "verified_bytes":0,"deleted_count":0,"bytes_reclaimed":0,
             "processed_entries":0,"processed_regular_bytes":0,
             "processed_temp_bytes":0,"root_deleted":False}
    cursor=_gc_claim_checkpoint_select(container,digest,key_bytes,initial)
    pointer=_instance_pack_read(container,digest,"claim","POINTER")
    pending_pointer=re.fullmatch(
        r"(?:will|did)-pointer-([1-9][0-9]*)",str(journal.get("phase")))
    if (pending_pointer and isinstance(pointer,dict) and
            pointer.get("generation") == int(pending_pointer.group(1))):
        journal=_gc_claim_checkpoint_advance(
            container,digest,journal,key_bytes,cursor)
    required=set(initial)
    integers=("file_offset","verification_pass","verified_entries",
              "verified_bytes","deleted_count","bytes_reclaimed",
              "processed_entries","processed_regular_bytes",
              "processed_temp_bytes")
    if (not isinstance(cursor,dict) or set(cursor) != required or
            any(not isinstance(cursor[name],int) or cursor[name] < 0
                for name in integers) or
            not isinstance(cursor["content_verified"],bool) or
            not isinstance(cursor["root_deleted"],bool) or
            cursor["verification_pass"] not in (0,1,2) or
            (cursor["active_path_b64"] is None) !=
                (cursor["active_identity"] is None)):
        raise StateError("catalog-root-invalid",
                         "snapshot temp GC cursor is invalid",4)
    if cursor["active_path_b64"] is not None:
        _gc_snapshot_tree_decode_path(cursor["active_path_b64"])
        if not isinstance(cursor["active_identity"],dict):
            raise StateError("catalog-root-invalid",
                             "snapshot temp active identity is invalid",4)
    elif (cursor["file_offset"] != 0 or cursor["verification_pass"] != 0 or
          cursor["first_sha256"] is not None or cursor["content_verified"] or
          cursor["sha256_state"] != initial["sha256_state"]):
        raise StateError("catalog-root-invalid",
                         "snapshot temp inactive cursor conflicts",4)
    active=cursor["active_identity"]
    if active is not None:
        active_kind=active.get("type")
        active_size=active.get("size")
        if (active_kind not in ("directory","regular","symlink","fifo",
                               "socket","block","char") or
                not isinstance(active_size,int) or active_size < 0):
            raise StateError("catalog-root-invalid",
                             "snapshot temp active leaf schema is invalid",4)
        if active_kind == "regular":
            expected_verified=(active_size+cursor["file_offset"]
                               if cursor["verification_pass"] == 2 else
                               cursor["file_offset"])
            if (cursor["verification_pass"] not in (1,2) or
                    (cursor["verification_pass"] == 1 and
                     cursor["first_sha256"] is not None) or
                    (cursor["verification_pass"] == 2 and
                     (not isinstance(cursor["first_sha256"],str) or
                      not HEX64.fullmatch(cursor["first_sha256"]))) or
                    cursor["file_offset"] > active_size or
                    (cursor["content_verified"] and
                     (cursor["verification_pass"] != 2 or
                      cursor["file_offset"] != active_size))):
                raise StateError("catalog-root-invalid",
                                 "snapshot temp regular cursor conflicts",4)
        else:
            expected_verified=0
            if (cursor["verification_pass"] != 0 or
                    cursor["first_sha256"] is not None or
                    cursor["file_offset"] != 0 or
                    cursor["sha256_state"] != initial["sha256_state"] or
                    not cursor["content_verified"]):
                raise StateError("catalog-root-invalid",
                                 "snapshot temp payload-free cursor conflicts",4)
    else:
        expected_verified=0
    active_verified=1 if active is not None and cursor["content_verified"] else 0
    active_root=(cursor["active_path_b64"] == "" if active is not None else False)
    entry_ceiling=bounds["max_paths"]+2
    if (cursor["processed_entries"] > entry_ceiling or
            cursor["processed_regular_bytes"] > bounds["max_temp_bytes"] or
            cursor["processed_temp_bytes"] > bounds["max_temp_bytes"] or
            cursor["bytes_reclaimed"] != cursor["processed_temp_bytes"] or
            cursor["deleted_count"] != cursor["processed_entries"]+
                (1 if cursor["root_deleted"] else 0) or
            cursor["verified_entries"] != cursor["deleted_count"]+active_verified or
            cursor["verified_bytes"] !=
                2*cursor["processed_regular_bytes"]+expected_verified or
            cursor["root_deleted"] and active is not None or
            active_root and active.get("type") != "directory"):
        raise StateError("catalog-root-invalid",
                         "snapshot temp GC cursor accounting conflicts",4)
    ResumableSHA256.restore(cursor["sha256_state"],cursor["file_offset"])
    entries_budget=config["ZYZ_SNAPSHOT_GC_MAX_ENTRIES_PER_PASS"]
    bytes_budget=config["ZYZ_SNAPSHOT_GC_MAX_VERIFY_BYTES_PER_PASS"]
    deadline=_gc_data_monotonic()+config["ZYZ_SNAPSHOT_GC_MAX_SEC"]
    effects={"entries_verified":0,"verification_bytes":0,
             "entries_deleted":0,"bytes_reclaimed":0}
    agents=container.parent/"agents"
    agents_fd=os.open(os.fsencode(agents),os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|
                      getattr(os,"O_NOFOLLOW",0)|getattr(os,"O_CLOEXEC",0))

    def pass_pending() -> tuple[dict,bool,dict]:
        nonlocal journal
        journal=_gc_claim_journal_phase(
            container,digest,journal,"will-pass-checkpoint")
        journal=_gc_claim_checkpoint_advance(
            container,digest,journal,key_bytes,cursor)
        journal=_gc_claim_journal_phase(
            container,digest,journal,"did-pass-checkpoint")
        return journal,False,effects

    try:
        while not cursor["root_deleted"]:
            if entries_budget <= 0 or _gc_data_monotonic() >= deadline:
                return pass_pending()
            if cursor["active_path_b64"] is None:
                try:
                    leaf=_gc_snapshot_tree_next_leaf(agents_fd,target)
                except FileNotFoundError:
                    raise StateError("catalog-root-invalid",
                                     "snapshot temp root disappeared",4)
                root=leaf["root_empty"]
                path_b64="" if root else leaf["path_b64"]
                identity=leaf["identity"]
                if (not root and cursor["processed_entries"] >= entry_ceiling):
                    raise StateError("catalog-root-invalid",
                                     "snapshot temp path ceiling exceeded",4)
                if identity["type"] == "regular":
                    if (identity["allocated_bytes"] >
                            bounds["max_temp_bytes"]-
                            cursor["processed_temp_bytes"]):
                        raise StateError("catalog-root-invalid",
                                         "snapshot temp byte ceiling exceeded",4)
                    verification_pass=1;content_verified=False
                    verified_entries=cursor["verified_entries"]
                else:
                    verification_pass=0;content_verified=True
                    verified_entries=cursor["verified_entries"]+1
                cursor=dict(cursor,active_path_b64=path_b64,
                            active_identity=identity,file_offset=0,
                            sha256_state=ResumableSHA256().export(),
                            verification_pass=verification_pass,
                            first_sha256=None,
                            content_verified=content_verified,
                            verified_entries=verified_entries)
                journal=_gc_claim_checkpoint_advance(
                    container,digest,journal,key_bytes,cursor)
                _catalog_barrier(
                    "catalog-claim-gc",
                    f"tree-cursor-checkpoint-{cursor['deleted_count']}")
                if content_verified:
                    effects["entries_verified"]+=1
            if _gc_data_monotonic() >= deadline:
                return pass_pending()
            identity=cursor["active_identity"]
            index=cursor["deleted_count"]
            if identity["type"] == "regular" and not cursor["content_verified"]:
                if bytes_budget <= 0:
                    return pass_pending()
                hasher=ResumableSHA256.restore(
                    cursor["sha256_state"],cursor["file_offset"])
                offset,consumed=_gc_snapshot_tree_hash_leaf(
                    agents_fd,target,cursor["active_path_b64"],identity,
                    cursor["file_offset"],hasher,bytes_budget,deadline)
                cursor=dict(cursor,file_offset=offset,
                            sha256_state=hasher.export(),
                            verified_bytes=cursor["verified_bytes"]+consumed)
                bytes_budget-=consumed
                effects["verification_bytes"]+=consumed
                if offset < identity["size"]:
                    journal=_gc_claim_checkpoint_advance(
                        container,digest,journal,key_bytes,cursor)
                    return pass_pending()
                computed=hasher.hexdigest()
                if cursor["verification_pass"] == 1:
                    journal=_gc_claim_journal_phase(
                        container,digest,journal,
                        f"will-content-commitment-{index}")
                    cursor=dict(cursor,file_offset=0,
                                sha256_state=ResumableSHA256().export(),
                                verification_pass=2,first_sha256=computed)
                    journal=_gc_claim_checkpoint_advance(
                        container,digest,journal,key_bytes,cursor)
                    _catalog_barrier(
                        "catalog-claim-gc",
                        f"first-content-commitment-{index}")
                    journal=_gc_claim_journal_phase(
                        container,digest,journal,
                        f"did-content-commitment-{index}")
                    if bytes_budget <= 0 or _gc_data_monotonic() >= deadline:
                        return pass_pending()
                    continue
                if (cursor["verification_pass"] != 2 or
                        not hmac.compare_digest(
                            computed,str(cursor["first_sha256"]))):
                    raise StateError("catalog-root-invalid",
                                     "snapshot temp content commitment changed",4)
                journal=_gc_claim_journal_phase(
                    container,digest,journal,
                    f"will-content-verified-{index}")
                cursor=dict(cursor,content_verified=True,
                            verified_entries=cursor["verified_entries"]+1)
                journal=_gc_claim_checkpoint_advance(
                    container,digest,journal,key_bytes,cursor)
                _catalog_barrier(
                    "catalog-claim-gc",f"second-content-verified-{index}")
                journal=_gc_claim_journal_phase(
                    container,digest,journal,
                    f"did-content-verified-{index}")
                effects["entries_verified"]+=1
            elif not cursor["content_verified"]:
                raise StateError("catalog-root-invalid",
                                 "snapshot temp unverified leaf reached delete",4)
            elif (journal.get("phase") not in
                  (f"will-delete-entry-{index}",f"did-delete-entry-{index}") and
                  not str(journal.get("phase")).startswith(
                      "did-content-verified-")):
                journal=_gc_claim_journal_phase(
                    container,digest,journal,
                    f"did-content-verified-{index}")
            if _gc_data_monotonic() >= deadline:
                return pass_pending()
            root_entry=cursor["active_path_b64"] == ""
            regular=identity["type"] == "regular"
            next_cursor=dict(
                cursor,active_path_b64=None,active_identity=None,file_offset=0,
                sha256_state=ResumableSHA256().export(),verification_pass=0,
                first_sha256=None,content_verified=False,
                deleted_count=cursor["deleted_count"]+1,
                bytes_reclaimed=cursor["bytes_reclaimed"]+
                    (identity["allocated_bytes"] if regular else 0),
                processed_entries=cursor["processed_entries"]+
                    (0 if root_entry else 1),
                processed_regular_bytes=cursor["processed_regular_bytes"]+
                    (identity["size"] if regular else 0),
                processed_temp_bytes=cursor["processed_temp_bytes"]+
                    (identity["allocated_bytes"] if regular else 0),
                root_deleted=root_entry)
            will=f"will-delete-entry-{index}";did=f"did-delete-entry-{index}"
            phase=journal.get("phase")
            if phase not in (will,did):
                evidence=_gc_snapshot_tree_delete_evidence(
                    agents_fd,target,cursor["active_path_b64"],identity)
                journal=_gc_claim_journal_phase(
                    container,digest,
                    dict(journal,tree_delete_evidence=evidence,
                         delete_after_cursor=next_cursor),will)
            elif (journal.get("delete_after_cursor") != next_cursor or
                  not isinstance(journal.get("tree_delete_evidence"),dict)):
                raise StateError("catalog-root-invalid",
                                 "snapshot temp delete after-set conflicts",4)
            performed,reclaimed=_gc_snapshot_tree_delete_leaf(
                agents_fd,target,cursor["active_path_b64"],identity,
                journal["tree_delete_evidence"])
            if performed:
                barrier=("tree-root-delete" if root_entry else
                         f"tree-directory-rmdir-{index}"
                         if identity["type"] == "directory" else
                         f"tree-leaf-unlink-{index}")
                _catalog_barrier("catalog-claim-gc",barrier)
                effects["entries_deleted"]+=1
                effects["bytes_reclaimed"]+=reclaimed
            journal=_gc_claim_journal_phase(container,digest,journal,did)
            cursor=next_cursor;entries_budget-=1
            journal=_gc_claim_checkpoint_advance(
                container,digest,journal,key_bytes,cursor)
        journal=dict(journal,deleted_count=cursor["deleted_count"],
                     bytes_reclaimed=cursor["bytes_reclaimed"],
                     verified_entries=cursor["verified_entries"],
                     verified_bytes=cursor["verified_bytes"])
        return journal,True,effects
    finally:
        os.close(agents_fd)


def _gc_claim_advance(container: Path, candidate: dict, now: int,
                      config: dict) -> dict:
    """Advance one eligible claim through bounded data work and A receipt."""
    digest = candidate["logical_key_sha256"]
    owner = candidate["owner"]
    journal = _instance_pack_read(container, digest, "claim", "GC_JOURNAL")
    if journal is None:
        if owner.get("state") == "released-clean":
            plan={"claim_kind":"zero","targets":[],"intent_digests":[],
                  "staging_digest":None,"live_inventory_digest":None,
                  "tree_bounds":None}
        else:
            publication=_gc_publication_staging_plan(container,candidate)
            snapshot_temp=_gc_snapshot_temp_plan(candidate)
            if publication is not None:
                plan={"claim_kind":"snapshot-publication",**publication,
                      "tree_bounds":None}
            elif snapshot_temp is not None:
                plan={**snapshot_temp,"intent_digests":[],
                      "staging_digest":None,"live_inventory_digest":None}
            else:
                return {"state":"skipped","journal":None,"receipt":None,
                        "effects":{"entries_verified":0,"verification_bytes":0,
                                   "entries_deleted":0,"bytes_reclaimed":0}}
        key_bytes = secrets.token_bytes(32)
        journal = {"schema_version": 1, "phase": "prepared",
                   "logical_key_sha256": digest,
                   "instance_key": candidate["immutable"]["instance_key"],
                   "owner_digest": json_digest(owner),
                   "claim_kind":plan["claim_kind"],
                   "targets":plan["targets"],
                   "target_set_digest":json_digest(plan["targets"]),
                   "intent_digests":plan["intent_digests"],
                   "staging_digest":plan["staging_digest"],
                   "live_inventory_digest":plan["live_inventory_digest"],
                   "tree_bounds":plan["tree_bounds"],
                   "key_b64": base64.b64encode(key_bytes).decode(),
                   "key_digest": hashlib.sha256(key_bytes).hexdigest(),
                   "quarantine_count": 0, "deleted_count": 0,
                   "bytes_reclaimed": 0,
                   "verified_entries": 0, "verified_bytes": 0,
                   "created_epoch": now}
        _instance_pack_write(container, digest, "claim", "GC_JOURNAL", journal)
        _catalog_barrier("catalog-claim-gc", "prepared")
    if (journal.get("schema_version") != 1 or
            journal.get("logical_key_sha256") != digest or
            journal.get("instance_key") != candidate["immutable"]["instance_key"] or
            journal.get("owner_digest") != json_digest(owner) or
            journal.get("quarantine_count") != 0 or
            journal.get("claim_kind") not in
                ("zero","snapshot-publication","snapshot-temp") or
            not isinstance(journal.get("targets"),list) or
            json_digest(journal["targets"]) != journal.get("target_set_digest") or
            (journal.get("claim_kind") == "zero" and journal["targets"]) or
            (journal.get("claim_kind") == "snapshot-temp" and
             (_gc_snapshot_temp_plan(candidate) !=
              {"claim_kind":"snapshot-temp","targets":journal["targets"],
               "target_set_digest":journal["target_set_digest"],
               "tree_bounds":journal.get("tree_bounds")}))):
        raise StateError("catalog-root-invalid", "claim GC journal binding conflicts", 4)
    try:
        key_bytes = base64.b64decode(journal["key_b64"], validate=True)
    except Exception:
        raise StateError("catalog-root-invalid", "claim GC key encoding is invalid", 4)
    if len(key_bytes) != 32 or hashlib.sha256(key_bytes).hexdigest() != journal.get("key_digest"):
        raise StateError("catalog-root-invalid", "claim GC key digest conflicts", 4)
    phase = journal.get("phase")
    if phase == "prepared":
        journal = _gc_claim_journal_phase(container, digest, journal, "will-key-prepare")
        phase = journal["phase"]
    if phase == "will-key-prepare":
        prepared_key = {"schema_version": 1, "state": "prepared",
                        "key_b64": journal["key_b64"],
                        "key_digest": journal["key_digest"]}
        observed = _instance_pack_read(container, digest, "claim", "KEY")
        if observed is None:
            _instance_pack_write(container, digest, "claim", "KEY", prepared_key)
        elif observed != prepared_key:
            raise StateError("catalog-root-invalid", "claim prepared KEY conflicts", 4)
        _catalog_barrier("catalog-claim-gc", "KEY-header-committed")
        journal = _gc_claim_journal_phase(container, digest, journal, "did-key-prepare")
        phase = journal["phase"]
    if phase == "did-key-prepare":
        journal = _gc_claim_journal_phase(container, digest, journal, "will-key-commit")
        phase = journal["phase"]
    if phase == "will-key-commit":
        active_key = {"schema_version": 1, "state": "active",
                      "key_b64": journal["key_b64"],
                      "key_digest": journal["key_digest"]}
        observed = _instance_pack_read(container, digest, "claim", "KEY")
        if observed != active_key:
            _instance_pack_write(container, digest, "claim", "KEY", active_key)
        _catalog_barrier("catalog-claim-gc", "KEY-state-committed")
        journal = _gc_claim_journal_phase(container, digest, journal, "did-key-commit")
        phase = journal["phase"]
    effects={"entries_verified":0,"verification_bytes":0,
             "entries_deleted":0,"bytes_reclaimed":0}
    if phase not in ("will-receipt","did-receipt","waiting-receipt-anchor"):
        if journal["claim_kind"] == "snapshot-publication":
            journal,complete,effects=_gc_claim_process_publication_data(
                container,candidate,journal,key_bytes,config)
            if not complete:
                return {"state":"pending","journal":journal,"receipt":None,
                        "effects":effects}
        elif journal["claim_kind"] == "snapshot-temp":
            journal,complete,effects=_gc_claim_process_snapshot_temp_data(
                container,candidate,journal,key_bytes,config)
            if not complete:
                return {"state":"pending","journal":journal,"receipt":None,
                        "effects":effects}
        else:
            journal=dict(journal,deleted_count=0,bytes_reclaimed=0,
                         verified_entries=0,verified_bytes=0)
        journal = _gc_claim_journal_phase(
            container, digest, dict(journal, receipt_epoch=now), "will-receipt")
        phase = journal["phase"]
    totals=("deleted_count","bytes_reclaimed","verified_entries","verified_bytes")
    if (not isinstance(journal.get("receipt_epoch"), int) or
            journal["receipt_epoch"] < 0 or
            any(not isinstance(journal.get(name),int) or journal[name] < 0
                for name in totals)):
        raise StateError("catalog-root-invalid", "claim receipt epoch is invalid", 4)
    receipt_body = {"schema_version": 1, "state": "waiting-receipt-anchor",
                    "logical_key_sha256": digest,
                    "instance_key": journal["instance_key"],
                    "owner_digest": journal["owner_digest"],
                    "claim_kind":journal["claim_kind"],
                    "target_set_digest":journal["target_set_digest"],
                    "deleted_count":journal["deleted_count"],
                    "bytes_reclaimed":journal["bytes_reclaimed"],
                    "verified_entries":journal["verified_entries"],
                    "verified_bytes":journal["verified_bytes"],
                    "result": "compacted",
                    "committed_epoch": journal["receipt_epoch"]}
    receipt = {**receipt_body, "hmac_sha256": hmac.new(
        key_bytes, _catalog_json(receipt_body), hashlib.sha256).hexdigest()}
    if phase == "will-receipt":
        observed = _instance_pack_read(container, digest, "claim", "RECEIPT")
        if observed is None:
            _instance_pack_write(container, digest, "claim", "RECEIPT", receipt)
        elif observed != receipt:
            raise StateError("catalog-root-invalid", "claim RECEIPT conflicts", 4)
        _catalog_barrier("catalog-claim-gc", "RECEIPT-header-committed")
        journal = _gc_claim_journal_phase(
            container, digest, dict(journal, receipt_digest=json_digest(receipt)),
            "did-receipt")
        phase = journal["phase"]
    if phase == "did-receipt":
        journal = _gc_claim_journal_phase(
            container, digest, journal, "waiting-receipt-anchor")
    elif phase != "waiting-receipt-anchor":
        raise StateError("catalog-root-invalid", "claim GC phase is invalid", 4)
    observed_receipt = _instance_pack_read(container, digest, "claim", "RECEIPT")
    if observed_receipt != receipt or journal.get("receipt_digest") != json_digest(receipt):
        raise StateError("catalog-root-invalid", "claim receipt waiting state conflicts", 4)
    return {"state":"waiting-receipt-anchor","journal":journal,
            "receipt":receipt,"effects":effects}


def _gc_retire_publication_staging(container: Path, journal: dict) -> str | None:
    """Mark the exact parent intents claim-retired before pack release."""
    if journal.get("claim_kind") != "snapshot-publication":
        return None
    instance_key=journal.get("instance_key")
    requested=journal.get("intent_digests")
    receipt_digest=journal.get("receipt_digest")
    if (not isinstance(instance_key,str) or not KEY_RE.fullmatch(instance_key) or
            not isinstance(requested,list) or not requested or
            len(set(requested)) != len(requested) or
            any(not isinstance(value,str) or not HEX64.fullmatch(value)
                for value in requested) or
            not isinstance(receipt_digest,str) or
            not HEX64.fullmatch(receipt_digest)):
        raise StateError("catalog-root-invalid",
                         "publication parent retirement binding is invalid",4)
    def retire(staging: dict) -> dict:
        if (not isinstance(staging,dict) or
                set(staging) != {"schema_version","instance_key",
                                 "publication_cleanup_intents"} or
                staging.get("schema_version") != 1 or
                staging.get("instance_key") != instance_key or
                not isinstance(staging.get("publication_cleanup_intents"),list)):
            raise StateError("catalog-root-invalid",
                             "publication parent staging is invalid",4)
        located={};successor_rows=[]
        for row in staging["publication_cleanup_intents"]:
            if not isinstance(row,dict):
                raise StateError("catalog-root-invalid",
                                 "publication parent intent is invalid",4)
            if row.get("claim_state") == "pending":
                prior_digest=json_digest(row)
                successor_row=dict(
                    row,claim_state="retired",
                    claim_receipt_digest=receipt_digest)
            elif row.get("claim_state") == "retired":
                prior_digest=json_digest(dict(
                    row,claim_state="pending",claim_receipt_digest=None))
                if (prior_digest in requested and
                        row.get("claim_receipt_digest") != receipt_digest):
                    raise StateError("catalog-root-invalid",
                                     "publication parent receipt conflicts",4)
                successor_row=row
            else:
                raise StateError("catalog-root-invalid",
                                 "publication parent intent state is invalid",4)
            if prior_digest in requested:
                if prior_digest in located:
                    raise StateError("catalog-root-invalid",
                                     "publication parent intent is duplicated",4)
                located[prior_digest]=True
                successor_rows.append(successor_row)
            else:
                successor_rows.append(row)
        if set(located) != set(requested):
            raise StateError("catalog-root-invalid",
                             "publication parent intent disappeared",4)
        return {**staging,"publication_cleanup_intents":successor_rows}

    lock_path=container/f"{instance_key}.lock.v1"
    try:
        os.lstat(os.fsencode(lock_path))
        instance_present=True
    except FileNotFoundError:
        instance_present=False
    if instance_present:
        with InstanceFlock(container,instance_key):
            fd=_instance_open_pack(container,instance_key,"work",True)
            try:
                staging=_instance_pack_read_fd(
                    fd,"work",instance_key,"TERMINAL_STAGING")
                successor=retire(staging)
                if successor != staging:
                    _instance_pack_write_fd(
                        fd,"work",instance_key,"TERMINAL_STAGING",successor,
                        "catalog-claim-gc")
            finally:
                os.close(fd)
    else:
        with TerminalFlock(container):
            fd=_terminal_open_pack(container,True)
            try:
                index,selected,_=_terminal_find_cell(fd,instance_key)
                if index is None or selected is None:
                    raise StateError("catalog-root-invalid",
                                     "publication terminal parent is absent",4)
                current=selected[3][2]
                if current.get("state") != "handoff-accepted":
                    raise StateError("catalog-root-invalid",
                                     "publication terminal parent is invalid",4)
                staging=current.get("publication_staging")
                successor=retire(staging)
                if successor != staging:
                    _terminal_write_cell(
                        fd,selected,index,
                        {**current,"publication_staging":successor},
                        "publication-parent-retired")
            finally:
                os.close(fd)
    _catalog_barrier("catalog-claim-gc","publication-parent-retired")
    return json_digest(successor)


def _gc_consume_pending_anchor(container: Path, config: dict) -> dict | None:
    """Run terminal-first B/C for the one ROOT-addressable pending receipt."""
    def finish_release(digest: str, request: int) -> dict:
        released = _catalog_complete_instance_release(
            container, f"claim.{digest}", request, config)
        # Keep the ROOT pointer until the terminal cell no longer owns the
        # external ACK/release transition.  A crash before this commit is then
        # replayable from the still-addressable claim digest.
        _terminal_retire_claim_anchor(container, digest)
        with CatalogFlock(container):
            release_proof = _catalog_validate_genesis(container)
            os.close(release_proof.pop("global_fd"))
            pending = release_proof["root_meta"].get("pending_anchor_claim_sha256")
            if pending is not None and pending != digest:
                raise StateError("catalog-root-invalid",
                                 "pending anchor pointer changed after release", 4)
            if pending is not None:
                pointer_global = os.open(
                    os.fsencode(container / ".catalog-global-pack.v1"),
                    os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
                pointer_recovery = os.open(
                    os.fsencode(container / ".catalog-recovery-pack.v1"),
                    os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                try:
                    _catalog_root_successor(
                        pointer_global, pointer_recovery, release_proof,
                        release_proof["root"][2][4096:5120],
                        {"pending_anchor_claim_sha256": None},
                        "anchor-pointer-consumed")
                finally:
                    os.close(pointer_global); os.close(pointer_recovery)
        return released

    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        os.close(proof.pop("global_fd"))
        digest = proof["root_meta"].get("pending_anchor_claim_sha256")
        if digest is None:
            return None
        if not isinstance(digest, str) or not HEX64.fullmatch(digest):
            raise StateError("catalog-root-invalid", "pending anchor pointer is invalid", 4)
        try:
            immutable = _instance_pack_read(container, digest, "claim", "IMMUTABLE_KEY")
            journal = _instance_pack_read(container, digest, "claim", "GC_JOURNAL")
            receipt = _instance_pack_read(container, digest, "claim", "RECEIPT")
            key_record = _instance_pack_read(container, digest, "claim", "KEY")
            observed_ack = _instance_pack_read(container, digest, "claim", "ANCHOR_ACK")
        except FileNotFoundError:
            immutable = journal = receipt = key_record = observed_ack = None
        if immutable is None:
            # The selected recovery free-will is the sole legal authority after
            # physical unlink. It can finish CELL/ROOT free without pack data.
            release_after_unlink = True
            release_ready = False
        else:
            release_after_unlink = False
            receipt_digest = json_digest(receipt) if isinstance(receipt, dict) else None
            try:
                receipt_key=base64.b64decode(
                    journal.get("key_b64",""),validate=True)
            except Exception:
                receipt_key=b""
            receipt_body=({name:value for name,value in receipt.items()
                           if name != "hmac_sha256"}
                          if isinstance(receipt,dict) else {})
            receipt_hmac=(hmac.new(
                receipt_key,_catalog_json(receipt_body),hashlib.sha256).hexdigest()
                          if len(receipt_key) == 32 else None)
            common_valid = (
                isinstance(immutable, dict) and isinstance(journal, dict) and
                isinstance(immutable.get("reservation_bytes"), int) and
                immutable["reservation_bytes"] >= CLAIM_PACK_SIZE and
                isinstance(receipt, dict) and
                set(receipt) == set(receipt_body) | {"hmac_sha256"} and
                hmac.compare_digest(str(receipt.get("hmac_sha256")),
                                    str(receipt_hmac)) and
                receipt.get("state") == "waiting-receipt-anchor" and
                receipt.get("logical_key_sha256") == digest and
                receipt.get("instance_key") == immutable.get("instance_key") and
                receipt.get("owner_digest") == journal.get("owner_digest") and
                receipt.get("target_set_digest") ==
                    journal.get("target_set_digest") and
                receipt.get("claim_kind") == journal.get("claim_kind") and
                all(isinstance(receipt.get(name),int) and receipt[name] >= 0
                    for name in ("deleted_count","bytes_reclaimed",
                                 "verified_entries","verified_bytes")) and
                journal.get("logical_key_sha256") == digest and
                journal.get("receipt_digest") == receipt_digest and
                isinstance(key_record, dict) and
                key_record.get("key_digest") == journal.get("key_digest"))
            ack_valid = (
                isinstance(observed_ack, dict) and
                observed_ack.get("state") == "did-anchor-ack" and
                observed_ack.get("logical_key_sha256") == digest and
                observed_ack.get("receipt_digest") == receipt_digest)
            release_ready = (
                common_valid and journal.get("phase") == "will-claim-release" and
                key_record.get("state") == "retired" and
                ack_valid and
                journal.get("anchor_ack_digest") == json_digest(observed_ack))
            waiting_anchor = (
                common_valid and
                ((journal.get("phase") == "waiting-receipt-anchor" and
                  (key_record.get("state") == "active" or
                   (key_record.get("state") == "retired" and ack_valid))) or
                 (journal.get("phase") == "did-key-delete" and
                  key_record.get("state") == "retired" and ack_valid) or
                 (journal.get("phase") in
                    ("will-parent-retire","did-parent-retire") and
                  key_record.get("state") == "retired" and ack_valid)))
            if not release_ready and not waiting_anchor:
                raise StateError("catalog-root-invalid",
                                 "pending receipt anchor binding conflicts", 4)
        instance_key = immutable.get("instance_key") if immutable is not None else None
        if immutable is not None and (
                not isinstance(instance_key, str) or not KEY_RE.fullmatch(instance_key)):
            raise StateError("catalog-root-invalid", "pending anchor instance key is invalid", 4)

    if release_after_unlink:
        released = finish_release(digest, 0)
        return {"state": "released", "logical_key_sha256": digest,
                "entries_deleted": released.get("entries_deleted", 0),
                "bytes_reclaimed": released.get("bytes_reclaimed", 0),
                "release": released}
    if release_ready:
        released = finish_release(digest, immutable["reservation_bytes"])
        return {"state": "released", "logical_key_sha256": digest,
                "entries_deleted": released.get("entries_deleted", 0),
                "bytes_reclaimed": released.get("bytes_reclaimed", 0),
                "release": released}

    # B phase: terminal-first lookup remains authoritative after every instance
    # object has been physically released. No catalog lock is held here.
    receipt_digest = json_digest(receipt)
    terminal_anchor = _terminal_anchor_receipt(
        container, instance_key, digest, receipt_digest)
    if terminal_anchor is not None:
        ack = {"schema_version": 1, "state": "did-anchor-ack",
               "logical_key_sha256": digest,
               "receipt_digest": receipt_digest, "route": "terminal",
               "terminal_cell_index": terminal_anchor["cell_index"],
               "terminal_cell_generation": terminal_anchor["cell_generation"],
               "terminal_cell_digest": terminal_anchor["cell_digest"],
               "terminal_anchor_digest": json_digest(terminal_anchor["anchor"])}
        observed_ack = _instance_pack_read(container, digest, "claim", "ANCHOR_ACK")
        if observed_ack is None:
            _instance_pack_write(container, digest, "claim", "ANCHOR_ACK", ack)
        elif observed_ack != ack:
            raise StateError("catalog-root-invalid", "claim terminal ACK conflicts", 4)
        _catalog_barrier("catalog-claim-gc", "ANCHOR_ACK-header-committed")
    else:
        with InstanceFlock(container, instance_key):
            audit_fd = _instance_open_pack(container, instance_key, "audit", True)
            work_fd = _instance_open_pack(container, instance_key, "work", False)
            try:
                identity = _instance_pack_read_fd(
                    audit_fd, "audit", instance_key, "IDENTITY")
                done = _instance_pack_read_fd(audit_fd, "audit", instance_key, "DONE")
                finalized = _instance_pack_read_fd(
                    audit_fd, "audit", instance_key, "FINALIZED")
                latch = _instance_pack_read_fd(
                    work_fd, "work", instance_key, "TERMINAL_HANDOFF")
                if not isinstance(identity, dict):
                    raise StateError("catalog-root-invalid", "anchor instance identity is absent", 4)
                if latch is not None or done is not None or finalized is not None:
                    # F is the routing point. A reserved/not-yet-Published cell is
                    # helped by the terminal owner on the next lifecycle pass;
                    # this path must never append a post-F audit generation.
                    return {"state": "pending-terminal-route",
                            "logical_key_sha256": digest}
                anchor_record = {"schema_version": 1, "state": "anchored",
                                 "logical_key_sha256": digest,
                                 "receipt_digest": receipt_digest,
                                 "route": "instance", "instance_key": instance_key}
                observed_anchor = _instance_pack_read_fd(
                    audit_fd, "audit", instance_key, "GC_ANCHOR")
                if observed_anchor is None:
                    _instance_pack_write_fd(
                        audit_fd, "audit", instance_key, "GC_ANCHOR", anchor_record)
                elif observed_anchor != anchor_record:
                    raise StateError("catalog-root-invalid", "instance GC anchor conflicts", 4)
                _catalog_barrier("catalog-claim-gc", "GC_ANCHOR-slot-committed")
                ack = {"schema_version": 1, "state": "did-anchor-ack",
                       "logical_key_sha256": digest,
                       "receipt_digest": receipt_digest, "route": "instance",
                       "instance_anchor_digest": json_digest(anchor_record)}
                observed_ack = _instance_pack_read(
                    container, digest, "claim", "ANCHOR_ACK")
                if observed_ack is None:
                    _instance_pack_write(
                        container, digest, "claim", "ANCHOR_ACK", ack)
                elif observed_ack != ack:
                    raise StateError("catalog-root-invalid", "claim anchor ACK conflicts", 4)
                _catalog_barrier("catalog-claim-gc", "ANCHOR_ACK-header-committed")
            finally:
                os.close(work_fd)
                os.close(audit_fd)

    # C phase: consume ACK and retire the key under only the catalog lock.
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        os.close(proof.pop("global_fd"))
        if proof["root_meta"].get("pending_anchor_claim_sha256") != digest:
            raise StateError("catalog-root-invalid", "pending anchor pointer changed", 4)
        observed_ack = _instance_pack_read(container, digest, "claim", "ANCHOR_ACK")
        if observed_ack != ack:
            raise StateError("catalog-root-invalid", "claim anchor ACK disappeared", 4)
        retired_key = {"schema_version": 1, "state": "retired",
                       "key_digest": journal["key_digest"]}
        observed_key = _instance_pack_read(container, digest, "claim", "KEY")
        if observed_key != retired_key:
            _instance_pack_write(container, digest, "claim", "KEY", retired_key)
        _catalog_barrier("catalog-claim-gc", "KEY-retired-header-committed")
        journal = _gc_claim_journal_phase(
            container,digest,journal,"did-key-delete")
        _catalog_claim_owner_release_clean_locked(
            container,digest,int(time.time()))
        journal = _gc_claim_journal_phase(
            container, digest,
            dict(journal, anchor_ack_digest=json_digest(ack)),
            "will-parent-retire")
    parent_digest=_gc_retire_publication_staging(container,journal)
    with CatalogFlock(container):
        proof=_catalog_validate_genesis(container)
        os.close(proof.pop("global_fd"))
        if proof["root_meta"].get("pending_anchor_claim_sha256") != digest:
            raise StateError("catalog-root-invalid",
                             "pending anchor changed during parent retirement",4)
        observed_journal=_instance_pack_read(
            container,digest,"claim","GC_JOURNAL")
        if observed_journal != journal:
            raise StateError("catalog-root-invalid",
                             "claim journal changed during parent retirement",4)
        journal=_gc_claim_journal_phase(
            container,digest,
            dict(journal,parent_staging_digest=parent_digest),
            "did-parent-retire")
        journal=_gc_claim_journal_phase(
            container,digest,journal,"will-claim-release")
    released = finish_release(digest, immutable["reservation_bytes"])
    return {"state": "released", "logical_key_sha256": digest,
            "entries_deleted": released.get("entries_deleted", 0),
            "bytes_reclaimed": released.get("bytes_reclaimed", 0),
            "release": released}


def _catalog_commit_root_updates(container: Path, proof: dict, updates: dict,
                                 barrier: str) -> tuple[dict, bool]:
    with CatalogFlock(container):
        current = _catalog_validate_genesis(container)
        os.close(current.pop("global_fd"))
        effective = {key: value for key, value in updates.items()
                     if current["root_meta"].get(key) != value}
        if not effective:
            return current, False
        global_fd = os.open(os.fsencode(container / ".catalog-global-pack.v1"),
                            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        recovery_fd = os.open(os.fsencode(container / ".catalog-recovery-pack.v1"),
                              os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            _catalog_root_successor(
                global_fd, recovery_fd, current,
                current["root"][2][4096:5120], effective, barrier)
        finally:
            os.close(global_fd); os.close(recovery_fd)
        refreshed = _catalog_validate_genesis(container)
        os.close(refreshed.pop("global_fd"))
        return refreshed, True


def _catalog_commit_idle_schedule(container: Path, proof: dict, config: dict, now: int,
                                  next_epoch: int | None = None,
                                  reason: str = "completed-pass",
                                  root_updates: dict | None = None) -> dict:
    interval = config["ZYZ_SNAPSHOT_GC_INTERVAL_SEC"]
    if interval == 0 and next_epoch is None and not root_updates:
        return proof
    with CatalogFlock(container):
        proof = _catalog_validate_genesis(container)
        os.close(proof.pop("global_fd"))
        global_path = container / ".catalog-global-pack.v1"
        fd = os.open(os.fsencode(global_path), os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            root = proof["root"]
            schedule = proof["schedule"]
            next_epoch = now + interval if next_epoch is None else next_epoch
            if next_epoch <= now or next_epoch > 2147483647:
                raise StateError("gc-internal", "schedule epoch overflow", 5, True)
            schedule_meta = {"schema_version": 1, "state": "SCHEDULED",
                             "generation": schedule[0] + 1, "next_gc_epoch": next_epoch,
                             "reason": reason, "committed_epoch": now,
                             "source_root_digest": root[3][3].hex()}
            schedule_image = _catalog_image(b"ZYZSCH1", 4096, schedule[0] + 1,
                                            schedule[3], schedule_meta)
            schedule_bank = 1 - proof["root_meta"]["schedule_bank"]
            _catalog_pwrite_all(fd, schedule_image,
                                CATALOG_LAYOUT["schedule"][0] + schedule_bank * 4096,
                                "SCHEDULE successor")
            _data_sync(fd)
            _catalog_barrier("gc-step", "schedule")
            schedule_digest = _catalog_digest(b"zyz-pack-image-id-v1", schedule_image)

            root_meta = dict(proof["root_meta"])
            root_meta.update(generation=root[0] + 1, schedule_bank=schedule_bank,
                             schedule_digest=schedule_digest.hex())
            if root_updates:
                root_meta.update(root_updates)
            old_root = root[2]
            root_image = _catalog_image(b"ZYZROOT1", CATALOG_ROOT_IMAGE_SIZE, root[0] + 1,
                                        root[3][3], root_meta, ((4096, old_root[4096:]),))
            root_bank = 1 - root[1]
            _catalog_pwrite_all(fd, root_image,
                                CATALOG_LAYOUT["root_meta"][0] + root_bank * CATALOG_ROOT_IMAGE_SIZE,
                                "ROOT_META successor")
            _data_sync(fd)
            _catalog_barrier("catalog-root", "root-successor-durable")
        finally:
            os.close(fd)
        refreshed = _catalog_validate_genesis(container)
        os.close(refreshed.pop("global_fd"))
        return refreshed


def gc_step_command(task: str, trigger: str) -> tuple[dict, int]:
    if trigger not in CATALOG_TRIGGERS:
        return _gc_error(_gc_output(), "error", "invalid-request",
                         "trigger must be watchdog, lifecycle, manual, or system-timer",
                         False, 2)
    try:
        _catalog_runtime(task)
    except StateError as exc:
        return _gc_error(
            _gc_output(), "error", "invalid-request", exc.message, False, 2)
    explicit_due = True if trigger in ("manual", "system-timer") else None
    out = _gc_output(trigger, explicit_due, False)
    try:
        config = _gc_config()
        entry_now = _gc_now_epoch()
        _gc_test_monotonic_validate()
    except StateError as exc:
        return _gc_error(out, "error", "invalid-request", exc.message, False, 2)
    try:
        container, _ = ensure_catalog_genesis(task, False)
        terminal_pending = False
        terminal_hint_error = None
        try:
            terminal_pending = _terminal_pending_release_known(container)
        except StateError as exc:
            terminal_hint_error = exc

        # The entry snapshot is the only source of stdout due/before fields.
        # No pass mutation is permitted before this lock is released.
        with CatalogFlock(container):
            out["lock_acquired"] = True
            entry = _catalog_validate_genesis(container)
            os.close(entry.pop("global_fd"))
            root = entry["root_meta"]
            required_ints = ("owned_bytes", "blocked_claims_known",
                             "active_claims", "active_data_claims",
                             "discovery_cursor")
            if any(not isinstance(root.get(key), int) or
                   isinstance(root[key], bool) or root[key] < 0
                   for key in required_ints):
                raise StateError("catalog-root-invalid",
                                 "ROOT counters are invalid", 4)
            if not isinstance(root.get("claim_scan_due"), bool):
                raise StateError("catalog-root-invalid",
                                 "ROOT claim scan hint is invalid", 4)
            due = _gc_schedule_due(
                trigger, entry["schedule_meta"], root, config, entry_now,
                terminal_pending)
            out.update(
                due=due,
                blocked_claims_known=root["blocked_claims_known"],
                owned_bytes_before=root["owned_bytes"],
                high_water=config["ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES"],
                hard_water=config["ZYZ_SNAPSHOT_GC_HARD_WATER_BYTES"])
            entry_schedule_epoch = entry["schedule_meta"].get(
                "next_gc_epoch")
            _catalog_barrier("gc-step", "entry-snapshot")

        if terminal_hint_error is not None:
            raise terminal_hint_error
        if root["blocked_claims_known"] > 0:
            out["owned_bytes_after"] = root["owned_bytes"]
            return _gc_error(out, "blocked", "catalog-claim-blocked",
                             "catalog contains blocked claims", False, 4)
        if not due:
            out["owned_bytes_after"] = root["owned_bytes"]
            out["next_gc_epoch"] = entry_schedule_epoch
            if _catalog_dense_signature_matches(root):
                return _gc_error(
                    out, "pressure", "catalog-capacity-pressure",
                    "catalog is densely occupied by live claims", True, 3, True)
            out.update(ok=True, state="idle", error=None)
            return out, 0

        pending = False
        pressure = False
        completed_work = False
        future: list[int] = []
        if isinstance(entry_schedule_epoch, int) and entry_schedule_epoch > entry_now:
            future.append(entry_schedule_epoch)

        terminal_release = _terminal_resume_pending_release(container, config)
        if terminal_release is not None:
            completed_work = (completed_work or
                              terminal_release["compaction_advanced"])
            out["transactions_advanced"] += 1
            out["entries_deleted"] += terminal_release["entries_deleted"]
            out["bytes_reclaimed"] += terminal_release["bytes_reclaimed"]

        anchor_result = _gc_consume_pending_anchor(container, config)
        if anchor_result is not None and anchor_result.get("state") == "released":
            completed_work = True
            out["receipts_anchored"] += 1
            out["transactions_advanced"] += 1
            out["entries_deleted"] += anchor_result.get("entries_deleted", 0)
            out["bytes_reclaimed"] += anchor_result.get("bytes_reclaimed", 0)

        # Freeze at most one 64-claim slice under the catalog lock, then release
        # it before any per-claim instance/terminal operation.
        sweep = None
        with CatalogFlock(container):
            current = _catalog_validate_genesis(container)
            os.close(current.pop("global_fd"))
            if current["root_meta"]["active_data_claims"] > 0:
                global_rw = os.open(
                    os.fsencode(container / ".catalog-global-pack.v1"),
                    os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
                recovery_ro = os.open(
                    os.fsencode(container / ".catalog-recovery-pack.v1"),
                    os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                try:
                    sweep = _gc_claim_sweep(
                        container, current, global_rw, recovery_ro, 64)
                finally:
                    os.close(global_rw); os.close(recovery_ro)
        future_epoch = None
        if sweep is not None:
            out["claims_scanned"] += sweep["claims_scanned"]
            out["transactions_advanced"] += 1
            prior_future = sweep.get("prior_next_gc_epoch")
            if isinstance(prior_future, int) and prior_future > entry_now:
                future.append(prior_future)
            eligible = 0
            pending_digest = None
            for candidate in sweep["candidates"]:
                existing_gc = _instance_pack_read(
                    container, candidate["logical_key_sha256"],
                    "claim", "GC_JOURNAL")
                publication_ready = False
                if (existing_gc is None and
                        candidate["owner"].get("state") == "did-create" and
                        candidate["owner"].get("purpose") ==
                            "snapshot-publication"):
                    publication_ready = (_gc_publication_staging_plan(
                        container, candidate) is not None)
                if existing_gc is not None or publication_ready:
                    classification, epoch = "eligible", None
                else:
                    classification, epoch = _gc_claim_classify(
                        candidate, entry_now,
                        config["ZYZ_NO_OUTPUT_TEMP_STALE_SEC"])
                if classification == "skip":
                    out["claims_skipped"] += 1
                    if isinstance(epoch, int) and epoch > entry_now:
                        future.append(epoch)
                    _gc_claim_observe(container, candidate, entry_now, epoch)
                    continue
                advanced = _gc_claim_advance(
                    container, candidate, entry_now, config)
                effects = advanced["effects"]
                out["entries_verified"] += effects["entries_verified"]
                out["verification_bytes"] += effects["verification_bytes"]
                out["entries_deleted"] += effects["entries_deleted"]
                out["bytes_reclaimed"] += effects["bytes_reclaimed"]
                out["transactions_advanced"] += 1
                if (advanced["state"] == "waiting-receipt-anchor" and
                        pending_digest is None):
                    pending_digest = candidate["logical_key_sha256"]
                if advanced["state"] == "skipped":
                    out["claims_skipped"] += 1
                else:
                    # Cursor/schedule bookkeeping and a healthy ineligible
                    # observation are scan work, not compaction.  Only a claim
                    # lifecycle that durably advances toward receipt/release
                    # contributes to the final compacted aggregate.
                    completed_work = True
                    eligible += 1
            future_epoch = min(future) if future else None
            if sweep["more"]:
                _, root_advanced = _catalog_commit_root_updates(
                    container, current,
                    {"sweep_next_gc_epoch": future_epoch},
                    "claim-sweep-future")
                out["transactions_advanced"] += int(root_advanced)
            if pending_digest is not None:
                with CatalogFlock(container):
                    pointer = _catalog_validate_genesis(container)
                    os.close(pointer.pop("global_fd"))
                    observed = pointer["root_meta"].get(
                        "pending_anchor_claim_sha256")
                if observed is None:
                    _, root_advanced = _catalog_commit_root_updates(
                        container, pointer,
                        {"pending_anchor_claim_sha256": pending_digest},
                        "pending-anchor-pointer")
                    out["transactions_advanced"] += int(root_advanced)
                elif observed != pending_digest:
                    raise StateError("catalog-root-invalid",
                                     "pending anchor pointer conflicts", 4)
            pending = (sweep["more"] or eligible > 0 or
                       (future_epoch is not None and
                        future_epoch <= entry_now))

        migration = _catalog_migration_step(container, config)
        out["transactions_advanced"] += migration["transactions_advanced"]
        out["entries_deleted"] += migration["entries_deleted"]
        out["bytes_reclaimed"] += migration["bytes_reclaimed"]
        completed_work = completed_work or migration["advanced"]
        pending = pending or migration["pending"]
        pressure = migration["pressure"]

        with CatalogFlock(container):
            after = _catalog_validate_genesis(container)
            os.close(after.pop("global_fd"))
            after_root = after["root_meta"]
        out["owned_bytes_after"] = after_root["owned_bytes"]
        if after_root["blocked_claims_known"] > 0:
            return _gc_error(out, "blocked", "catalog-claim-blocked",
                             "catalog contains blocked claims", False, 4)

        if not pending:
            root_updates = None
            if (after_root["active_data_claims"] == 0 or
                    (sweep is not None and not sweep["more"])):
                root_updates = {"claim_scan_due": False,
                                "sweep_next_gc_epoch": None}
            cadence = (entry_now + config["ZYZ_SNAPSHOT_GC_INTERVAL_SEC"]
                       if config["ZYZ_SNAPSHOT_GC_INTERVAL_SEC"] else None)
            future_values = [value for value in (future_epoch, cadence)
                             if isinstance(value, int) and value > entry_now]
            schedule_epoch = min(future_values) if future_values else None
            if schedule_epoch is not None:
                after = _catalog_commit_idle_schedule(
                    container, after, config, entry_now, schedule_epoch,
                    "ttl-recheck" if future_epoch == schedule_epoch else
                    "cadence", root_updates)
                out["transactions_advanced"] += 1
                out["next_gc_epoch"] = schedule_epoch
            elif root_updates:
                after, root_advanced = _catalog_commit_root_updates(
                    container, after, root_updates, "claim-sweep-idle")
                out["transactions_advanced"] += int(root_advanced)
                out["next_gc_epoch"] = None
            else:
                out["next_gc_epoch"] = (entry_schedule_epoch
                                        if isinstance(entry_schedule_epoch, int) and
                                        entry_schedule_epoch > entry_now else None)
            out["owned_bytes_after"] = after["root_meta"]["owned_bytes"]
            pressure = _catalog_dense_signature_matches(after["root_meta"])
        else:
            out["next_gc_epoch"] = (future_epoch
                                    if isinstance(future_epoch, int) and
                                    future_epoch > entry_now else None)

        if pending:
            out.update(ok=True, state="pending", error=None)
            return out, 3
        if pressure:
            return _gc_error(
                out, "pressure", "catalog-capacity-pressure",
                "catalog is densely occupied by live claims", True, 3, True)
        out.update(ok=True, state="compacted" if completed_work else "idle",
                   error=None)
        return out, 0
    except StateError as exc:
        if exc.code == "catalog-lock-timeout":
            out.update(ok=True, state="pending", error=None)
            if out["owned_bytes_before"] is None:
                out["lock_acquired"] = False
            return out, 3
        if exc.code in ("catalog-lock-capability-unavailable", "genesis-capability-unavailable"):
            return _gc_error(out, "blocked", exc.code, exc.message, True, 4)
        if exc.code == "genesis-capacity-unavailable":
            return _gc_error(out, "blocked", exc.code, exc.message, True, 4)
        if exc.code == "catalog-root-invalid":
            return _gc_error(out, "blocked", exc.code, exc.message, False, 4)
        return _gc_error(out, "blocked", "gc-internal", exc.message, True, 5)
    except Exception as exc:
        return _gc_error(out, "blocked", "gc-internal", str(exc), True, 5)


def emit_gc(value: dict, code: int) -> int:
    ordered = {key: value[key] for key in GC_OUTPUT_KEYS}
    print(json.dumps(ordered, separators=(",", ":"), ensure_ascii=True))
    return code


def config_status():
    effective = {name: env_uint(name, default, low, high, zero) for name,default,low,high,zero in PUBLIC_CONFIG}
    frozen = ["ZYZ_NO_OUTPUT_MAX_PATHS","ZYZ_NO_OUTPUT_MAX_FILE_BYTES","ZYZ_NO_OUTPUT_MAX_TOTAL_BYTES",
              "ZYZ_NO_OUTPUT_MAX_INVENTORY_BYTES","ZYZ_NO_OUTPUT_MAX_MANIFEST_BYTES","ZYZ_NO_OUTPUT_MAX_RSS_BYTES",
              "ZYZ_NO_OUTPUT_MAX_TEMP_BYTES","ZYZ_NO_OUTPUT_SNAPSHOT_TIMEOUT_SEC"]
    result = {"ok": True, "state": "config", "effective": effective,
              "frozen_snapshot_policy": {k: effective[k] for k in frozen}}
    result.update(effective)
    return result


def path_record_selftest(root: str):
    path_b64=[]
    with os.scandir(os.fsencode(root)) as entries:
        for entry in entries: path_b64.append(base64.b64encode(os.fsencode(entry.name)).decode())
    return {"ok":True,"state":"paths","path_b64":path_b64}


def main(argv: list[str]) -> int:
    if not argv: raise StateError("usage", "missing command", 2)
    command = argv[0]
    if command == "gc-step" and len(argv) == 3:
        value, code = gc_step_command(argv[1], argv[2])
        return emit_gc(value, code)
    if command == "hook-main-heartbeat" and len(argv) == 3:
        hook_main_heartbeat(argv[1], argv[2]); return 0
    if command == "hook-observe" and len(argv) == 3:
        return emit(observe_task(argv[1], argv[2]))
    if command == "hook-start" and len(argv) == 4: hook_start(*argv[1:]); return 0
    if command == "hook-stop" and len(argv) == 4: hook_stop(*argv[1:]); return 0
    if command == "hook-heartbeat" and len(argv) == 7: hook_heartbeat(*argv[1:]); return 0
    if command == "config-status" and len(argv) == 1: return emit(config_status())
    if command == "path-record-selftest" and len(argv) == 2: return emit(path_record_selftest(argv[1]))
    env = base_envelope(argv)
    if command == "probe-status" and len(argv) == 3:
        return emit(status_result(argv[1], argv[2], env))
    if command == "probe-create" and len(argv) == 4:
        return emit(probe_create(argv[1], argv[2], argv[3], env))
    if command == "probe-ack" and len(argv) == 4:
        return emit(probe_update(command, argv[1], argv[2], argv[3], "acknowledged", env))
    if command == "probe-cancel" and len(argv) == 5:
        return emit(probe_update(command, argv[1], argv[2], argv[3], argv[4], env))
    if command == "finalize" and len(argv) in (5, 6):
        key, marker, idem = finalize_fixed(
            argv[1], argv[2], argv[3], argv[4],
            argv[5] if len(argv) == 6 else None)
        env.update(state="terminal", instance_key=key, trusted=True, tracking_capability="armed",
                   terminal_kind="finalized", terminal_epoch=marker["terminal_epoch"], idempotent=idem,
                   cleanup_state=marker["cleanup_state"], cleanup_pending=marker["cleanup_pending"],
                   cleanup_error=marker["cleanup_error"], cleanup_intent_digest=marker["cleanup_intent_digest"],
                   cleanup_receipt_digest=marker["cleanup_receipt_digest"])
        return emit(env)
    if command == "adopt-legacy" and len(argv) == 5:
        try:
            return emit(adopt_legacy(argv[1], argv[2], argv[3], argv[4], env))
        except StateError as exc:
            exc.envelope = env
            raise
    if command == "reconcile-start" and len(argv) == 6:
        return emit(reconcile_start(argv[1], argv[2], argv[3], argv[4], argv[5], env))
    if command == "reconcile-stop" and len(argv) == 6:
        return emit(reconcile_stop(argv[1], argv[2], argv[3], argv[4], argv[5], env))
    raise StateError("usage", "invalid command or argument count", 2)


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except StateError as exc:
        env = getattr(exc, "envelope", None)
        if not isinstance(env, dict):
            try: env = base_envelope(sys.argv[1:])
            except Exception: env = {"ok": False, "state": "error"}
        env.update(ok=False, state="error", error={"code": exc.code, "message": exc.message, "retryable": exc.retryable})
        print(json.dumps(env, sort_keys=True, separators=(",", ":"), ensure_ascii=True))
        raise SystemExit(exc.exit_code)
    except Exception as exc:
        try: env = base_envelope(sys.argv[1:])
        except Exception: env = {"ok": False, "state": "error"}
        env.update(ok=False, state="error", error={"code": "internal", "message": str(exc)[:512], "retryable": False})
        print(json.dumps(env, sort_keys=True, separators=(",", ":"), ensure_ascii=True))
        raise SystemExit(1)
