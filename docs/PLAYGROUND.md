# The Rake playground

This page includes the playground: someone who has never written SIMD code
can learn Rake by editing and running small programs in the browser. The
tutorial introduces one idea at a time and makes each idea visible in the
result, lane trace, generated code or compiler message. The reference after
the editor explains each lesson and the syntax that may look strange to a
programmer coming from C, Java, JavaScript or Python. Every program is
also compiled by the documentation checker, and its result is the one the
lesson promises.

## The screen

```text
+------------------------------------------------------------------------+
| Rake playground     Lesson 4 of 12: Marking uniforms     [Prev] [Next] |
+----------------------------+-------------------------------------------+
| Lesson text                | Editor                                    |
|                            |  scratch scale(values: f32s,               |
| What the lesson            |               <factor: f32>) -> f32s:     |
| introduces, the task and   |    values * <factor>                      |
| what to inspect after      |                                           |
| running it.                | [Run]   Target: [wasm-simd128 v]  [Reset] |
|                            +-------------------------------------------+
|                            | Result | Lanes | Code | Messages          |
|                            |                                           |
|                            |  main returned 40                         |
+----------------------------+-------------------------------------------+
```

The lesson text sits on the left and the editor on the right, with four
tabs under it:

| Tab | Shows |
| --- | --- |
| Result | what `main` returned, or the trap that stopped it, with its line |
| Lanes | each rack the program computed as a row with one decimal value per lane, and each mask as a row of filled and empty cells |
| Code | the selected target's output: C with WebAssembly intrinsics, native kernel assembly, or native mixed C with opaque kernel assembly |
| Messages | the compiler's errors, each also underlined in the editor at its line and column |

Stepping through a program in the Lanes tab shows one instruction acting on
all the lanes at once, the idea the whole tutorial builds on.

The target menu offers WebAssembly, SSE2, AVX2, AVX-512 and NEON. The browser
development compiler supports native slow orchestration with uniform `f32`
kernel calls too. Lessons start on WebAssembly when they contain a whole
program. WebAssembly covers general memory runs. SSE2, AVX2, AVX-512 and NEON
also compile `f32` stream traversals and single-column stack updates. Other
native memory runs give the compiler's work-in-progress diagnostic. Updates
can use a separate destination stack with a different record layout. Every result and
lane trace comes from Rake's interpreter, using the selected profile's `f32`
rack width. The browser displays C or assembly without executing that
generated machine code. Native object verification still requires `rakec`
and the platform toolchain outside the browser.

## How it works

The compiler runs in the page. `rakec` is OCaml, and `js_of_ocaml` compiles
its front end, interpreter and emitters for the browser, so the playground
calls the same code behind `rakec --interpret` and `rakec --emit-asm` that
runs on a workstation. The parts that start clang and the assembler stay out
of the browser build. Compilation and execution happen in a worker. A program
that runs for more than three seconds is stopped without freezing the editor.
The Lanes tab reads the
interpreter's values, which it already computes lane by lane. Object
verification needs clang and a disassembler, so the playground leaves it to
the command line, and the Code tab says so.

The editor highlights code with the Rake Tree-sitter grammar, compiled to
WebAssembly, with the same highlighting queries this site uses. The lessons
are this page: each lesson's program and expected result live here, and the
documentation checker compiles and runs every one, so a change to the
language that breaks a lesson fails the compiler's tests until the lesson is
updated.

## The lessons

