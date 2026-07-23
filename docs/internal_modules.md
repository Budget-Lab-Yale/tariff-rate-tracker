# Internal R module structure

The tracker is an executable analysis repository, not a user-facing R library.
Its internal R files nevertheless use a package-like dependency contract through
`src/core/module_loader.R`.

## Rules

- Every reusable production module is listed in `TARIFF_MODULES` with its file
  and direct dependencies.
- Entrypoints request a named bundle (`core`, `calculation`, `daily`, `build`, or
  `publishing`) rather than maintaining their own ordered `source()` lists.
- Dependencies are loaded recursively and each module is sourced once per target
  environment. Cycles and unknown module names are hard errors.
- `source(src/core/helpers.R)` remains supported for existing utilities, but it
  resolves its dependencies through the same manifest.
- Add a manifest entry or dependency edge when adding a production R module. Do
  not use `exists(function_name)` to infer whether a dependency happened to load.

This structure deliberately stops short of exposing the model as an installed R
package: the pipeline remains a set of executable scripts and keeps its current
CLI and cluster behavior.
