# The Rake playground

The playground teaches Rake to someone who has never written SIMD code, with
small programs to edit and run in the browser. Each lesson introduces one
idea and makes it visible in the result, the lane trace, the generated code or
a compiler message. This page is the lessons' source: the documentation
checker compiles every program here and verifies its stated result, so a
language change that breaks a lesson fails the compiler's tests.

## Tabs and targets

The editor has four output tabs:

| Tab | Shows |
| --- | --- |
| Result | what `main` returned, or the trap that stopped it, with its line |
| Lanes | each computed rack as a row with one decimal value per lane, and each mask as a row of filled and empty cells |
| Code | the selected target's output: C with WebAssembly intrinsics, native kernel assembly, or native mixed C with opaque kernel assembly |
| Messages | the compiler's errors, each also underlined in the editor at its line and column |

The target menu offers WebAssembly, SSE2, AVX2, AVX-512 and NEON. Lessons
with a whole program start on WebAssembly, which compiles stack runs and
general runs over views. The native targets compile stack runs, while general
runs over views and runtime inner loops give the compiler's work-in-progress
diagnostic there. Results and lane traces come from Rake's interpreter at
the selected profile's `f32` rack width, and Code displays the generated C or
assembly without executing it.

## The browser compiler

`rakec` is written in OCaml, and `js_of_ocaml` compiles its front end,
interpreter and emitters for the browser, so the playground runs the same code
as `rakec --interpret`, `rakec --emit-c` and `rakec --emit-asm`. Compilation
and execution happen in a worker, so a program that runs for more than three
seconds is stopped without freezing the editor. Object verification needs clang and a disassembler, so it stays on the
command line.

## 1. A program

A Rake file is a list of definitions. `slow main() -> i32:` defines the
program's entry point, a function with no parameters that returns a 32-bit
integer. A line ending in a colon opens the indented body below it, `let`
binds a name to a value, and `~~` starts a comment.

<!-- rake-check: run 42 -->
<!-- playground-starter -->
```rake
~~ The program's result is what main returns.
slow main() -> i32:
  let answer = 6 * 7
  return answer
```

Result: `main returned 42`. Change `6 * 7` to `9 * 9` and run, and Result
changes to `main returned 81`.

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
`total := 0` to `let total = 0` and run. Messages says
`this location can't be assigned` at the `<-`, because an immutable binding
can't change.

## 3. A rack

`f32s` is a rack: four `f32` values in one WebAssembly `v128`. A `run` is
vector code that reads and writes memory. Its parameter `x: []f32` is a view
of floats, and `out: mut []f32` is a writable one. `x[<0>]` loads the rack of
four floats starting at element 0, `out[<0>] <- ...` stores one, and `<2.0>`
is the number 2 in every lane.

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

Result: `main returned 20`. Change `<2.0>` to `<3.0>` and run, and Result
becomes `main returned 30`. In Lanes, the load fills a row of four cells,
`1 2 3 4`, and the multiply turns the whole row into `3 6 9 12` in one step,
and Code shows it as one `wasm_f32x4_mul`.

## 4. Marking uniforms

A `scratch` is a function of racks. `<factor: f32>` declares a uniform, one
scalar shared by every lane, and `<factor>` uses it. The brackets appear in
both places so that every point where a scalar becomes a rack shows on the
page.

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

Result: `main returned 40`. Slow code writes `factor` bare, because there
it's just a number, and marks it `<factor>` at the call, where it crosses into
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
with a uniform index. `sums := <0.0>` is a location holding a rack of four
running sums, `sum(sums)` adds a rack's lanes into one scalar, and
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
`total` from `<12>` to `<8>` and run, and Result becomes `main returned 36`.
Lanes shows `sums` holding `6 8 10 12`, one running sum in each lane, and
`sum` folds them from lane 0 upwards into 36: vector code adds in columns, then
reduces once at the end.

## 6. Fused stages

`| step <| velocities * <dt>` is one stage of a fused computation, read from
right to left: the expression flows into `step`. Consecutive stages form one
region of pure arithmetic, and their identifiers are for the reader, so the
compiler sees `positions + velocities * <dt>`.

<!-- rake-check: verify x86-avx2 aarch64-neon wasm-simd128 -->
<!-- playground-starter -->
```rake
scratch advance(positions: f32s, velocities: f32s, <dt: f32>) -> f32s:
  | step  <| velocities * <dt>
  | moved <| positions + step
  moved
```

This lesson has no `main`. Select `x86-avx2`, run the compiler and open Code
to find the two instructions that implement the scratch:

