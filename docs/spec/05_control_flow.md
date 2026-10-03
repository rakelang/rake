# Control flow

Rake has two kinds of choice. A uniform condition chooses the same branch for
every lane. A mask chooses a branch independently in each lane.
In vector code, both choices use vector selection. Slow code can branch
around statements. Tines, through blocks and sweeps are the
named form of the second kind, defined in [tines, through and
sweeps](03_tines_and_through.md). This page defines conditional
expressions, loops and branches.

## Conditional expressions

`if c then a else b` is a value. Its condition decides how it chooses.

A mask condition chooses lane by lane. Each branch is computed under its
mask, the condition's lanes for `a` and the others for `b`, combined with
any mask around the expression, and a lane-wise selection joins them. An
inactive lane's computation doesn't happen, as in a through block, so
operands are replaced with benign values on targets with floating-point
exceptions. On WebAssembly, the expression below is two subtractions, a
comparison and one `v128.bitselect`. A mask conditional compiles on
every production profile:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch distance(v: f32s, w: f32s) -> f32s:
  if v > w then v - w else w - v
```

A uniform condition chooses one whole rack. The development compiler accepts
a direct comparison of uniform `f32` values on every production profile.
A comparison can also use a literal or an extracted `f32` bound as a uniform.
The physical profiles broadcast the operands, compare them as vectors and
select the same branch in every participating lane. Both branches have
instructions, with benign operands substituted for untaken work that could
raise floating-point exceptions. A surrounding `through` or traversal tail
also limits participation.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch pick(near: f32s, far: f32s, <distance: f32>, <limit: f32>) -> f32s:
  if <distance> <= <limit> then near else far
```

Comparisons with a NaN are false, including `!=`, so an unordered condition
chooses the `else` arm. These native conditionals are development additions
after the 0.6.0-beta tag. Integer and Boolean uniform conditions in vector
code remain WIP (work in progress) on the physical profiles.

WebAssembly retains one scalar condition and a whole-rack selection. It
computes both pure branches before selecting, and has no floating-point
exception flags. It also supports integer and Boolean conditions:

<!-- rake-check: verify wasm-simd128 -->
```rake
scratch pick_late(near: f32s, far: f32s, <late: i32>) -> f32s:
  if <late> > <0> then near else far
```

In slow code, only the chosen branch is evaluated.

In vector code, a branch can't read memory. A load, gather or element read is
bound with `let` before the conditional, so it visibly happens whichever way
the condition goes:

<!-- rake-check: reject "an if's branches compute on values" -->
```rake
run choose(x: []f32, out: mut []f32, <late: i32>):
  out[<0>] <- if <late> > <0> then x[<0>] else x[<4>]
```

## Fixed-count loops

`repeat <i: i32> from <0> up to <4>:` runs its body once for each index from
the first bound up to, but not including, the second. Both bounds are
constants, and the brackets mark the index as uniform. Inside the body the
index is a constant, so it can index an array of rack locations and take part
in address arithmetic.

In a scratch or rake, `repeat` unrolls completely, and the body may update
mutable rack locations, so a scratch stays straight-line code. This compiles on
every production profile:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch cube(a: f32s) -> f32s:
  power := a
  repeat <i: i32> from <0> up to <2>:
    power <- power * a
  power
```

In a run, `repeat` unrolls while its trips times its body's statements stay
within 4096, and otherwise it stays a loop with the same meaning. Either way
each rack location stays one `v128` value in a WebAssembly local. In
`test/program/vector_tier.rk`, a `repeat` of 5000 trips compiles to a loop of
one `f32x4.mul`, one `f32x4.add` and the counter.

## Loops and branches in runs

A run's counted loop, `for <i: i32> from <a> up to <b> by <s>:`, has a uniform
index, bounds and step. The step is 1 unless given. A step of zero or less
traps, and the last iteration stops at the bound instead of stepping past it.
A statement `if <c>:`, with `else if` and `else` arms, takes a uniform
condition and branches around whole statements:

<!-- rake-check: run 20 -->
```rake
run clip_rows(x: []f32, out: mut []f32, <n: i32>, <limit: i32>):
  for <i: i32> from <0> up to <n> by <4>:
    let row = x[<i>]
    if <i> < <limit>:
      out[<i>] <- row * <2.0>
    else:
      out[<i>] <- row

slow main() -> i32:
  values: [12]f32 := [1.0; 12]
  result: [12]f32 := [0.0; 12]
  clip_rows(values, result, <12>, <8>)
  total := 0.0
  i := 0
  while true:
    if i = 12:
      break
    total <- total + result[i]
    i <- i + 1
  return i32(total)
```

A run has no `while`, `break`, `continue` or `return`, so every vector loop
runs a counted number of iterations. Mutable rack locations, such as
`total := <0.0>`, and arrays of them, such as `acc: [8]i32s := <0>`, carry
values across iterations. In a traversal's tail an assignment updates only
the active lanes.

A traversal, `for chunk in input using f32s up to <count>:`, is a different
loop: it visits a stack's records a rack at a time, as [packs and
runs](02_packs_and_run.md) define. A counted loop may contain a traversal, and
a traversal may contain counted loops, `repeat`, statement `if` and a
traversal of the same lane count.

## Slow control flow

Slow code has `if`, `else if` and `else`, `while`, the counted `for i from a
up to b by s`, `break`, `continue` and `return`, as [the slow
tier](08_slow_tier.md) defines. It holds no racks, so a run called inside a
slow loop does whole-rack work once each iteration.
