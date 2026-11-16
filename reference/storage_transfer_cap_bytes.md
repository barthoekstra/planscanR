# Return the finite per-download cap used by planscanR.

Acquisition workers use this cap as a hard reservation maximum. An
unbounded downloader option is rejected so a transfer cannot exceed its
reservation without a separate bounded growth protocol.

## Usage

``` r
storage_transfer_cap_bytes()
```

## Value

A positive byte count.