```text
advance:
    vbroadcastss ymm2, xmm2
    vfmadd231ps ymm0, ymm1, ymm2
    ret
```

The multiply and the add became one fused multiply-add on eight lanes, after
a broadcast of `<dt>`. On `wasm-simd128`, which has no fused multiply-add, the
tab shows a splat, a multiply and an add.

## 7. Choosing by lane

A comparison of racks gives a mask, one true or false for each lane, and
`if v > w then v - w else w - v` with a mask condition chooses lane by lane.

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
Change the first value of `a` from `1.0` to `6.0` and run, and Result becomes
`main returned 1703`. In Lanes, the first mask value changes and the select
takes the other subtraction for that lane. Both subtractions still run on all
four lanes, because there's only one instruction stream.

## 8. Tines and sweeps

The square root of a negative number is NaN:

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

Result: a trap at the last line, `-nan does not fit i32`, with `4 NaN 3 1` in
Lanes. A rake guards the lanes instead. `tine #valid(values: f32s) means
values >= <0.0>` is a reusable predicate defined outside the rake, and
`#valid(values)` computes the mask of lanes that may take a root.
`through #valid(values) into rooted:` binds roots in those lanes and leaves
the others undefined, so the sweep reads `rooted` only where the tine holds,
and the `gaps` arm supplies zero for every other lane.

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

Result: `main returned 8`, and the NaN has left Lanes: `4 0 3 1`.

Change the `gaps` arm's value to `<-1.0>` and run. The result becomes
`main returned 7`, with output lanes `4 -1 3 1`. There's no intermediate zero
to change, because `rooted` has a value only where `#valid(values)` holds.

Delete the `gaps` arm and run, and the compiler reports
`Sweep does not provably cover every lane`. Restore it, then change its value
to `rooted`. That's refused too, because it would read the root in the
negative lane, where none was computed. To define that lane, add
`else <999.0>` before `into rooted` in the through header, and run with
`rooted` still in both sweep arms: the result is now 1007. Reset the lesson to
restore its original behaviour.

## 9. Columns

A `pack` describes one particle, and a `stack` stores many particles as a
column for each field, with a count of records. In a run,
`particles.position` is the entire position column, and the compiler visits
it a rack at a time, including a final partial rack. The byte column `age`
stays one byte per record. `widen` extends it to unsigned 32-bit lanes,
and `to_f32` converts those to floats for the calculation.

<!-- rake-check: run 1570 -->
<!-- playground-starter -->
```rake
pack Particles {
  f32: position, velocity;
  u8: age;
}

run advance(particles: stack Particles, <dt: f32>) -> stack Particles:
  let age = to_f32(widen(particles.age))
  particles with { position: particles.position + particles.velocity * <dt> / (age + <1.0>) }

slow main() -> i32:
  positions: [6]f32 := [0.0, 10.0, 20.0, 30.0, 40.0, 50.0]
  velocities: [6]f32 := [4.0, 4.0, 4.0, 4.0, 4.0, 4.0]
  ages: [6]u8 := [0, 1, 3, 0, 1, 3]
  let n = 6
  particles := stack Particles { position: slice(positions, 0, n), velocity: slice(velocities, 0, n), age: slice(ages, 0, n) }
  particles <- advance(particles, <0.5>)
  total := 0.0
  for i from 0 up to i32(count(particles)):
    total <- total + particles.position[i]
  return i32(total * 10.0)
```

Result: `main returned 1570`. Calling `advance` moves the stack in and returns
it with `position` replaced, so the program assigns the result back to
`particles`. Change `let n = 6` to `let n = 5` and run. The second rack in
Lanes now has one live lane and three empty ones, because the tail loads and
stores only the record that exists.

Now keep only the young particles. Add `tine #young means age < <2.0>` after
the `let` in `advance`, and change its last line to `compact particles with {
position: ... } where #young`, keeping the same position expression. With
`n = 6` the result is `main returned 860`: four particles remain, moved to the
front of each column, and `count(particles)` is 4.

The lesson starts on WebAssembly, with four records per rack, as on SSE2 and
NEON. Select AVX2, with eight, or AVX-512, with sixteen, and both counts above
fit in one partial rack.

## 10. A whole program

Slow code holds a program's records, state and control flow. A `record`
groups fields, `state games: i32 := 0` keeps a value for the life of the
program, and a `mut` parameter lets the function write to it. Inside a run,
`slow { ... }` enters scalar mode, the performance boundary corresponding to
Rust's `unsafe { ... }` safety boundary, and at `}` the run resumes vector
mode.

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
`main returned 933`, because the record and module state survive each call.

