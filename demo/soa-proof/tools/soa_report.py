#!/usr/bin/env python3
"""Compile and inspect the SoA proof cases.

The output deliberately contains observations, not claims that require data-flow
analysis.  In particular, stack references are only *spill evidence*, and a
scalar floating-point operation plus a backward branch is only *scalar cleanup
evidence*.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable


VERSION = "1"
PROFILES = {
    "sse2": {
        "bits": 128,
        "c": ["-march=x86-64", "-msse2", "-mno-avx"],
        "rust": ["-C", "target-cpu=x86-64", "-C", "target-feature=+sse2,-avx,-avx2,-avx512f"],
    },
    "avx2": {
        "bits": 256,
        "c": ["-march=x86-64", "-mavx2", "-mfma", "-mno-avx512f"],
        "rust": ["-C", "target-cpu=x86-64", "-C", "target-feature=+avx2,+fma,-avx512f"],
    },
    "avx512": {
        "bits": 512,
        "c": ["-march=x86-64", "-mavx512f", "-mavx512dq", "-mavx512vl", "-mfma"],
        "rust": ["-C", "target-cpu=x86-64", "-C", "target-feature=+avx512f,+avx512dq,+avx512vl,+fma"],
    },
}

INSTRUCTION_RE = re.compile(r"^\s*([0-9a-fA-F]+):\s+(?:[0-9a-fA-F]{2}\s+)*([a-zA-Z][\w.]*)\s*(.*?)\s*$")
SYMBOL_RE = re.compile(r"^([0-9a-fA-F]+) <(.+)>:$")
REGISTER_RE = re.compile(r"\b([xyz]mm)(?:[0-9]|[12][0-9]|3[01])\b", re.I)
TARGET_RE = re.compile(r"(?:__m(?:128|256|512)|\b(?:xmm|ymm|zmm)\w*|avx(?:2|512)?|sse\d*)", re.I)
CPP_CONDITION_RE = re.compile(r"^\s*#\s*(?:if|ifdef|ifndef|elif)\b")
RUST_CFG_RE = re.compile(r"#\s*\[\s*cfg(?:_attr)?\b")
SCALAR_FP_RE = re.compile(
    r"^(?:v)?(?:add|sub|mul|div|max|min|sqrt|rcp|rsqrt|round|cvt\w*|fmadd\w*|fmsub\w*)s[sd]$",
    re.I,
)
PACKED_FP_RE = re.compile(
    r"^(?:v)?(?:add|sub|mul|div|max|min|sqrt|rcp|rsqrt|round|cvt\w*|fmadd\w*|fmsub\w*)p[sd]$",
    re.I,
)


def run(command: list[str], *, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def tool_version(executable: str | None) -> dict[str, str | None]:
    if not executable:
        return {"command": None, "path": None, "version": None}
    path = shutil.which(executable) if "/" not in executable else executable
    if not path:
        return {"command": executable, "path": None, "version": None}
    result = run([path, "--version"])
    first = (result.stdout or result.stderr).splitlines()
    return {"command": executable, "path": str(Path(path).resolve()), "version": first[0] if first else "unknown"}


def safe_name(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("._") or "case"


def resolve(path: str, base: Path, values: dict[str, str]) -> Path:
    expanded = path.format_map(defaultdict(str, values))
    candidate = Path(expanded).expanduser()
    return candidate if candidate.is_absolute() else (base / candidate).resolve()


def read_manifest(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader((line for line in stream if not line.lstrip().startswith("#")), delimiter="\t"))
    if not rows:
        raise ValueError(f"manifest has no cases: {path}")
    return [{str(k).strip(): (v or "").strip() for k, v in row.items()} for row in rows]


def field(row: dict[str, str], *names: str, default: str = "") -> str:
    return next((row[name] for name in names if row.get(name)), default)


def requested_profiles(row: dict[str, str]) -> list[str]:
    raw = field(row, "profiles", "profile", default="sse2,avx2,avx512")
    values = [part.strip() for part in re.split(r"[, ]+", raw) if part.strip()]
    unknown = sorted(set(values) - PROFILES.keys())
    if unknown:
        raise ValueError(f"unknown profile(s) {', '.join(unknown)}")
    return values


def default_compile(language: str, source: Path, obj: Path, profile: str, name: str,
                    compiler: str, extra: str) -> list[str]:
    args = shlex.split(extra)
    if language in {"c", "clang"}:
        return [compiler, "-O3", "-std=c11", "-fno-unwind-tables", "-fno-asynchronous-unwind-tables",
                *PROFILES[profile]["c"], *args, "-c", str(source), "-o", str(obj)]
    if language in {"rust", "rustc"}:
        crate = safe_name(name).replace("-", "_")
        return [compiler, "--edition=2021", "--crate-name", crate, "--crate-type=lib", "-C", "opt-level=3",
                "-C", "panic=abort", "-C", "codegen-units=1", *PROFILES[profile]["rust"], *args,
                "--emit=obj", "-o", str(obj), str(source)]
    raise ValueError(f"language {language!r} needs build_command or an existing object")


def source_metrics(path: Path | None) -> dict[str, Any]:
    if not path or not path.is_file():
        return {"source_bytes": None, "source_nonblank_lines": None, "source_sha256": None,
                "width_specific_tokens": None, "conditional_compilation_directives": None}
    data = path.read_bytes()
    text = data.decode("utf-8", errors="replace")
    lines = text.splitlines()
    return {
        "source_bytes": len(data),
        "source_nonblank_lines": sum(bool(line.strip()) for line in lines),
        "source_sha256": hashlib.sha256(data).hexdigest(),
        "width_specific_tokens": len(TARGET_RE.findall(text)),
        "conditional_compilation_directives": sum(bool(CPP_CONDITION_RE.search(line)) for line in lines)
        + len(RUST_CFG_RE.findall(text)),
    }


def parse_nm_size(obj: Path, symbol: str, nm: str) -> int | None:
    result = run([nm, "-S", "--defined-only", str(obj)])
    if result.returncode:
        return None
    matches: list[tuple[str, int]] = []
    for line in result.stdout.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and re.fullmatch(r"[0-9a-fA-F]+", parts[1]):
            matches.append((parts[3], int(parts[1], 16)))
    if symbol:
        exact = [size for name, size in matches if name == symbol]
        return exact[0] if exact else None
    return sum(size for _, size in matches)


def disassemble(obj: Path, symbol: str, objdump: str) -> tuple[str, list[dict[str, Any]], str | None]:
    command = [objdump, "-d", "-M", "intel", "--no-show-raw-insn"]
    if symbol:
        command.append(f"--disassemble={symbol}")
    command.append(str(obj))
    result = run(command)
    if result.returncode:
        return result.stdout, [], result.stderr.strip() or "objdump failed"
    instructions: list[dict[str, Any]] = []
    current = ""
    for line in result.stdout.splitlines():
        match = SYMBOL_RE.match(line.strip())
        if match:
            current = match.group(2)
            continue
        match = INSTRUCTION_RE.match(line)
        if not match or (symbol and current != symbol):
            continue
        address, mnemonic, operands = match.groups()
        instructions.append({"address": int(address, 16), "mnemonic": mnemonic.lower(),
                             "operands": operands.lower(), "symbol": current})
    error = None if instructions else f"no instructions found for {symbol or 'object'}"
    return result.stdout, instructions, error


def branch_target(operands: str) -> int | None:
    match = re.match(r"(?:0x)?([0-9a-f]+)(?:\s|$)", operands)
    return int(match.group(1), 16) if match else None


def inspect(instructions: list[dict[str, Any]]) -> dict[str, Any]:
    mnemonic_counts = Counter(inst["mnemonic"] for inst in instructions)
    width_counts: Counter[int] = Counter()
    vector_stack = 0
    stack_refs = 0
    calls = 0
    conditional_branches = 0
    backward_branches = 0
    scalar_fp = 0
    packed_fp = 0
    call_targets: list[str] = []
    for inst in instructions:
        mnemonic, operands = inst["mnemonic"], inst["operands"]
        widths = {"xmm": 128, "ymm": 256, "zmm": 512}
        used = [widths[match.lower()] for match in REGISTER_RE.findall(operands)]
        if used:
            width_counts[max(used)] += 1
        has_stack = bool(re.search(r"\[(?:[^]]*\b(?:rsp|rbp)\b[^]]*)\]", operands))
        stack_refs += has_stack
        vector_stack += bool(has_stack and used)
        is_call = mnemonic.startswith("call")
        calls += is_call
        if is_call:
            call_targets.append(operands)
        is_conditional = mnemonic.startswith("j") and mnemonic not in {"jmp", "jmpq"}
        conditional_branches += is_conditional
        target = branch_target(operands)
        backward_branches += bool(is_conditional and target is not None and target < inst["address"])
        scalar_fp += bool(SCALAR_FP_RE.match(mnemonic))
        packed_fp += bool(PACKED_FP_RE.match(mnemonic))
    max_width = max(width_counts, default=0)
    frame_setup = any(
        (inst["mnemonic"] == "push" and inst["operands"].strip() == "rbp")
        or (inst["mnemonic"] == "sub" and inst["operands"].lstrip().startswith("rsp,"))
        for inst in instructions
    )
    return {
        "instruction_count": len(instructions),
        "max_vector_register_bits": max_width or None,
        "instructions_using_xmm": width_counts[128],
        "instructions_using_ymm": width_counts[256],
        "instructions_using_zmm": width_counts[512],
        "packed_fp_instructions": packed_fp,
        "scalar_fp_instructions": scalar_fp,
        "calls": calls,
        "call_targets": call_targets,
        "conditional_branches": conditional_branches,
        "backward_conditional_branches": backward_branches,
        "stack_frame_setup": frame_setup,
        "stack_memory_accesses": stack_refs,
        "vector_stack_memory_accesses": vector_stack,
        "spill_evidence": bool(vector_stack),
        "scalar_cleanup_evidence": bool(scalar_fp and backward_branches),
        "mnemonics": dict(sorted(mnemonic_counts.items())),
    }


def lexical_duplication(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[tuple[str, str], set[Path]] = defaultdict(set)
    for record in records:
        source = record.get("source")
        if source:
            groups[(record["logical_case"], record["language"])].add(Path(source))
    result = []
    for (case, language), paths in sorted(groups.items()):
        normalized: list[str] = []
        lines_by_file: list[set[str]] = []
        valid_paths = [path for path in sorted(paths) if path.is_file()]
        for path in valid_paths:
            file_lines: set[str] = set()
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
                value = re.sub(r"\s+", " ", line.strip())
                if value and not value.startswith("//"):
                    normalized.append(value)
                    file_lines.add(value)
            lines_by_file.append(file_lines)
        cross_file_counts = Counter(line for file_lines in lines_by_file for line in file_lines)
        result.append({
            "logical_case": case,
            "language": language,
            "distinct_source_files": len(valid_paths),
            "normalized_noncomment_lines": len(normalized),
            "cross_file_repeated_normalized_lines": sum(count - 1 for count in cross_file_counts.values()),
            "definition": "lexical: shared whitespace-collapsed nonblank lines across distinct files, excluding //-only lines",
        })
    return result


def write_tsv(path: Path, records: list[dict[str, Any]]) -> None:
    columns = [
        "name", "logical_case", "language", "kind", "profile", "expected", "status", "source", "object",
        "symbol", "code_size_bytes", "instruction_count", "max_vector_register_bits", "packed_fp_instructions",
        "scalar_fp_instructions", "calls", "conditional_branches", "backward_conditional_branches",
        "stack_frame_setup", "stack_memory_accesses", "vector_stack_memory_accesses", "spill_evidence",
        "scalar_cleanup_evidence", "source_nonblank_lines", "source_bytes", "width_specific_tokens",
        "conditional_compilation_directives", "mnemonics", "call_targets", "error",
    ]
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, columns, delimiter="\t", extrasaction="ignore", lineterminator="\n")
        writer.writeheader()
        writer.writerows({key: json.dumps(value, sort_keys=True) if isinstance(value, (dict, list)) else value
                          for key, value in record.items()} for record in records)


def write_text(path: Path, records: list[dict[str, Any]], duplication: list[dict[str, Any]], metadata: dict[str, Any]) -> None:
    lines = [
        "SoA assembly report",
        f"host: {metadata['host']['system']} {metadata['host']['machine']} | objdump: {metadata['tools']['objdump']['version']}",
        "",
        "case/profile                 status              bits size  calls stack vec-stack scalar-fp packed-fp",
    ]
    for record in records:
        label = f"{record['name']}/{record['profile']}"
        lines.append(
            f"{label:<28} {record['status']:<19} {str(record.get('max_vector_register_bits') or '-'):>4} "
            f"{str(record.get('code_size_bytes') or '-'):>4} {str(record.get('calls', '-')):>6} "
            f"{str(record.get('stack_memory_accesses', '-')):>5} "
            f"{str(record.get('vector_stack_memory_accesses', '-')):>9} "
            f"{str(record.get('scalar_fp_instructions', '-')):>9} {str(record.get('packed_fp_instructions', '-')):>9}"
        )
        if record.get("error"):
            lines.append(f"  error: {record['error'].splitlines()[0]}")
    lines += ["", "Source duplication (lexical, not semantic):"]
    for item in duplication:
        lines.append(
            f"  {item['logical_case']}/{item['language']}: {item['distinct_source_files']} file(s), "
            f"{item['normalized_noncomment_lines']} lines, "
            f"{item['cross_file_repeated_normalized_lines']} cross-file repeated lines"
        )
    lines += [
        "",
        "Notes: register width/opcode/call/branch/stack figures are direct disassembly observations.",
        "spill_evidence means a vector-register instruction references rsp/rbp; it is not data-flow proof of a spill.",
        "scalar_cleanup_evidence means scalar FP instructions and a backward conditional branch both occur.",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=Path(__file__).resolve().parent.parent / "cases.tsv")
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parent.parent / "out")
    parser.add_argument("--profile", action="append", choices=sorted(PROFILES), help="limit profiles (repeatable)")
    parser.add_argument("--clang", default=os.environ.get("CC", "clang"))
    parser.add_argument("--rustc", default=os.environ.get("RUSTC", "rustc"))
    parser.add_argument("--objdump", default=os.environ.get("OBJDUMP", "objdump"))
    parser.add_argument("--nm", default=os.environ.get("NM", "nm"))
    args = parser.parse_args()

    manifest = args.manifest.resolve()
    base = manifest.parent
    out = args.out.resolve()
    (out / "build").mkdir(parents=True, exist_ok=True)
    (out / "disasm").mkdir(parents=True, exist_ok=True)
    (out / "logs").mkdir(parents=True, exist_ok=True)
    selected = set(args.profile or PROFILES)
    rows = read_manifest(manifest)
    records: list[dict[str, Any]] = []
    unexpected = False

    for index, row in enumerate(rows, 1):
        name = field(row, "name", "id", default=f"case-{index}")
        logical_case = field(row, "logical_case", "case", default=name)
        language = field(row, "language", "lang").lower()
        symbol = field(row, "symbol", "function")
        kind = field(row, "kind", "variant", default="unspecified")
        expected = field(row, "expect", "expected", default="pass").lower()
        if expected in {"compile", "success"}:
            expected = "pass"
        if expected in {"fail", "error"}:
            expected = "reject"
        for profile in requested_profiles(row):
            if profile not in selected:
                continue
            values = {**row, "name": name, "profile": profile, "root": str(base), "out": str(out)}
            source_text = field(row, "source", "src")
            source = resolve(source_text, base, values) if source_text else None
            values["source"] = str(source or "")
            object_text = field(row, "object", "obj")
            obj = resolve(object_text, base, values) if object_text else out / "build" / f"{safe_name(name)}.{profile}.o"
            obj.parent.mkdir(parents=True, exist_ok=True)
            values["object"] = str(obj)
            record: dict[str, Any] = {
                "name": name, "logical_case": logical_case, "language": language, "kind": kind,
                "profile": profile, "profile_vector_bits": PROFILES[profile]["bits"], "expected": expected,
                "source": str(source) if source else "", "object": str(obj), "symbol": symbol,
                **source_metrics(source),
            }
            build_command = field(row, "build_command", "command")
            command: list[str] | None = None
            if build_command:
                command = [part.format_map(defaultdict(str, values)) for part in shlex.split(build_command)]
            elif not object_text or not obj.is_file():
                compiler = field(row, "compiler", default=args.clang if language in {"c", "clang"} else args.rustc)
                try:
                    if source is None:
                        raise ValueError("source is required for default compilation")
                    command = default_compile(language, source, obj, profile, name, compiler,
                                              field(row, "compile_args", "args", "flags"))
                except ValueError as error:
                    record.update(status="configuration_error", error=str(error), compile_command=None)
                    records.append(record)
                    unexpected = True
                    continue
            record["compile_command"] = command
            compile_result = run(command, cwd=base) if command else None
            record["compile_exit_code"] = compile_result.returncode if compile_result else None
            if compile_result:
                log_base = out / "logs" / f"{safe_name(name)}.{profile}.compile"
                log_base.with_suffix(".stdout.txt").write_text(compile_result.stdout, encoding="utf-8")
                log_base.with_suffix(".stderr.txt").write_text(compile_result.stderr, encoding="utf-8")
            command_failed = compile_result is not None and compile_result.returncode != 0
            if command_failed:
                error = (compile_result.stderr.strip() if compile_result else f"object does not exist: {obj}")
                status = "expected_rejection" if expected == "reject" else "compile_failed"
                record.update(status=status, error=error)
                unexpected |= expected != "reject"
                records.append(record)
                continue
            if not obj.is_file():
                record.update(status="artifact_missing", error=f"build succeeded but object does not exist: {obj}")
                records.append(record)
                unexpected = True
                continue
            if expected == "reject":
                record.update(status="unexpected_acceptance", error="compiled successfully but rejection was expected")
                unexpected = True
            else:
                record.update(status="compiled", error=None)
            disassembly, instructions, error = disassemble(obj, symbol, args.objdump)
            (out / "disasm" / f"{safe_name(name)}.{profile}.txt").write_text(disassembly, encoding="utf-8")
            record.update(inspect(instructions))
            record["code_size_bytes"] = parse_nm_size(obj, symbol, args.nm)
            if error:
                record["status"] = "analysis_failed"
                record["error"] = error
                unexpected = True
            records.append(record)

    metadata = {
        "schema_version": VERSION,
        "generated_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "manifest": str(manifest),
        "manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
        "host": {"system": platform.system(), "release": platform.release(), "machine": platform.machine(),
                 "python": platform.python_version()},
        "tools": {"clang": tool_version(args.clang), "rustc": tool_version(args.rustc),
                  "objdump": tool_version(args.objdump), "nm": tool_version(args.nm)},
        "profiles": PROFILES,
        "definitions": {
            "spill_evidence": "vector-register instruction with an rsp/rbp memory operand",
            "scalar_cleanup_evidence": "scalar floating-point instruction(s) and backward conditional branch(es) coexist",
            "code_size_bytes": "ELF symbol st_size reported by nm; whole-object sum when symbol is omitted",
        },
    }
    duplication = lexical_duplication(records)
    payload = {"metadata": metadata, "records": records, "source_duplication": duplication}
    (out / "report.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_tsv(out / "report.tsv", records)
    write_text(out / "report.txt", records, duplication, metadata)
    print((out / "report.txt").read_text(encoding="utf-8"), end="")
    return 1 if unexpected else 0


if __name__ == "__main__":
    raise SystemExit(main())
