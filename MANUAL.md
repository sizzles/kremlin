The KreMLin manual
==================

## Interaction with external code

To successfully mix hand-written C code and F* code, the recommended workflow
is:
- model your C functions at the F* level using a `Stubs.fst` or `Stubs.fsti`
  file and run `krml -skip-compilation Stubs.fst` to check that the
  generated .h file matches what you're about to provide;
- write other `.fst` files against `Stubs.fst`; extract with `krml -drop Stubs
  stubs.c` or `krml -drop Stubs -ccopt -lstubs`.

KreMLin still needs to see some declarations for your stubs, so that it can
type-check the rest of your program using these stubs. F*, however, just drops
any `.fsti` file, meaning that you need to use an `.fst` instead for KreMLin to
even be aware of these functions. The `-drop` option of KreMLin makes sure that
no `.h` or `.c` is generated, and you can provide hand-written code instead.

Note: you may need to add `-add-include '"stubs.h"'` too, and write `stubs.h` by
hand.

## Different degrees of inlining

### Using the F* normalizer

The `inline_for_extraction` keyword relies on F\*'s normalizer to replace calls
to `f x` with `x * x` *at extraction-time*.

```
inline_for_extraction let f x = x * x
```

This inlining can only operate on pure computations, but can inline them into
effectful computations. There is a warning when `inline_for_extraction` is
ignored on a stateful function.

The advantage of `inline_for_extraction` is that things such as:

```
let inline_for_extraction f (): Tot bool = false
let g () =
  if f () then
    e1
  else
    e2
```

end up normalized as:

```
let g () =
  e2
```

The `inline_for_extraction` keyword is specifically intended to impact only
(KreMLin) extraction, and is distinct from `unfold`, which impacts F\*'s SMT
encoding.

### Using KreMLin

The KreMLin extraction pipeline of F\* now supports custom attributes. The
`"substitute"` attribute means that KreMLin (not F\*!) will *always*,
*everywhere*, replace any call to `f x` with its body `x * x`.

```
[@"substitute"]
let f x = x * x
```

KreMLin also supports the `"c_inline"` attribute. This attribute just means
that:

```
[@ "c_inline" ]
let f x = x * x
```

is extracted to

```
inline int f(int x) {
  return x * x;
}
```

Note: the [C standard says](http://en.cppreference.com/w/c/language/inline)
says

> If a non-static function is declared inline, then it must be defined in the
> same translation unit. The inline definition that does not use extern is not
> externally visible and does not prevent other translation units from defining
> the same function. This makes the inline keyword an alternative to static for
> defining functions inside header files, which may be included in multiple
> translation units of the same program.

If you use `[@"c_inline"]` on a function that is called from another module,
this is likely to fail, unless you use the `-bundle` option of KreMLin.

## Generating `static` functions

Functions that are marked `private` in F\* can usually be marked as `static` in
the resulting C code, except for the following situation:

```
module M

private let g () =
  ...

let f (): StackInline unit ... =
  g ()

module N

let h () =
  M.f ()
```

That case will trigger warning 7 ("private F\* function cannot be marked as C
static").


## Workflow for higher-order programming in F\*

One may want to write high-order, generic code in F\* that, after sufficient
partial evaluation, becomes first-order and type-checks in Low\*. Here are some
tips and tricks:
- **non-Low\* subexpressions**: closures, natural integers, and other non Low\*
  constructs trigger early failures; chances are that these are used ghostly; if
  this is the case, use `erased` (from `FStar.Ghost`) to trigger extraction as
  `unit` arguments, which KreMLin knows how to eliminate;
- **higher-order types**: the default extraction from F\* leaves parameterized
  type definitions in place; in particular, this situation is problematic:
  ```
  let f x: Type = match x with ... -> int32 { ... refinement ... }
  let g x: f x = ...
  ```
  this cannot be expressed in C; to force every `f x` to reduce, use the
  `unfold` qualifier on `f`.

  If you have a type abbreviation that does not require computation but takes
  parameters that can be erased at extraction time, or that expands to a
  function type, you can use `inline_for_extraction` on the type-level function
  to unfold its definition at every usage before KreMLin constructs its type
  signature. This can help extract types that would otherwise not be
  expressible, and has the advantage of having no impact on verification.
- **polymorphism**: KreMLin does **not** support whole-program monomorphization
  yet; as a stop-gap measure, mark polymorphic functions with `[@"substitute"]`
  (on the `val` and the `let`) so that, once inlined at call-site, they
  type-check as Low\* -- consider turning Warning 10 on with `-warn-error +10`