| # | Lesson | Concept it introduces | Key moment |
| ---: | --- | --- | --- |
| 1 | [A program](#1-a-program) | definitions, indentation, `->`, `let`, comments | changing `6 * 7` and seeing the new result |
| 2 | [Changing values](#2-changing-values) | `:=` and `<-`, `for`, `if`, `%` | assigning to a `let` is refused |
| 3 | [A rack](#3-a-rack) | `f32s`, views, `run`, a rack load and store | Lanes shows one vector multiply on four lanes |
| 4 | [Marking uniforms](#4-marking-uniforms) | `scratch`, `<factor: f32>` and `<factor>` | removing the brackets is an error that points at the broadcast |
| 5 | [Loops and reductions](#5-loops-and-reductions) | counted vector loops, rack locations, `sum`, `let <x: T>` | the four running sums fold into one |
| 6 | [Fused stages](#6-fused-stages) | `\| name <\| e`, fused multiply-add | the x86 Code tab shows one `vfmadd231ps` |
| 7 | [Choosing by lane](#7-choosing-by-lane) | masks, `if ... then ... else` on racks | both branches run and a select joins them |
| 8 | [Tines and sweeps](#8-tines-and-sweeps) | global `#tine` predicates, `through`, `sweep`, `gaps`, optional fallbacks | incomplete coverage and an undefined lane both become compiler errors |
| 9 | [Columns](#9-columns) | `stack`, `pack`, traversals, `widen`, tails | a count of 6 leaves a tail with two live lanes |
| 10 | [A whole program](#10-a-whole-program) | `slow {}`, records, `state`, `mut` | scalar state updates require a block, and vector work resumes at `}` |
| 11 | [Proved or refused](#11-proved-or-refused) | profiles and their rules | `sin` is refused instead of slowed down |
| 12 | [Bits](#12-bits) | integer racks, bit operations, `repeat` | a flood fill spreads along a row of a bitboard |

Each lesson adds one idea to the ones before it, and the key moment is the
point the lesson is built to reach: the learner makes a change, runs it, and
sees the idea in the result, the Lanes tab or a message.

## 1. A program

A Rake file is a list of definitions. `slow main() -> i32:` defines the
program's entry point, a function with no parameters that returns a 32-bit
integer. The line ends in a colon, and the indented lines below it are its
body. `let` binds a name to a value, and `~~` starts a comment.

<!-- rake-check: run 42 -->
<!-- playground-starter -->
```rake
~~ The program's result is what main returns.
slow main() -> i32:
  let answer = 6 * 7
  return answer
```

Result: `main returned 42`. Change `6 * 7` to `9 * 9`, run the program and
check that Result changes to `main returned 81`. This gives the first lesson
its edit, run and read loop before any SIMD appears.

## 2. Changing values

A `let` is bound once. A name that changes is a location, made with `:=` and
changed with `<-`. `for i from 0 up to 10:` counts from 0 to 9, and `%` is
the remainder.

<!-- rake-check: run 20 -->
<!-- playground-starter -->
```rake
slow main() -> i32:
  total := 0
  for i from 0 up to 10:
    if i % 2 = 0:
      total <- total + i
  return total
```

Result: `main returned 20`, the sum of 0, 2, 4, 6 and 8. Change
`total := 0` to `let total = 0` and run. The
Messages tab says `this location can't be assigned` at the `<-`, which shows
that the two kinds of name are different things, not two spellings.

## 3. A rack

`f32s` is a rack: four `f32` values in one WebAssembly `v128`. A
`run` is vector code that reads and writes memory. Its parameter `x: []f32`
is a view of floats, and `mut []f32` one it may write. `x[<0>]` loads the
rack of four floats starting at element 0, and `out[<0>] <- ...` stores one.
`<2.0>` is the number 2 in every lane.

<!-- rake-check: run 20 -->
<!-- playground-starter -->
```rake
run twice(x: []f32, out: mut []f32):
  out[<0>] <- x[<0>] * <2.0>

slow main() -> i32:
  values: [4]f32 := [1.0, 2.0, 3.0, 4.0]
  doubled: [4]f32 := [0.0; 4]
  twice(values, doubled)
  return i32(doubled[0] + doubled[1] + doubled[2] + doubled[3])
```

Result: `main returned 20`. Change `<2.0>` to `<3.0>` and run. Result becomes
`main returned 30`. In the Lanes tab, the load fills
a row of four cells, `1 2 3 4`, and the multiply turns the whole row into
`3 6 9 12` in one step. The Code tab shows the step is one
`wasm_f32x4_mul`.

## 4. Marking uniforms

A `scratch` is a function of racks. `<factor: f32>` declares a uniform, one
scalar shared by every lane, and `<factor>` uses it. The brackets appear at
both places on purpose: wherever a scalar becomes a rack, the page shows it.

<!-- rake-check: run 40 -->
<!-- playground-starter -->
```rake
scratch scale(values: f32s, <factor: f32>) -> f32s:
  values * <factor>

run scale_all(x: []f32, out: mut []f32, <factor: f32>):
  out[<0>] <- scale(x[<0>], <factor>)

slow main() -> i32:
  values: [4]f32 := [1.0, 2.0, 3.0, 4.0]
  scaled: [4]f32 := [0.0; 4]
  let factor = 10.0
  scale_all(values, scaled, <factor>)
  return i32(scaled[3])
```

Result: `main returned 40`. Slow code writes `factor` bare, because there it
is just a number. It is marked `<factor>` at the call, where it crosses into
vector code. Delete the brackets around `factor` inside the scratch and run:

<!-- rake-check: reject "'factor' is a uniform scalar: write <factor> where it meets a rack" -->
```rake
scratch scale(values: f32s, <factor: f32>) -> f32s:
  values * factor
```

The message points at `factor` and says what to write. Broadcasting a scalar
costs an instruction, and Rake never does it out of sight.

## 5. Loops and reductions

In a run, `for <i: i32> from <0> up to <n> by <4>:` counts in steps of four,
and its index is a uniform. `sums := <0.0>` is a location that holds a rack,
four running sums. `sum(sums)` adds a rack's lanes into one scalar, and
`let <whole: f32> = ...` binds that scalar as a uniform.

<!-- rake-check: run 78 -->
<!-- playground-starter -->
```rake
run total(x: []f32, out: mut []f32, <n: i32>):
  sums := <0.0>
  for <i: i32> from <0> up to <n> by <4>:
    sums <- sums + x[<i>]
  let <whole: f32> = sum(sums)
  out[<0>] <- <whole>

slow main() -> i32:
  values: [12]f32 := [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0]
  result: [4]f32 := [0.0; 4]
  total(values, result, <12>)
  return i32(result[0])
```

Result: `main returned 78`, the sum of 1 to 12. Change the count passed to
`total` from `<12>` to `<8>` and run. Result becomes `main returned 36`.
In the Lanes tab after the shorter loop, `sums` holds `6 8 10 12`, one
running sum in each lane, and `sum` folds them from lane 0 upwards into 36.
Vector code adds in columns, then reduces once at the end.

## 6. Fused stages

`| step <| velocities * <dt>` is one stage of a fused computation. Read it
from right to left: the expression flows into `step`. Consecutive stages
form one region of pure arithmetic, and the identifiers inside it are for the
reader, so the compiler sees `positions + velocities * <dt>`.

<!-- rake-check: verify x86-avx2 aarch64-neon wasm-simd128 -->
<!-- playground-starter -->
```rake
scratch advance(positions: f32s, velocities: f32s, <dt: f32>) -> f32s:
  | step  <| velocities * <dt>
  | moved <| positions + step
  moved
```

This lesson has no `main`. Select `x86-avx2`, run the compiler and open Code.
Find the two instructions that implement the scratch:

```text
advance:
    vbroadcastss ymm2, xmm2
    vfmadd231ps ymm0, ymm1, ymm2
    ret
```

The multiply and the add became one fused multiply-add on eight lanes, and
the broadcast of `<dt>` is the instruction above it. On `wasm-simd128`,
which has no fused multiply-add, the tab shows a splat, a multiply and an add.

## 7. Choosing by lane

A comparison of racks gives a mask, one true or false for each lane. `if v >
w then v - w else w - v` with a mask condition chooses lane by lane.

<!-- rake-check: run 4703 -->
<!-- playground-starter -->
```rake
scratch distance(v: f32s, w: f32s) -> f32s:
  if v > w then v - w else w - v

run distances(a: []f32, b: []f32, out: mut []f32):
  out[<0>] <- distance(a[<0>], b[<0>])

slow main() -> i32:
  a: [4]f32 := [1.0, 9.0, 4.0, 4.0]
  b: [4]f32 := [5.0, 2.0, 4.0, 1.0]
  result: [4]f32 := [0.0; 4]
  distances(a, b, result)
  return i32(result[0] * 1000.0 + result[1] * 100.0 + result[2] * 10.0 + result[3])
```

Result: `main returned 4703`, the four distances 4, 7, 0 and 3 as digits.
Change the first value of `a` from `1.0` to `6.0` and run. Result becomes
`main returned 1703`. In the Lanes tab, the first mask value changes and the
select takes the other subtraction for that lane. Both subtractions still run
on all four lanes, because there is only one instruction stream.

## 8. Tines and sweeps

Some operations go wrong on some inputs. The square root of a negative
number is NaN:

<!-- rake-check: trap "does not fit i32" -->
```rake
scratch roots(values: f32s) -> f32s:
  sqrt(values)

run all_roots(x: []f32, out: mut []f32):
  out[<0>] <- roots(x[<0>])

slow main() -> i32:
  values: [4]f32 := [16.0, -4.0, 9.0, 1.0]
  rooted: [4]f32 := [0.0; 4]
  all_roots(values, rooted)
  return i32(rooted[0] + rooted[1] + rooted[2] + rooted[3])
```

Result: a trap at the last line, `-nan does not fit i32`, and the Lanes tab
shows `4 NaN 3 1`. A rake guards the lanes instead.
Define `tine #valid(values: f32s) means values >= <0.0>` outside the rake.
It is a reusable predicate with an explicit input, so applying
`#valid(values)` computes the mask of lanes that may take a root.
`through #valid(values) into rooted:` binds roots in those lanes. The other
lanes are undefined, so the sweep reads `rooted` only where the tine holds.
The `gaps` arm supplies zero for every complementary lane.

<!-- rake-check: run 8 -->
<!-- playground-starter -->
```rake
tine #valid(values: f32s) means values >= <0.0>

rake safe_root(values: f32s) -> f32s:
  through #valid(values) into rooted:
    sqrt(values)

  sweep:
    | #valid(values) => rooted
    | #valid(values) gaps => <0.0>

run all_roots(x: []f32, out: mut []f32):
  out[<0>] <- safe_root(x[<0>])

slow main() -> i32:
  values: [4]f32 := [16.0, -4.0, 9.0, 1.0]
  rooted: [4]f32 := [0.0; 4]
  all_roots(values, rooted)
  return i32(rooted[0] + rooted[1] + rooted[2] + rooted[3])
```

Result: `main returned 8`. The NaN has left the Lanes tab: `4 0 3 1`.

Change the `gaps` arm's value to `<-1.0>` and run. The result becomes
`main returned 7`, with output lanes `4 -1 3 1`. There is no intermediate
zero to change: `rooted` has a value only where `#valid(values)` holds.

Delete the `gaps` arm and run. The compiler reports
`Sweep does not provably cover every lane`. Restore it, then change its
value to `rooted`. That is also refused: it would read the root in the
negative lane, where no root was computed.

To define that intermediate lane, add `else <999.0>` before `into rooted`
in the through header. Run with `rooted` still in both sweep arms: the
result is now 1007. Reset the lesson to restore its original behaviour.
These computations are pure, but not lazy. A sweep selects values in place
without triggering or rearranging earlier work. It is the rake's result
form and needs no `return` keyword.

## 9. Columns

Data for vector code is usually stored as columns, one array for each field.
A `pack` describes one particle with its position, velocity and age. A
`stack` stores many particles as a separate column for each field.
`for particle in particles using f32s up to <count>:`
visits the records a rack at a time. A byte column is stored one byte per
record, and `widen` turns a chunk of it into a rack of 32-bit lanes when the
code needs it.

<!-- rake-check: run 1570 -->
<!-- playground-starter -->
```rake
pack Particles {
  f32: position, velocity;
  u8: age;
}

run advance(particles: stack Particles, <count: i64>, <dt: f32>) -> f32:
  for particle in particles using f32s up to <count>:
    let age = to_f32(bitcast(i32s, widen(particle.age)))
    yield particle.position + particle.velocity * <dt> / (age + <1.0>)

slow main() -> i32:
  positions: [6]f32 := [0.0, 10.0, 20.0, 30.0, 40.0, 50.0]
  velocities: [6]f32 := [4.0, 4.0, 4.0, 4.0, 4.0, 4.0]
  ages: [6]u8 := [0, 1, 3, 0, 1, 3]
  moved: [6]f32 := [0.0; 6]
  advance(stack Particles { position: positions, velocity: velocities, age: ages }, <6>, <0.5>, moved)
  total := 0.0
  for i from 0 up to 6:
    total <- total + moved[i]
  return i32(total * 10.0)
```

Result: `main returned 1570`. Each `yield` writes a rack of results to the
output, which slow code passes as the last argument. Change the count passed
to `advance` from `<6>` to `<5>` and run. The second chunk in the Lanes tab
now has one live lane and three empty ones. The tail loads and stores only
the record that exists.

## 10. A whole program

Slow code holds a program's records, state and control flow. A `record` groups
fields, `state games: i32 := 0` keeps a value for the life of the program,
and a `mut` parameter is one the function writes.
Inside a run, `slow { ... }` explicitly enters scalar mode. This is the
performance boundary corresponding to Rust's `unsafe { ... }` safety boundary.
At `}` the run resumes vector mode. This syntax is available in 0.5.0-beta
and in the playground.

<!-- rake-check: run 922 -->
<!-- playground-starter -->
```rake
record Score {
  f32: best;
  i32: rounds;
}

state games: i32 := 0

run highest(x: []f32, out: mut []f32):
  let <top: f32> = maximum(x[<0>])
  slow { games <- games + 1; }
  out[<0>] <- <top>

slow play(score: mut Score, values: []f32):
  top: [4]f32 := [0.0; 4]
  highest(values, top)
  if top[0] > score.best:
    score.best <- top[0]
  score.rounds <- score.rounds + 1

slow main() -> i32:
  score: Score := Score { best: 0.0, rounds: 0 }
  first: [4]f32 := [3.0, 8.0, 1.0, 5.0]
  second: [4]f32 := [9.0, 2.0, 4.0, 7.0]
  play(score, first)
  play(score, second)
  return i32(score.best) * 100 + score.rounds * 10 + games
```

Result: `main returned 922`: the best score 9, two rounds and two games. Add
`play(score, first)` after the two existing calls and run. Result becomes
`main returned 933`, showing that the record and module state survive each
call.

Now remove `slow {` and its closing brace, leaving `games <- games + 1` in
the run. Run it and read the error: vector code can't access module state.
Restore the block and run again. The reduction before it and the broadcast
store after it remain vector work. In Code, find the scalar helper call
between them.

A block's last expression can return a scalar to a marked uniform binding.
Its local bindings end at the brace. A block can't capture a rack: move the
`maximum` into it as `let top = maximum(x[<0>])`, run, and read the error.
Restore the reduction outside the block. A reduction or extraction is the
explicit boundary from a rack to a scalar.

Slow code can't hold a rack. This separate rejected example shows the rule:

<!-- rake-check: reject "slow code can't take f32s values" -->
```rake
slow total(values: f32s) -> f32:
  return 0.0

slow main() -> i32:
  return 0
```

Slow code is scalar, so it can't hold a rack. Vector work happens only inside
the vector functions it calls, which keeps every rack as one vector value.

## 11. Proved or refused

The target menu chooses a profile, and each profile has rules that every
program it compiles obeys. Physical profiles keep every rack in one register
without calls or spills. WebAssembly keeps every rack as one `v128` and uses
only the virtual instructions the profile lists. Rake has no vector sine yet:

<!-- rake-check: reject "call to 'sin' is not supported by native scratch lowering" -->
<!-- playground-starter -->
```rake
scratch wave(values: f32s) -> f32s:
  sin(values)
```

Run the program and read the unsupported-operation message. Then replace
`sin(values)` with `abs(values)` and run again. The supported operation
compiles, and Code shows its vector instruction. A C compiler given a sine of
every lane may call the scalar `sinf` once per lane and carry on, slower. Rake
stops and says which operation it can't compile. On a workstation,
`rakec --verify-native` also disassembles the object and checks the profile's
rules.

## 12. Bits

Racks hold integers too. A `u8s` rack holds sixteen bytes. Here each byte is
one row of an 8 by 8 board, and its bits are the row's cells. `shift_bits_left`
and `shift_bits_right` move every row's bits one cell east or west at once,
and `repeat` runs its body a fixed number of times.

<!-- rake-check: run 15 -->
<!-- playground-starter -->
```rake
~~ One step of a flood fill on an 8 by 8 board, a row to each byte lane:
~~ every reached cell spreads to its east and west neighbours that are open.
scratch spread(reached: u8s, open: u8s) -> u8s:
  let east = shift_bits_left(reached, 1)
  let west = shift_bits_right(reached, 1)
  bit_and(bit_or(reached, bit_or(east, west)), open)

run flood(rows: []u8, walls: []u8, out: mut []u8):
  reached := rows[<0>]
  repeat <step: i32> from <0> up to <7>:
    reached <- spread(reached, walls[<0>])
  out[<0>] <- reached

slow main() -> i32:
  start: [16]u8 := [8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  open: [16]u8 := [239, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0]
  filled: [16]u8 := [0; 16]
  flood(start, open, filled)
  return i32(filled[0])
```

Result: `main returned 15`. The fill starts at bit 3 of the first row, and bit
4 is a wall, so it spreads west to bits 0 to 3. Change the first byte in
`open` from `239` to `255` and run. Result becomes `main returned 255`, because
the fill reaches the whole row. Lanes shows sixteen decimal byte values, one
per lane, and each shift updates all sixteen at once.

## Reading Rake

Rake takes much of its look from functional languages such as OCaml,
Haskell, Elm and Erlang, and its layout from Python. A programmer who knows
C, Java or JavaScript meets these forms for the first time, and the
playground explains each one where it first appears, in a note beside the
editor.

### Layout

Function and control-flow bodies use indentation: a line ending in `:` opens
the lines indented below it, as in Python. Tabs aren't allowed. Braces enclose
pack and record fields, stack constructors and `slow { ... }` blocks. In a slow
block, multiline statements are indented, while inline statements use
semicolons. Its last expression is its value unless a semicolon discards it.

### Types after identifiers

`values: f32s` reads "values, of type `f32s`", the order of Python's type
hints, TypeScript, Rust and the ML family, rather than C's `float values`.
The result type comes after `->`, as in Python and Rust: `slow main() -> i32:`.
The plural spelling is a rack: `f32` is one float and `f32s` a register of
them.

### Bindings and locations

`let answer = 6 * 7` binds a name to a value once, as `let` does in OCaml
and Haskell, or `const` in JavaScript. A name that changes is a location:
`total := 0` creates it, and `total <- total + i` changes it. The two arrows
come from older languages. `:=` is assignment in Pascal and ALGOL and in
OCaml's references, and `<-` updates mutable fields and arrays in OCaml.
Keeping them apart from `=` means `=` is always a comparison: `if i % 2 = 0:`
tests equality, where C would write `==`.

### Expressions that choose

`if v > w then v - w else w - v` is an expression with a value, like C's
`v > w ? v - w : w - v` or OCaml's and Haskell's `if ... then ... else`.
On racks it chooses lane by lane. A statement `if` with a colon and a body is
the ordinary kind, for slow code and for runs.

### The marks

| Mark | Read it as | Familiar from |
| --- | --- | --- |
| `<x>`, `<x: f32>` | "the uniform `x`", the same in every lane | Rake's own: angle brackets around a scalar |
| `#valid` | "the tine `valid`", a mask of lanes | Rake's own: the `#` is drawn like a mask with open lanes |
| `\| moved <\| e` | "`e` flows into `moved`" | `<\|` is backward application in Elm and F#, the mirror of `\|>` |
| `\| #valid => rooted` | "where `#valid`, take `rooted`" | the cases of OCaml's and Haskell's `match` and `case`, and the arms of Rust's `match` |
| `_` | "every other lane" | the wildcard pattern of OCaml, Haskell, Rust and Erlang |
| `~~` | "a comment to the end of the line" | Rake's own, like `//` in C. `(* ... *)` is a block comment, as in OCaml and Pascal |

### Brackets

`[4]f32` is an array of four floats, written before the element type as in Go,
and `[]f32` is a view of any number of them. `[1.0, 2.0]` is an array literal,
and `[0.0; 4]` four copies of `0.0`, as in Rust. `x[<i>]` with a uniform index
loads a rack of consecutive elements, and `x[i]` in slow code reads one.

## Ligatures

Functional languages are full of operators made of two or three characters:
`->` and `<-`, `=>`, `|>` and `<|`, `::`, `<>`, and Haskell's `>>=` and
`<$>`. A programming font with ligatures draws each as one symbol, so `->`
becomes an arrow and `!=` an unequal sign, while the file still holds the
plain characters. Reading code in OCaml, Haskell, Erlang, Gleam or Rake gets
easier when the arrows look like arrows.

Three free fonts draw the operators these languages use: JetBrains Mono,
which this site uses, Fira Code and Cascadia Code. Rendered in each, these
sequences become single symbols:

| Typed | Drawn | Rake | OCaml | Haskell | Erlang | Gleam |
| --- | --- | --- | --- | --- | --- | --- |
| `->` | a right arrow | result types | function types and match arms | function types and lambdas | clause bodies | function types and case arms |
| `<-` | a left arrow | assignment | field and array assignment | `do` binding | comprehension generators | `use` |
| `=>` | a double arrow | sweep arms | | class constraints | map associations | |
| `<\|` and `\|>` | triangles | fused stages | `\|>` is the pipe | | | `\|>` is the pipe |
| `!=`, `/=`, `=/=` | an unequal sign | `!=` | `!=`, physical inequality | `/=` | `/=` and `=/=` | `!=` |
| `<=` and `>=` | less-or-equal and greater-or-equal signs | comparisons | comparisons | comparisons | `>=` | comparisons |
| `<>` | a diamond | | structural inequality | semigroup append | | string concatenation |
| `~~` | a joined wave | comments | | | | |

The fonts leave Erlang's `=<` alone, and JetBrains Mono alone joins
Haskell's `>>=`. `:=` keeps its characters, with the colon raised to line up
with the equals sign.

Ligatures have one trap in Rake. A negative uniform literal starts with the
same two characters as assignment, so all three fonts draw `<-1.0>` as an
arrow followed by `1.0>`. The playground highlights `<-1.0>` as a uniform,
and its stylesheet turns ligatures off inside uniforms, so the literal keeps
its characters while `total <- total` still gets its arrow. In an editor
without that rule, `< -1.0>` with a space means the same and draws plainly.

The playground has ligatures on, with a switch beside the target menu that
shows the plain characters, for a learner copying code into an editor that
draws them differently.
