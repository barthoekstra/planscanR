# Resolve a legacy path or portable storage location

Character paths are accepted for older cache/index records (absolute
paths are only accepted when contained by one of the supplied roots).
Portable locations use
`list(storage_root_id = ..., relative_path = ...)`; `roots` is a named
character vector mapping those stable IDs to paths on this machine. The
built-in `cache` root resolves to `root` when no explicit mapping is
supplied.

## Usage

``` r
storage_resolve_location(
  location,
  root = NULL,
  roots = NULL,
  must_exist = FALSE
)
```

## Arguments

- location:

  A legacy absolute/root-relative path or portable location list.

- root:

  Existing cache root used for legacy relative paths and the built-in
  `cache` root.

- roots:

  Named paths for additional storage root IDs.

- must_exist:

  Require the resolved file or directory to exist.

## Value

A canonical absolute path below a registered root.
