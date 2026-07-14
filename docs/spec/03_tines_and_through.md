# Tines, through regions, and sweeps

Rake makes lane-dependent control explicit. A tine names a Boolean mask, a
through region computes one candidate under that mask, and a sweep chooses one
defined result for every lane.

## Tines

A tine declaration reads as a sentence:

```text
tine #valid when values >= <0.0>
```

`#valid` contains one Boolean decision per lane. The `#` is deliberately
visual: like a perforated mask or the tines of a rake, it suggests that some
values fall through its holes while others are held back. Because `#` always
means a mask, the distinction remains visible everywhere that mask is used.

Predicates evaluate lane by lane. They may combine comparisons, named tines,
and `not`, `and`, and `or`. A tine name refers only to its mask; it neither
executes nor stores a candidate computation.

## Through regions

A through region selects a tine, supplies safe inactive operands, and binds one
candidate result:

```text
through #valid else <0.0> into rooted:
  sqrt(values)
```

The header reads in semantic order: values pass `through #valid`; inactive
lanes receive the uniform scalar `<0.0>`; and the candidate flows `into
rooted`. The `else` clause is required whenever an inactive lane needs a safe
operand or passthrough.

For a lane where the tine is true, the body is semantically evaluated. For an
inactive lane it is not: the body must not consume an invalid operand, raise a
floating-point exception, access memory, or perform another side effect. The
passthrough is evaluated outside the masked body and supplies inactive lanes.

An implementation may speculate a pure, total operation only when speculation
is observably equivalent to skipping the inactive lane. Selecting the final
value after an unsafe operation does not satisfy this rule.

### Executable semantics

The scalar interpreter skips inactive lanes and supplies the passthrough. A
vector backend replaces inactive inputs with benign operands before every
operation that is safe to sanitize. It may supply `0.0` before `sqrt`, for
example, or numerator `0.0` and denominator `1.0` before division. A final
vector selection chooses the active result or passthrough. Targets with native
masked operations may use them when they preserve the same semantics.

Typed native IR records each benign substitution. Verification rejects an
exception-capable masked instruction whose operands bypass sanitization.
Operations without a call-free masked lowering remain unavailable on that
target rather than falling back to scalar lane work.

## Sweeps

A sweep lists tine arms in source-priority order and ends with one catch-all:

```text
return sweep:
  | #first  => first_value
  | #second => second_value
  | _       => fallback
```

The first matching named arm wins when masks overlap. `_` supplies every lane
that matched no named arm. Every sweep has exactly one final catch-all; the
checker rejects a missing catch-all, duplicate tine, or arm after `_`.

The leading bars align the alternatives as one selection surface. `=>` points
from a lane condition to the value chosen for those lanes. `return sweep:`
makes clear that this total selection is the rake's result, rather than another
intermediate mask.

Semantic evaluation begins with the catch-all value and applies named arms
from last to first. Native lowering implements the same priority with vector
selection or target mask instructions. It may introduce neither an undefined
lane nor a synthetic default absent from the source.

## Complete example

<!-- rake-example:safe-through:start -->
```rake
rake safe_root(values: f32s) -> f32s:
  tine #valid when values >= <0.0>

  through #valid else <0.0> into rooted:
    sqrt(values)

  return sweep:
    | #valid => rooted
    | _      => <0.0>
```
<!-- rake-example:safe-through:end -->

Tines need not be mutually exclusive. Source order is the explicit priority
mechanism; the final `_` makes the result total.
