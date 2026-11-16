# Resolve one portable location below a storage root.

Existing symlink components are canonicalized before the containment
check, so a path cannot escape through a symlink below the root.

## Usage

``` r
storage_path(root, relative_path, create_parent = FALSE)
```

## Arguments

- root:

  Existing storage root.

- relative_path:

  Portable path below `root`.

- create_parent:

  Create the containing directory after validation.

## Value

An absolute canonical path.
