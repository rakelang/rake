# SoA proof assembly reporter

`run.sh` compiles every manifest case for SSE2, AVX2, and AVX-512, disassembles
the resulting object, and writes `report.json`, `report.tsv`, and `report.txt`.
Raw disassembly and compiler output are retained beside the reports. The host,
compiler, binutils, profile flags, and manifest hash are recorded in JSON.

The default manifest is `../cases.tsv`; paths in it are relative to the
manifest. It is tab-separated. A minimal example is:

```tsv
name	logical_case	language	source	symbol	kind	profiles	expect	compile_args	build_command	object
c-auto	particles	c	c/auto.c	update_particles	auto	sse2,avx2,avx512	pass			
rust-auto	particles	rust	rust/auto.rs	update_particles	auto	sse2,avx2,avx512	pass			
rake	particles	rake	rake/particles.rake	update_particles	native	sse2,avx2,avx512	pass		rakec --profile {profile} --emit-object {object} {source}	
```

Only `name`, `language`, and either `source`, `object`, or `build_command` are
fundamental. Aliases such as `lang`, `src`, `function`, `command`, and `obj`
are accepted. `{profile}`, `{source}`, `{object}`, `{root}`, and `{out}` are
expanded in build commands and object paths. Commands are tokenized like a
shell command but are executed directly; pipes and redirections are not
supported. Use a wrapper script for a multi-stage build.

```console
./tools/run.sh
./tools/run.sh --profile avx2 --out /tmp/soa-report
CC=clang-20 RUSTC=rustc OBJDUMP=objdump ./tools/run.sh
```

The report intentionally avoids fragile “better assembly” scores. Register
widths, opcodes, calls, branch direction, stack operands, and ELF symbol sizes
are direct observations. Spill and scalar-cleanup fields are explicitly named
as conservative evidence because proving either requires data-flow/control-flow
analysis. Source duplication is also labeled lexical rather than semantic.
