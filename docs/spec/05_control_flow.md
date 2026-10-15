# Control flow

Rake has two kinds of choice: a uniform condition chooses the same branch
for every lane, while a mask chooses independently in each lane. Vector code
makes both choices by vector selection, whereas slow code can branch around
statements. Tines, through blocks and sweeps are the named form of mask
choice, defined in [tines, through and sweeps](03_tines_and_through.md). This
page defines conditional expressions, loops and branches.

## Conditional expressions

`if c then a else b` is a value. Its condition decides how it chooses.

A mask condition chooses lane by lane. Each branch is computed under its
mask, the condition's lanes for `a` and the others for `b`, combined with
any mask around the expression, and a lane-wise selection joins them. An
inactive lane's computation doesn't happen, as in a through block, so
targets with floating-point exceptions replace its operands with benign
values. A mask conditional compiles on every production profile, and on
WebAssembly the expression below is two subtractions, a comparison and one
`v128.bitselect`:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch distance(v: f32s, w: f32s) -> f32s:
  if v > w then v - w else w - v
```

A uniform condition chooses one whole rack. It can be a direct comparison of
uniform `f32`, `i32` or `u32` values, including a literal of the same type or
an extracted `f32` bound as a uniform. The physical profiles broadcast the
operands, compare them as vectors and select the same branch in every
participating lane, with benign operands in untaken work that could raise
floating-point exceptions. A surrounding `through` or a stack run's tail also
limits participation.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch pick(near: f32s, far: f32s, <distance: f32>, <limit: f32>) -> f32s:
  if <distance> <= <limit> then near else far
```

Float comparisons with a NaN are false, including `!=`, so an unordered
condition chooses the `else` arm. Integer comparisons keep their declared
signed or unsigned order, including values across bit 31.

WebAssembly keeps one scalar condition and a whole-rack selection, computing
both pure branches before selecting. These integer conditions work on every
production profile:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch pick_late(near: f32s, far: f32s, <late: i32>) -> f32s:
  if <late> > <0> then near else far

scratch pick_unsigned(near: u32s, far: u32s, <distance: u32>, <limit: u32>) -> u32s:
  if <distance> <= <limit> then near else far
```

A Boolean uniform chooses a whole rack on every production profile. On the
physical profiles its value bit expands into an all-lane mask, so untaken
floating-point work keeps the same operand protection as a comparison.
The condition can come from a parameter, a marked Boolean literal such as
`<true>`, or a mask reduction. Below, `any` makes every lane choose `near`
when at least one lane is positive:

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
scratch pick_enabled(near: f32s, far: f32s, <enabled: bool>) -> f32s:
  if <enabled> then near else far

scratch pick_any_positive(near: f32s, far: f32s) -> f32s:
  let <enabled: bool> = any(near > <0.0>)
  if <enabled> then near else far

scratch pick_first(near: f32s, far: f32s) -> f32s:
  pick_enabled(near, far, <true>)
```

Native stack runs take `i32`, `u32` and `bool` uniforms within their [C
register boundary](02_packs_and_run.md#the-c-boundary).

In slow code, only the chosen branch is evaluated.

In vector code, a branch can't read memory. A load, gather or element read is
bound with `let` before the conditional, so it visibly happens either way:

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
within 4096, and otherwise it stays a loop with the same meaning, keeping
each rack location in one `v128` local on WebAssembly. Native stack runs
accept only unrolled repeats, including nested ones that update local rack
locations or arrays of racks. Each rack of records starts with fresh
locations, and earlier immutable bindings keep their values.

<!-- rake-check: verify x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 -->
```rake
pack Samples {
  f32: value;
}

run cubes(samples: stack Samples) -> stack Samples:
  let value = samples.value
  power := value
  repeat <i: i32> from <0> up to <2>:
    power <- power * value
  samples with { value: power }
```

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
values across iterations. In a stack run's tail an assignment updates only
the active lanes.

A stack run has no loop of its own: the compiler visits its stacks' records a
rack at a time, as [packs and runs](02_packs_and_run.md) define. Its body may
contain `repeat`, counted loops and statement `if`.

## Slow control flow

Slow code has `if`, `else if` and `else`, `while`, the counted `for i from a
up to b by s`, `break`, `continue` and `return`, as [the slow
tier](08_slow_tier.md) defines. It holds no racks, so a run called inside a
slow loop does whole-rack work once each iteration.