Now remove `slow {` and its closing brace, leaving `games <- games + 1` in
the run. Run it and read the error: vector code can't access module state.
Restore the block and run again, then find the scalar helper call in Code,
between the vector reduction before it and the broadcast store after it.

A block can return a scalar to a marked uniform binding, but it can't capture
a rack: move
the `maximum` into it as `let top = maximum(x[<0>])`, run, and read the error.
Then restore the reduction outside the block. A reduction or extraction is the
explicit boundary from a rack to a scalar.

Slow code can't hold a rack at all, so this separate example is rejected:

<!-- rake-check: reject "slow code can't take f32s values" -->
```rake
slow total(values: f32s) -> f32:
  return 0.0

slow main() -> i32:
  return 0
```

## 11. Proved or refused

The target menu chooses a profile, and each profile has its own rules for
compiled programs. Physical profiles keep every rack in one register
without calls or spills, while WebAssembly keeps every rack as one `v128` and
uses only the profile's listed virtual instructions. Rake has no vector sine
yet:

<!-- rake-check: reject "call to 'sin' is not supported by native scratch lowering" -->
<!-- playground-starter -->
```rake
scratch wave(values: f32s) -> f32s:
  sin(values)
```

Run the program and read the unsupported-operation message, then replace
`sin(values)` with `abs(values)` and run again. The supported operation
compiles, and Code shows its vector instruction. A C compiler given a sine of
every lane may call the scalar `sinf` once per lane and carry on, slower,
whereas Rake stops and says which operation it can't compile.

## 12. Bits

Racks hold integers too. A `u8s` rack holds sixteen bytes, and here each byte
is one row of an 8 by 8 board, with its bits as the row's cells.
`shift_bits_left` and `shift_bits_right` move every row's bits one cell east
or west at once, and `repeat` runs its body a fixed number of times.

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
`open` from `239` to `255` and run, and Result becomes `main returned 255`
because the fill reaches the whole row. Lanes shows sixteen decimal byte
values, one per lane, and each shift updates all sixteen at once.

## Reading Rake

Rake takes much of its look from functional languages such as OCaml, Haskell,
Elm and Erlang, and its layout from Python.

### Layout

A line ending in `:` opens the lines indented below it, as in Python, for
function and control-flow bodies, and tabs aren't allowed. Braces enclose pack
and record fields, stack constructors and `slow { ... }` blocks. In a slow
block, multiline statements are indented and inline statements use
semicolons, and the last expression is the block's value unless a semicolon
discards it.

### Types after identifiers

`values: f32s` reads "values, of type `f32s`", in the order of Python's type
hints, TypeScript, Rust and the ML family, where C writes `float values`. The
result type follows `->`, as in `slow main() -> i32:`, and the plural spelling
is a rack: `f32` is one float and `f32s` a register of them.

### Bindings and locations

`let` binds a name to a value once, as in OCaml and Haskell, or `const` in
JavaScript. A location is created with `:=` and changed with `<-`, which come
from Pascal, ALGOL and OCaml. Keeping both apart from `=` means `=` is always
a comparison, so `if i % 2 = 0:` tests equality where C would write `==`.

### Conditional expressions

`if v > w then v - w else w - v` is an expression with a value, like C's
`v > w ? v - w : w - v` or OCaml's and Haskell's `if ... then ... else`. A
statement `if` with a colon and a body is the ordinary kind.

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

`[4]f32` is an array of four floats, written before the element type as in
Go, and `[]f32` is a view of any number of them. `[1.0, 2.0]` is an array
literal, and `[0.0; 4]` is four copies of `0.0`, as in Rust. `x[<i>]` with a
uniform index loads a rack of consecutive elements, and `x[i]` in slow code
reads one.

## Ligatures

A programming font with ligatures, such as this site's JetBrains Mono,
Fira Code or Cascadia Code, draws operators such as `->`, `<-`, `=>`,
`<|` and `~~` as single symbols, while the file still holds the plain
characters.

A negative uniform literal starts with the same two characters as assignment,
so all three fonts draw `<-1.0>` as an
arrow followed by `1.0>`. The playground highlights `<-1.0>` as a uniform and
turns ligatures off inside uniforms, so the literal keeps its characters while
`total <- total` still gets its arrow. In an editor without that rule,
`< -1.0>` with a space means the same and draws plainly. The Ligatures switch
beside the target menu shows the plain characters, for copying code into an
editor that draws them differently.
